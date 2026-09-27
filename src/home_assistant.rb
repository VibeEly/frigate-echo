require 'json'
require 'uri'
require_relative 'http_client'

class HomeAssistant
	def initialize(url, token)
		@url = url
		@token = token
	end

	def people_home
		fetch_people.select  { |p| p['state'] == 'home' }
		            .collect { |p| p['attributes']['friendly_name'] }
	end

	private

	def fetch_people
	  uri = URI("#{@url}/api/states")
	  req = Net::HTTP::Get.new(uri)
	  req['Authorization'] = "Bearer #{@token}"
	  req['Content-Type'] = 'application/json'

	  res = HttpClient.perform(uri, req)

	  unless res.is_a?(Net::HTTPSuccess)
	    raise "Home Assistant error: #{res.code} #{res.message} #{res.body}"
	  end

	  states = JSON.parse(res.body)
		states.select { |entity| entity['entity_id'].start_with?('person.') }
	rescue JSON::ParserError => e
	  raise "Home Assistant returned invalid JSON: #{e.message}"
	end
end
