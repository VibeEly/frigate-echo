$stdout.sync = true

require 'logger'
require 'mqtt'
require 'securerandom'

require_relative 'home_assistant'
require_relative 'frigate'
require_relative 'config'
require_relative 'message'
require_relative 'remote_backup'
require_relative 'alert_worker'
require_relative 'maintenance'

CONFIG = Config.load('config/config.yml')

FRIGATE_EXPORTS = '/mnt/frigate_exports'
ECHO_STORAGE    = '/mnt/echo_storage'
EXPORT_WAIT_TIMEOUT = 2 * 60       # give up waiting on a Frigate export after 2 minutes
MQTT_RECONNECT_MAX_DELAY = 60       # seconds

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

frigate_config = CONFIG[:frigate]
require_config!(frigate_config, :password) if frigate_config[:user]
frigate_config[:export_start] ||= 5
frigate_config[:export_end] ||= 5

frigate = FrigateExport.new(
	frigate_config[:url],
	frigate_config[:api_key],
	user: frigate_config[:user],
	password: frigate_config[:password],
	verify_ssl: frigate_config.fetch(:verify_ssl, true),
	cookie_name: frigate_config[:cookie_name] || 'frigate_token'
)

if CONFIG[:home_assistant]
	require_config!(CONFIG[:home_assistant], :url, :token)
	home_assistant = HomeAssistant.new(
		CONFIG[:home_assistant][:url],
		CONFIG[:home_assistant][:token],
		entities: CONFIG[:home_assistant][:entities]
	)
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

# Optional retention. Must be a whole number of days. 
# If 0 all clips are retained and nothing deleted.
retention_days = CONFIG[:retention_days].to_i.nonzero?


worker = AlertWorker.new(
	frigate: frigate,
	exports_dir: FRIGATE_EXPORTS,
	storage_dir: ECHO_STORAGE,
	remote_backup: remote_backup,
	logger: logger,
	export_timeout: EXPORT_WAIT_TIMEOUT
).start

Maintenance.new(
	storage_dir: ECHO_STORAGE,
	remote_backup: remote_backup,
	retention_days: retention_days,
	logger: logger
).start

# Handles one MQTT message. 
handle_message = lambda do |message_str|
	begin
		message = Message.new(message_str)

		# Is it a concluded alert message?
		next unless message.end_alert?

		id = message.internal_id

		logger.info("#{id} Alert received on camera \"#{message.camera_name}\"")

		if message.camera_name.to_s.empty? || message.start_time.nil?
			logger.warn("#{id} Skipping alert; message has no camera or start_time.")
			next
		end

		# Is anyone home? If Home Assistant cannot be reached, still export backup
		if home_assistant
			begin
				people_home = home_assistant.people_home
				unless people_home.empty?
					logger.info("#{id} Ignoring alert. The following people are home: #{people_home.join(', ')}.")
					next
				end
			rescue StandardError => e
				logger.warn("#{id} Could not check Home Assistant, exporting anyway: #{e.message.lines.first.to_s.strip}")
			end
		end

		worker.enqueue(ExportJob.new(
			internal_id: id,
			camera: message.camera_name,
			start_time: message.start_time - frigate_config[:export_start],
			end_time: (message.end_time || Time.now.to_f) + frigate_config[:export_end]
		))

		logger.info("#{id} Export queued.")
	rescue Message::ParseError => e
		logger.warn("Skipping unparseable MQTT message: #{e.message}")
	rescue StandardError => e
		# Log Errors and keep processing subsequent MQTT messages.
		logger.error("Error while processing alert: #{e.class}: #{e.message}")
		logger.error(e.backtrace.first(5).join("\n")) if e.backtrace
	end
end

# Connect to MQTT, reconnecting with backoff if the broker goes away.
begin
	reconnect_delay = 1

	loop do
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
				reconnect_delay = 1

				client.get(CONFIG[:mqtt][:topic]) do |_topic, message_str|
					handle_message.call(message_str)
				end
			end

			logger.warn("MQTT connection closed.")
		rescue StandardError, MQTT::Exception => e
			# MQTT::Exception does not inherit from StandardError.
			logger.warn("MQTT connection lost: #{e.class}: #{e.message}")
		end

		logger.info("Reconnecting to MQTT in #{reconnect_delay}s")
		sleep reconnect_delay
		reconnect_delay = [reconnect_delay * 2, MQTT_RECONNECT_MAX_DELAY].min
	end
rescue Interrupt
	logger.info("\nExiting...")
end
