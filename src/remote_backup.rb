require 'open3'
require 'shellwords'

# Ships a local file to a remote host over rsync-via-SSH.
#
# Security notes:
# * Only key-based SSH auth is supported (no password prompts) — BatchMode=yes
#   makes this explicit and causes a fast failure instead of hanging on a
#   prompt if a key isn't set up correctly.
# * Host key checking defaults to "yes", meaning the remote host must already
#   be present in a known_hosts file (either the default one, or the one
#   given via `known_hosts_file`). This protects against MITM/spoofed hosts.
#   Only disable this if you fully understand the risk.
# * All command arguments passed to Open3 are given as array elements (never
#   interpolated into a shell string), so nothing in a filename or config
#   value can be used to inject extra shell commands into *our own* process.
# * The one place a shell string genuinely has to be built — rsync's `-e`
#   flag, which rsync itself hands to a shell to launch ssh — is assembled
#   with Shellwords so that a value such as an identity_file path containing
#   a space or a quote can't break out of it.
class RemoteBackup
  class Error < StandardError; end

  def initialize(host:, user:, path:, port: 22, identity_file: nil,
                 known_hosts_file: nil, strict_host_key_checking: true,
                 rsync_bin: 'rsync')
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
  end

  # Uploads a single local file to the configured remote directory.
  # Returns true on success, raises RemoteBackup::Error on failure.
  def upload(local_path)
    unless File.file?(local_path)
      raise Error, "Local file not found: #{local_path}"
    end

    remote_target = "#{@user}@#{@host}:#{ensure_trailing_slash(@path)}"

    cmd = [
      @rsync_bin,
      '-az',            # archive mode + compression
      '--partial',      # keep partially transferred files so retries can resume
      '--timeout=60',
      '-e', build_ssh_command,
      local_path,
      remote_target
    ]

    stdout, stderr, status = Open3.capture3(*cmd)

    unless status.success?
      raise Error, "rsync exited with #{status.exitstatus}: #{stderr.strip.empty? ? stdout.strip : stderr.strip}"
    end

    true
  end

  # Deletes files older than `retention_days` from the remote backup
  # directory, mirroring the local Echo storage cleanup in start.rb.
  # Returns true on success, raises RemoteBackup::Error on failure.
  def prune(retention_days)
    days = Integer(retention_days)
    remote_dir = ensure_trailing_slash(@path).chomp('/')

    # This string is executed by the *remote* shell (ssh concatenates
    # trailing argv elements and hands them to the remote user's shell),
    # so the path is Shellwords-escaped here — unlike ssh_argv itself,
    # which is passed straight to Open3 with no shell involved.
    remote_find_cmd = "find #{Shellwords.escape(remote_dir)} -type f -mtime +#{days} -delete"

    cmd = ssh_argv + ["#{@user}@#{@host}", remote_find_cmd]

    stdout, stderr, status = Open3.capture3(*cmd)

    unless status.success?
      raise Error, "remote prune exited with #{status.exitstatus}: #{stderr.strip.empty? ? stdout.strip : stderr.strip}"
    end

    true
  end

  private

  def ensure_trailing_slash(path)
    path.end_with?('/') ? path : "#{path}/"
  end

  # Builds argv for invoking `ssh` directly via Open3 (no shell in between),
  # so no quoting/escaping of these elements is needed or wanted.
  def ssh_argv
    argv = ['ssh', '-p', @port.to_s, '-o', 'BatchMode=yes']

    argv += ['-i', @identity_file] if @identity_file

    if @strict_host_key_checking
      argv += ['-o', 'StrictHostKeyChecking=yes']
      argv += ['-o', "UserKnownHostsFile=#{@known_hosts_file}"] if @known_hosts_file
    else
      argv += ['-o', 'StrictHostKeyChecking=no']
    end

    argv
  end

  # Builds the string passed to rsync's `-e` flag. rsync itself hands this
  # string to a shell, so — unlike ssh_argv above — every element needs
  # proper shell quoting. Reusing ssh_argv and joining it with Shellwords
  # guarantees the two commands never drift apart and that a value
  # containing a space or a single quote (e.g. an oddly-named
  # known_hosts_file path) can't break out of the string or inject
  # additional shell commands.
  #
  # NOTE: the previous implementation built this string by hand-wrapping
  # values in single quotes (e.g. "'#{@identity_file}'") instead of using
  # Shellwords. That does not escape single quotes *inside* the value, so a
  # path containing one could break out of the quoting and inject arbitrary
  # shell commands into the `-e` string that rsync executes.
  def build_ssh_command
    Shellwords.join(ssh_argv)
  end
end
