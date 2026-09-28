require 'json'
require 'uri'
require_relative 'http_client'

class HomeAssistant
	# entities: optional list of entity ids (e.g. ["person.alice"]) to check.
	# When omitted, every person.* entity is checked, which needs a fetch of
	# all Home Assistant states.
	def initialize(url, token, entities: nil)
		@url = url.to_s.chomp('/')
		@token = token
		@entities = Array(entities)
	end

	def people_home
		fetch_people.select  { |p| p['state'] == 'home' }
		            .collect { |p| p.dig('attributes', 'friendly_name') || p['entity_id'] }
	end

	private

	def fetch_people
		if @entities.empty?
			states = get_json('/api/states')
			states.select { |entity| entity['entity_id'].to_s.start_with?('person.') }
		else
			@entities.map { |id| get_json("/api/states/#{URI.encode_www_form_component(id)}") }
		end
	end

	def get_json(path)
		uri = URI("#{@url}#{path}")
		req = Net::HTTP::Get.new(uri)
		req['Authorization'] = "Bearer #{@token}"
		req['Content-Type'] = 'application/json'

		res = HttpClient.perform(uri, req)

		unless res.is_a?(Net::HTTPSuccess)
			raise "Home Assistant error: #{res.code} #{res.message} #{res.body}"
		end

		JSON.parse(res.body)
	rescue JSON::ParserError => e
		raise "Home Assistant returned invalid JSON: #{e.message}"
	end
end
