$stdout.sync = true

require 'logger'
require 'mqtt'

require_relative 'home_assistant'
require_relative 'frigate'
require_relative 'config'
require_relative 'message'
require_relative 'remote_backup'

CONFIG = Config.load('config/config.yml')

FRIGATE_EXPORTS = '/mnt/frigate_exports'
ECHO_STORAGE    = '/mnt/echo_storage'
REMOTE_PRUNE_INTERVAL = 24 * 60 * 60 # only prune the remote backup once per day

logger = Logger.new(STDOUT)
logger.level = Logger::INFO

frigate = FrigateExport.new(CONFIG[:frigate][:url], CONFIG[:frigate][:api_key])

if CONFIG[:home_assistant]
	home_assistant = HomeAssistant.new(CONFIG[:home_assistant][:url], CONFIG[:home_assistant][:token])
else
	home_assistant = nil
end

if CONFIG[:remote_backup]
	rb_config = CONFIG[:remote_backup]
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

# connect to MQTT

begin
	# Testing, delete after:
	logger.info("MQTT user: #{CONFIG[:mqtt][:username].inspect}, password present: #{!CONFIG[:mqtt][:password].to_s.empty?}")

	logger.info("Connecting to MQTT new at #{CONFIG[:mqtt][:server]}")
	
	# Added username and password fields for MQTT from new config.yml values
  MQTT::Client.connect(host: CONFIG[:mqtt][:server], username:CONFIG[:mqtt][:username], password:CONFIG[:mqtt][:password], client_id:"figate-echo-018-fork") do |client|
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

    	# Frigate names the export file after its own export id (e.g. "<id>.mp4"),
    	# so we can wait for that exact file instead of pattern-matching the
    	# whole exports folder — which was the source of the old-video bug:
    	# `id.split("_")` only gives the first two segments (not the true
    	# first/last), so for a camera name containing an underscore (e.g.
    	# "front_door") the old regex degraded into "front.+door", matching
    	# ANY export for that camera — including a stale leftover one — rather
    	# than the export that was just created.
    	filename = "#{id}.mp4"
    	filepath = File.join(FRIGATE_EXPORTS, filename)
    	last_size = -1

    	begin
    		if File.exist?(filepath)
    			current_size = File.size(filepath)
    			break if current_size == last_size

    			last_size = current_size
    		end

  			sleep 1
    	end while true

			logger.info "#{message.internal_id} Frigate export complete."

    	human_time = Time.at(start_time).localtime.strftime("%Y%m%d%H%M%S")
    	stored_path = "#{ECHO_STORAGE}/#{human_time}-#{filename}"
    	`mv #{FRIGATE_EXPORTS}/#{filename} #{stored_path}`

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
				`find #{ECHO_STORAGE} -type f -mtime +#{CONFIG[:retention_days]} -delete`

				# trim the remote backup directory too, but at most once per
				# day
				# best-effort, so a failure here is logged, not fatal. The
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
    end
  end
rescue Interrupt
  logger.info("\nExiting...")
end