require 'open3'
require 'shellwords'


# * Only key-based SSH auth is supported (no password prompts)
# * Host key checking defaults to "yes". The remote host must be present
#   in a known_hosts file (default one, or given via known_hosts_file)
# * Uploads are idempotent. `pending?` stays true after a failed upload (and
#   after startup) until `sync_files` has pushed everything, so a retry loop
#   can keep calling it.
class RemoteBackup
  class Error < StandardError; end

  # Partially transferred files go here instead of under their final name, so
  # a truncated clip is never mistaken for a complete one.
  PARTIAL_DIR = '.rsync-partial'.freeze

  # rsync exit 24 means "some source files vanished before transfer", which is
  # expected when local retention removes a file mid-sync.
  OK_EXIT_CODES = [0, 24].freeze

  def initialize(host:, user:, path:, port: 22, identity_file: nil,
                 known_hosts_file: nil, strict_host_key_checking: true,
                 rsync_bin: 'rsync', bandwidth_limit: 0)
    raise ArgumentError, 'host is required'  if host.to_s.empty?
    raise ArgumentError, 'user is required'  if user.to_s.empty?
    raise ArgumentError, 'path is required'  if path.to_s.empty?

    @host = host
    @user = user
    @path = path
    @port = Integer(port)
    @identity_file = identity_file
    @known_hosts_file = known_hosts_file
    @strict_host_key_checking = strict_host_key_checking
    @rsync_bin = rsync_bin
    @bandwidth_limit = Integer(bandwidth_limit || 0)

    @lock = Mutex.new
    # Start pending so a restart re-syncs anything a previous run failed to upload.
    @pending = true
  end

  def pending?
    @pending
  end

  # Uploads a single local file to the configured remote directory.
  def upload(local_path)
    unless File.file?(local_path)
      raise Error, "Local file not found: #{local_path}"
    end

    @lock.synchronize do
      run_rsync([local_path, remote_target])
    end

    true
  rescue StandardError
    @pending = true
    raise
  end

  # Uploads the named files (relative to dir) in one rsync run. Files that are
  # already up to date on the remote are skipped by rsync.
  def sync_files(dir, names)
    # Cleared before the transfer so a failure that happens meanwhile is not lost.
    @pending = false
    return true if names.empty?

    @lock.synchronize do
      run_rsync(['--files-from=-', ensure_trailing_slash(dir), remote_target],
                stdin_data: names.join("\n") + "\n")
    end

    true
  rescue StandardError
    @pending = true
    raise
  end

  # Deletes clips older than retention_days from the remote backup.
  def prune(retention_days)
    days = Integer(retention_days)
    raise ArgumentError, 'retention_days must be at least 1' if days < 1

    remote_dir = ensure_trailing_slash(@path).chomp('/')
    minutes = days * 24 * 60

    # Executed string on remote shell. Uses -mmin so the cutoff matches the
    # local retention exactly (find's -mtime rounds to whole days).
    remote_find_cmd = "find #{Shellwords.escape(remote_dir)} -type f -name '*.mp4' -mmin +#{minutes} -delete"

    cmd = ssh_argv + ["#{@user}@#{@host}", remote_find_cmd]

    stdout, stderr, status = @lock.synchronize { Open3.capture3(*cmd) }

    unless status.success?
      raise Error, "remote prune exited with #{status.exitstatus}: #{stderr.strip.empty? ? stdout.strip : stderr.strip}"
    end

    true
  end

  private

  def remote_target
    "#{@user}@#{@host}:#{ensure_trailing_slash(@path)}"
  end

  def run_rsync(args, stdin_data: nil)
    cmd = [
      @rsync_bin,
      '-a',                              # archive mode; no -z, MP4 is already compressed
      "--partial-dir=#{PARTIAL_DIR}",    # keep partial transfers (resumable) out of the way
      '--timeout=60',
      "--bwlimit=#{@bandwidth_limit}",   # limit bandwidth in KB/s, default unlimited 0
      '-e', build_ssh_command
    ] + args

    stdout, stderr, status = Open3.capture3(*cmd, stdin_data: stdin_data.to_s)

    unless OK_EXIT_CODES.include?(status.exitstatus)
      raise Error, "rsync exited with #{status.exitstatus}: #{stderr.strip.empty? ? stdout.strip : stderr.strip}"
    end

    true
  end

  def ensure_trailing_slash(path)
    path.end_with?('/') ? path : "#{path}/"
  end

  # Builds argv for invoking ssh directly via Open3
  def ssh_argv
    argv = ['ssh', '-p', @port.to_s, '-o', 'BatchMode=yes']

    # A dead or unreachable host must fail fast instead of hanging the caller.
    argv += ['-o', 'ConnectTimeout=10']
    argv += ['-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=3']

    argv += ['-i', @identity_file] if @identity_file

    if @strict_host_key_checking
      argv += ['-o', 'StrictHostKeyChecking=yes']
      argv += ['-o', "UserKnownHostsFile=#{@known_hosts_file}"] if @known_hosts_file
    else
      argv += ['-o', 'StrictHostKeyChecking=no']
    end

    argv
  end

  # Builds the string passed to rsync's `-e` flag.
  def build_ssh_command
    ssh_argv.map { |arg| rsync_rsh_quote(arg) }.join(' ')
  end

  # Quotes a single argument for rsync's --rsh splitter. Anything containing
  # whitespace, a single quote, a double quote, or a backslash is wrapped in
  # single quotes, with embedded single quotes escaped as '\''
  def rsync_rsh_quote(arg)
    return arg if arg =~ /\A[^\s'"\\]+\z/

    "'" + arg.gsub("'", "'\\\\''") + "'"
  end
end
