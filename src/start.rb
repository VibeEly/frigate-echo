$stdout.sync = true

require 'logger'
require 'mqtt'

require_relative 'home_assistant'
require_relative 'frigate'
require_relative 'config'
require_relative 'message'

CONFIG = Config.load('config/config.yml')

FRIGATE_EXPORTS = '/mnt/frigate_exports'
ECHO_STORAGE    = '/mnt/echo_storage'

logger = Logger.new(STDOUT)
logger.level = Logger::INFO

frigate = FrigateExport.new(CONFIG[:frigate][:url], CONFIG[:frigate][:api_key])

if CONFIG[:home_assistant]
	home_assistant = HomeAssistant.new(CONFIG[:home_assistant][:url], CONFIG[:home_assistant][:token])
else
	home_assistant = nil
end

# connect to MQTT

begin
	logger.info("Connecting to MQTT at #{CONFIG[:mqtt][:server]}")
	
	mqtt_options = {
		host:     CONFIG[:mqtt][:server],
		username: CONFIG[:mqtt][:username],
		password: CONFIG[:mqtt][:password],
	}
	mqtt_options[:port] = CONFIG[:mqtt][:port] if CONFIG[:mqtt][:port]

  MQTT::Client.connect(mqtt_options) do |client|
  	logger.info("Connected. Listening to topic #{CONFIG[:mqtt][:topic]}")
    
    client.get(CONFIG[:mqtt][:topic]) do |topic, message_str|
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
    	end_time  	= message.end_time   + buffer

    	res = frigate.create(message.camera_name, start_time, end_time) 

    	# move the file

    	id = res['export_id']

    	logger.info "#{message.internal_id}Frigate export id: #{id}"

    	first_part, last_part = id.split("_")
    	last_size = "-1"

    	begin    	
    		if m = `ls -s #{FRIGATE_EXPORTS}`.match(/\n\s*(?<size>\d+) (?<filename>#{first_part}.+#{last_part}[^\n]+)/) 
    			break if m[:size] == last_size

    			last_size = m[:size]
    		end
	
  			sleep 1
    	end while true

			logger.info "#{message.internal_id} Frigate export complete."

    	filename = m[:filename]

    	human_time = Time.at(start_time).localtime.strftime("%Y%m%d%H%M%S")
    	`mv #{FRIGATE_EXPORTS}/#{filename} #{ECHO_STORAGE}/#{human_time}-#{filename}`

    	logger.info "#{message.internal_id} File moved to Echo storage."

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
				`find #{ECHO_STORAGE} -type f -mtime +#{CONFIG[:retention_days]} -delete`
			end
    end
  end
rescue Interrupt
  logger.info("\nExiting...")
end