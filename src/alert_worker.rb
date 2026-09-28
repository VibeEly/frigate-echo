require 'fileutils'

# One alert that needs to be exported from Frigate and archived.
class ExportJob
  attr_accessor :export_id, :stored_path, :attempts, :run_at
  attr_reader :internal_id, :camera, :start_time, :end_time

  def initialize(internal_id:, camera:, start_time:, end_time:)
    @internal_id = internal_id
    @camera      = camera
    @start_time  = start_time
    @end_time    = end_time
    @attempts    = 0
    @run_at      = Time.now
  end
end

# Processes ExportJobs on a background thread so a slow export never blocks the
# MQTT loop. A failed job is retried with increasing delays; the queue lives in
# memory, so jobs still waiting are lost if the container restarts.
class AlertWorker
  # Seconds to wait before retry 1, 2, ... The job is abandoned once these run out.
  RETRY_DELAYS = [30, 60, 120, 300, 600].freeze

  STABLE_CHECK_INTERVAL = 3
  STABLE_CHECK_TIMEOUT  = 120

  def initialize(frigate:, exports_dir:, storage_dir:, remote_backup:, logger:, export_timeout: 600)
    @frigate        = frigate
    @exports_dir    = exports_dir
    @storage_dir    = storage_dir
    @remote_backup  = remote_backup
    @logger         = logger
    @export_timeout = export_timeout

    @jobs = []
    @lock = Mutex.new
    @wakeup = ConditionVariable.new
  end

  def start
    @thread = Thread.new { run }
    @thread.abort_on_exception = true
    self
  end

  def enqueue(job)
    @lock.synchronize do
      @jobs << job
      @wakeup.signal
    end
  end

  private

  def run
    loop do
      process(next_job)
    end
  end

  # Blocks until a job is due.
  def next_job
    @lock.synchronize do
      loop do
        now = Time.now
        due = @jobs.select { |j| j.run_at <= now }.min_by(&:run_at)

        if due
          @jobs.delete(due)
          return due
        end

        next_run_at = @jobs.map(&:run_at).min
        timeout = next_run_at ? [next_run_at - now, 0.1].max : nil
        @wakeup.wait(@lock, timeout)
      end
    end
  end

  def process(job)
    job.attempts += 1

    archive(job)
    upload(job)
  rescue StandardError => e
    handle_failure(job, e)
  end

  # Exports the clip from Frigate and moves it into Echo storage.
  def archive(job)
    id = job.internal_id

    unless job.export_id
      job.export_id = @frigate.create(job.camera, job.start_time, job.end_time)['export_id']
      @logger.info "#{id} Frigate export id: #{job.export_id}"
    end

    export = @frigate.wait_until_complete(job.export_id, timeout: @export_timeout)

    if export.nil?
      # Stuck or lost export: drop it so the next attempt starts a fresh one.
      discard_export(job)
      raise "Timed out waiting for Frigate to finish the export"
    end

    filename = File.basename(export['video_path'])
    filepath = File.join(@exports_dir, filename)

    # Frigate versions that do not report "in_progress" need the file checked.
    unless export.key?('in_progress')
      raise "Export file never stabilised: #{filepath}" unless wait_for_stable_file(filepath)
    end

    raise "Export file not found: #{filepath}" unless File.file?(filepath)
    raise "Export file is empty: #{filepath}" if File.size(filepath).zero?

    @logger.info "#{id} Frigate export complete."

    human_time = Time.at(job.start_time).localtime.strftime("%Y%m%d%H%M%S")
    stored_path = File.join(@storage_dir, "#{human_time}-#{filename}")

    move_into_place(filepath, stored_path)
    job.stored_path = stored_path

    @logger.info "#{id} File moved to Echo storage."

    # Delete the export in Frigate now that the clip is safely in Echo storage.
    begin
      @frigate.delete(job.export_id)
      @logger.info "#{id} Export deleted from Frigate."
    rescue StandardError => e
      @logger.warn "#{id} Could not delete export #{job.export_id} from Frigate (clip already archived): #{first_line(e)}"
    end
    job.export_id = nil
  end

  # Ship a copy offsite. A failure is not fatal: RemoteBackup remembers that it
  # is behind and Maintenance keeps retrying until everything is uploaded.
  def upload(job)
    return unless @remote_backup

    begin
      @remote_backup.upload(job.stored_path)
      @logger.info "#{job.internal_id} File backed up to remote server."
    rescue StandardError => e
      @logger.warn "#{job.internal_id} Remote backup failed, will retry: #{first_line(e)}"
    end
  end

  def handle_failure(job, error)
    id = job.internal_id
    delay = RETRY_DELAYS[job.attempts - 1]

    if delay
      job.run_at = Time.now + delay
      enqueue(job)
      @logger.warn "#{id} Attempt #{job.attempts} failed (#{error.class}: #{first_line(error)}). Retrying in #{delay}s."
    else
      @logger.error "#{id} Giving up after #{job.attempts} attempts (#{error.class}: #{first_line(error)})."
      # Do not leave an unwanted export behind in Frigate: exports are never
      # removed by Frigate's retention.
      discard_export(job) unless job.stored_path
    end
  end

  def discard_export(job)
    return unless job.export_id

    begin
      @frigate.delete(job.export_id)
      @logger.info "#{job.internal_id} Discarded unfinished export #{job.export_id} from Frigate."
    rescue StandardError => e
      @logger.warn "#{job.internal_id} Could not discard export #{job.export_id}: #{first_line(e)}"
    end

    job.export_id = nil
  end

  # Waits until the file exists and its size stops changing.
  def wait_for_stable_file(path)
    deadline = Time.now + STABLE_CHECK_TIMEOUT
    last_size = -1

    loop do
      if File.file?(path)
        size = File.size(path)
        return true if size > 0 && size == last_size
        last_size = size
      end

      return false if Time.now > deadline

      sleep STABLE_CHECK_INTERVAL
    end
  end

  # Frigate's exports folder and Echo storage are usually different
  # filesystems, so the move is a copy. Copy under a temporary name and rename
  # when done so a syncing tool never sees a half-written .mp4.
  def move_into_place(src, dest)
    tmp = "#{dest}.part"

    begin
      FileUtils.mv(src, tmp)
      File.rename(tmp, dest)
    rescue StandardError
      FileUtils.rm_f(tmp)
      raise
    end
  end

  def first_line(error)
    error.message.lines.first.to_s.strip
  end
end
