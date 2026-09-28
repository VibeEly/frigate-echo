# Background housekeeping:
# * Keeps retrying uploads to the remote backup until everything is there,
#   so a clip is not stranded locally just because the remote was
#   unreachable when the alert happened.
# * Applies retention to Echo storage and the remote backup once per day,
#   whether or not any alerts arrived.
class Maintenance
  SWEEP_INTERVAL = 60
  PRUNE_INTERVAL = 24 * 60 * 60
  STALE_PART_AGE = 60 * 60 # leftover .part files from an interrupted move

  def initialize(storage_dir:, remote_backup:, retention_days:, logger:)
    @storage_dir    = storage_dir
    @remote_backup  = remote_backup
    @retention_days = retention_days
    @logger         = logger
  end

  def start
    @thread = Thread.new { run }
    @thread.abort_on_exception = true
    self
  end

  private

  def run
    last_prune_at = nil

    loop do
      begin
        sweep_remote

        if last_prune_at.nil? || Time.now - last_prune_at >= PRUNE_INTERVAL
          last_prune_at = Time.now
          prune
        end
      rescue StandardError => e
        @logger.error "Maintenance error: #{e.class}: #{e.message.lines.first.to_s.strip}"
      end

      sleep SWEEP_INTERVAL
    end
  end

  def clips
    Dir.children(@storage_dir).select do |name|
      name.end_with?('.mp4') && File.file?(File.join(@storage_dir, name))
    end
  end

  def sweep_remote
    return unless @remote_backup && @remote_backup.pending?

    names = clips
    @logger.info "Syncing #{names.size} clip(s) to remote backup." unless names.empty?

    @remote_backup.sync_files(@storage_dir, names)
    @logger.info "Remote backup is up to date." unless names.empty?
  rescue StandardError => e
    @logger.warn "Remote backup sync failed, will retry: #{e.message.lines.first.to_s.strip}"
  end

  def prune
    return unless @retention_days

    @logger.info "Removing expired data from Echo storage."

    clip_cutoff = Time.now - (@retention_days * 24 * 60 * 60)
    part_cutoff = Time.now - STALE_PART_AGE

    Dir.children(@storage_dir).each do |name|
      path = File.join(@storage_dir, name)
      next unless File.file?(path)

      if name.end_with?('.mp4')
        File.delete(path) if File.mtime(path) < clip_cutoff
      elsif name.end_with?('.part')
        File.delete(path) if File.mtime(path) < part_cutoff
      end
    end

    return unless @remote_backup

    begin
      @remote_backup.prune(@retention_days)
      @logger.info "Removed expired data from remote backup."
    rescue StandardError => e
      @logger.warn "Could not prune remote backup: #{e.message.lines.first.to_s.strip}"
    end
  end
end
