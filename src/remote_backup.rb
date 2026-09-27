require 'open3'
require 'shellwords'


# * Only key-based SSH auth is supported (no password prompts) 
# * Host key checking defaults to "yes", meaning the remote host must already
#   be present in a known_hosts file (either the default one, or the one
#   given via `known_hosts_file`). This protects against MITM/spoofed hosts.
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
  def prune(retention_days)
    days = Integer(retention_days)
    remote_dir = ensure_trailing_slash(@path).chomp('/')

    # Executed string on remote shell 
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

  # Builds argv for invoking `ssh` directly via Open3 
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

  # Builds the string passed to rsync's `-e` flag. 
  def build_ssh_command
    ssh_argv.map { |arg| rsync_rsh_quote(arg) }.join(' ')
  end

  # Quotes a single argument for rsync's --rsh splitter. Anything containing
  # whitespace, a single quote, a double quote, or a backslash is wrapped in
  # single quotes, with embedded single quotes escaped as '\'' so they
  # can't break out of the quoting.
  def rsync_rsh_quote(arg)
    return arg if arg =~ /\A[^\s'"\\]+\z/

    "'" + arg.gsub("'", "'\\\\''") + "'"
  end
end
