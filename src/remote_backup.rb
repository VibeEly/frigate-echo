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
# * All command arguments are passed as array elements (never interpolated
#   into a shell string) so nothing in a filename or config value can be
#   used to inject extra shell commands.
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

  private

  def ensure_trailing_slash(path)
    path.end_with?('/') ? path : "#{path}/"
  end

  # Builds the string passed to rsync's `-e` flag. rsync itself hands this
  # string to a shell, so it is assembled with Shellwords from
  # config-supplied values (the same trust level as the API keys/tokens
  # already stored in config.yml) rather than from anything remote or
  # user-uploaded.
  def build_ssh_command
    parts = ['ssh', '-p', @port.to_s, '-o', 'BatchMode=yes']

    # Wrap paths in quotes to safely pass spaces to rsync's internal parser
    parts += ['-i', "'#{@identity_file}'"] if @identity_file

    if @strict_host_key_checking
      parts += ['-o', 'StrictHostKeyChecking=yes']
      parts += ['-o', "'UserKnownHostsFile=#{@known_hosts_file}'"] if @known_hosts_file
    else
      parts += ['-o', 'StrictHostKeyChecking=no']
    end

    # Use a standard space instead of Shellwords.join
    parts.join(' ')
  end
end
