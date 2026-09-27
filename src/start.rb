$stdout.sync = true

require 'logger'
require 'mqtt'
require 'fileutils'
require 'securerandom'

require_relative 'home_assistant'
require_relative 'frigate'
require_relative 'config'
require_relative 'message'
require_relative 'remote_backup'

CONFIG = Config.load('config/config.yml')

FRIGATE_EXPORTS = '/mnt/frigate_exports'
ECHO_STORAGE    = '/mnt/echo_storage'
REMOTE_PRUNE_INTERVAL = 24 * 60 * 60 # only prune the remote backup once per day
EXPORT_WAIT_TIMEOUT   = 10 * 60      # give up waiting on a Frigate export after 10 minutes

logger = Logger.new(STDOUT)
logger.level = Logger::INFO

# Fail fast with a clear message instead of a NoMethodError deep in a class
# if required config is missing.
def require_config!(config, *keys)
  keys.each do |key|
    if config[key].nil? || config[key].to_s.empty?
      raise "Missing required config key: #{key}"
    end
  end
end

require_config!(CONFIG[:mqtt] || {}, :server, :topic)
require_config!(CONFIG[:frigate] || {}, :url)

frigate = FrigateExport.new(CONFIG[:frigate][:url], CONFIG[:frigate][:api_key])

if CONFIG[:home_assistant]
	require_config!(CONFIG[:home_assistant], :url, :token)
	home_assistant = HomeAssistant.new(CONFIG[:home_assistant][:url], CONFIG[:home_assistant][:token])
else
	home_assistant = nil
end

if CONFIG[:remote_backup]
	rb_config = CONFIG[:remote_backup]
	require_config!(rb_config, :host, :user, :path)
	remote_backup = RemoteBackup.new(
		host: rb_config[:host],
		user: rb_config[:user],
		path: rb_config[:path],
		port: rb_config[:port] || 22,
		identity_file: rb_config[:identity_file],
		known_hosts_file: rb_config[:known_hosts_file],
		strict_host_key_checking: rb_config.fetch(:strict_host_key_checking, true)
	)
	logger.info("Remote backup enabled: #{rb_config[:user]}@#{rb_config[:host]}:#{rb_config[:path]}")
else
	remote_backup = nil
end

last_remote_prune_at = nil

# Waits for Frigate to finish writing the export file, by polling its size
# until it stops changing. Bounded by EXPORT_WAIT_TIMEOUT so a stalled or
# failed export can't wedge the process forever.
def wait_for_export(filepath, timeout:, logger:, internal_id:)
	last_size = -1
	deadline = Time.now + timeout

	loop do
		if File.exist?(filepath)
			current_size = File.size(filepath)
			return true if current_size == last_size
			last_size = current_size
		end

		if Time.now > deadline
			logger.warn("#{internal_id} Timed out waiting for Frigate export file: #{filepath}")
			return false
		end

		sleep 1
	end
end

# connect to MQTT

begin
	logger.info("Connecting to MQTT at #{CONFIG[:mqtt][:server]}")

	mqtt_options = {
		host: CONFIG[:mqtt][:server],
		client_id: "frigate-echo-#{SecureRandom.hex(4)}"
	}
	# Only send credentials if they were actually configured, rather than
	# passing empty strings to the broker.
	mqtt_options[:username] = CONFIG[:mqtt][:username] unless CONFIG[:mqtt][:username].to_s.empty?
	mqtt_options[:password] = CONFIG[:mqtt][:password] unless CONFIG[:mqtt][:password].to_s.empty?

	MQTT::Client.connect(mqtt_options) do |client|
		logger.info("Connected. Listening to topic #{CONFIG[:mqtt][:topic]}")

		client.get(CONFIG[:mqtt][:topic]) do |topic, message_str|
			begin
				message = Message.new(message_str)

				# is it a concluded alert message?
				next unless message.end_alert?

				logger.info("#{message.internal_id} Alert received on camera \"#{message.camera_name}\"")

				# is anyone home?

				if home_assistant
					people_home = home_assistant.people_home
					unless people_home.empty?
						logger.info("#{message.internal_id} Ignoring alert. The following people are home: #{people_home.join(', ')}.")
						next
					end
				end

				# export the video

				buffer      = 5
				start_time  = message.start_time - buffer
				end_time    = message.end_time   + buffer

				res = frigate.create(message.camera_name, start_time, end_time)

				# move the file

				id = res['export_id']

				logger.info "#{message.internal_id} Frigate export id: #{id}"

				# Frigate names the export file after its own export id (e.g. "<id>.mp4"),
				# so we can wait for that exact file instead of pattern-matching the
				# whole exports folder.
				filename = "#{id}.mp4"
				filepath = File.join(FRIGATE_EXPORTS, filename)

				unless wait_for_export(filepath, timeout: EXPORT_WAIT_TIMEOUT, logger: logger, internal_id: message.internal_id)
					logger.warn("#{message.internal_id} Skipping this alert; export never completed.")
					next
				end

				logger.info "#{message.internal_id} Frigate export complete."

				human_time = Time.at(start_time).localtime.strftime("%Y%m%d%H%M%S")
				stored_path = File.join(ECHO_STORAGE, "#{human_time}-#{filename}")

				# FileUtils.mv instead of a shelled-out `mv` string: this avoids
				# passing filenames through a shell entirely (so nothing in a
				# Frigate-provided export id can be interpreted as shell syntax),
				# and it raises on failure instead of silently doing nothing.
				FileUtils.mv(filepath, stored_path)

				logger.info "#{message.internal_id} File moved to Echo storage."

				# ship a copy offsite over rsync/SSH — this is a best-effort backup on
				# top of Echo storage, so a failure here is logged, not fatal

				if remote_backup
					begin
						remote_backup.upload(stored_path)
						logger.info "#{message.internal_id} File backed up to remote server."
					rescue StandardError => e
						logger.warn "#{message.internal_id} Remote backup failed: #{e.message.lines.first.to_s.strip}"
					end
				end

				# delete export in frigate — the clip is already safe in Echo storage,
				# so a failure here (API change, Frigate restarting) is logged, not fatal

				begin
					frigate.delete(id)
					logger.info "#{message.internal_id} Export deleted from Frigate."
				rescue StandardError => e
					logger.warn "#{message.internal_id} Could not delete export #{id} from Frigate (clip already archived): #{e.message.lines.first.to_s.strip}"
				end

				# trim exports folder

				if CONFIG[:retention_days]
					logger.info "Removing expired data from Echo storage."

					cutoff = Time.now - (CONFIG[:retention_days].to_i * 24 * 60 * 60)
					Dir.glob(File.join(ECHO_STORAGE, '*')).each do |path|
						next unless File.file?(path)
						File.delete(path) if File.mtime(path) < cutoff
					end

					# trim the remote backup directory too, but at most once per
					# day. Best-effort, so a failure here is logged, not fatal. The
					# timestamp is updated whether or not the prune succeeds, so a
					# failing remote host doesn't get hammered every alert either.
					if remote_backup && (last_remote_prune_at.nil? || Time.now - last_remote_prune_at >= REMOTE_PRUNE_INTERVAL)
						last_remote_prune_at = Time.now

						begin
							remote_backup.prune(CONFIG[:retention_days])
							logger.info "Removed expired data from remote backup."
						rescue StandardError => e
							logger.warn "Could not prune remote backup: #{e.message.lines.first.to_s.strip}"
						end
					end
				end
			rescue Message::ParseError => e
				logger.warn("Skipping unparseable MQTT message: #{e.message}")
			rescue StandardError => e
				# A single bad alert (Frigate API hiccup, unexpected payload shape,
				# etc.) should never take down the whole listener — log it and keep
				# processing subsequent MQTT messages.
				logger.error("Error while processing alert: #{e.class}: #{e.message}")
				logger.error(e.backtrace.first(5).join("\n")) if e.backtrace
			end
		end
	end
rescue Interrupt
  logger.info("\nExiting...")
end
