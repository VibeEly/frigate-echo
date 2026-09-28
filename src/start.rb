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
EXPORT_WAIT_TIMEOUT   = 2 * 60      # give up waiting on a Frigate export after 2 minutes
EXPORT_METADATA_WAIT_TIMEOUT = 30    # give up waiting on Frigate to report a video_path after 30 seconds

logger = Logger.new(STDOUT)
logger.level = Logger::INFO

# Check config for required values
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
		strict_host_key_checking: rb_config.fetch(:strict_host_key_checking, true),
		bandwidth_limit: rb_config[:bandwidth_limit] || 0
	)
	logger.info("Remote backup enabled: #{rb_config[:user]}@#{rb_config[:host]}:#{rb_config[:path]}")
else
	remote_backup = nil
end

last_remote_prune_at = nil

# Get Frigate video path via GET /api/exports/:id
# Poll until it reports a video_path. Set by EXPORT_METADATA_WAIT_TIMEOUT 
def wait_for_video_path(frigate, id, timeout:, logger:, internal_id:)
	deadline = Time.now + timeout

	loop do
		export = frigate.get(id)
		return export['video_path'] if export && export['video_path']

		if Time.now > deadline
			logger.warn("#{internal_id} Timed out waiting for Frigate to report a video_path for export #{id}")
			return nil
		end

		sleep 1
	end
end

# Waits for Frigate to finish writing the export file, by polling its size
# until it stops changing. Set by EXPORT_WAIT_TIMEOUT 
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

				# Is it a concluded alert message?
				next unless message.end_alert?

				logger.info("#{message.internal_id} Alert received on camera \"#{message.camera_name}\"")

				# Is anyone home?
				if home_assistant
					people_home = home_assistant.people_home
					unless people_home.empty?
						logger.info("#{message.internal_id} Ignoring alert. The following people are home: #{people_home.join(', ')}.")
						next
					end
				end

				# Export the video
				buffer      = 5
				start_time  = message.start_time - buffer
				end_time    = message.end_time   + buffer

				res = frigate.create(message.camera_name, start_time, end_time)

				# Move the file
				id = res['export_id']

				logger.info "#{message.internal_id} Frigate export id: #{id}"

				# Ask Frigate for the export's filename 
				video_path = wait_for_video_path(frigate, id, timeout: EXPORT_METADATA_WAIT_TIMEOUT, logger: logger, internal_id: message.internal_id)

				if video_path.nil?
					logger.warn("#{message.internal_id} Skipping this alert; no video_path reported for export #{id}.")
					next
				end

				filename = File.basename(video_path)
				filepath = File.join(FRIGATE_EXPORTS, filename)

				unless wait_for_export(filepath, timeout: EXPORT_WAIT_TIMEOUT, logger: logger, internal_id: message.internal_id)
					logger.warn("#{message.internal_id} Skipping this alert; export never completed.")
					next
				end

				logger.info "#{message.internal_id} Frigate export complete."

				human_time = Time.at(start_time).localtime.strftime("%Y%m%d%H%M%S")
				stored_path = File.join(ECHO_STORAGE, "#{human_time}-#{filename}")

				# Copy to local echo storage
				FileUtils.mv(filepath, stored_path)

				logger.info "#{message.internal_id} File moved to Echo storage."

				# Ship a copy offsite over rsync/SSH 
				if remote_backup
					begin
						remote_backup.upload(stored_path)
						logger.info "#{message.internal_id} File backed up to remote server."
					rescue StandardError => e
						logger.warn "#{message.internal_id} Remote backup failed: #{e.message.lines.first.to_s.strip}"
					end
				end

				# Delete export in Frigate after clip is already in Echo storage,
				begin
					frigate.delete(id)
					logger.info "#{message.internal_id} Export deleted from Frigate."
				rescue StandardError => e
					logger.warn "#{message.internal_id} Could not delete export #{id} from Frigate (clip already archived): #{e.message.lines.first.to_s.strip}"
				end

				# Trim exports folder
				if CONFIG[:retention_days]
					logger.info "Removing expired data from Echo storage."

					cutoff = Time.now - (CONFIG[:retention_days].to_i * 24 * 60 * 60)
					Dir.glob(File.join(ECHO_STORAGE, '*')).each do |path|
						next unless File.file?(path)
						File.delete(path) if File.mtime(path) < cutoff
					end

					# Trim the remote backup directory files
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
				# Log Errors and keep processing subsequent MQTT messages.
				logger.error("Error while processing alert: #{e.class}: #{e.message}")
				logger.error(e.backtrace.first(5).join("\n")) if e.backtrace
			end
		end
	end
rescue Interrupt
  logger.info("\nExiting...")
end