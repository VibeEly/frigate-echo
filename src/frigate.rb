require 'json'
require 'uri'
require_relative 'http_client'

class FrigateExport
	def initialize(url, api_key)
		@url = url
		@api_key = api_key
	end

	def list
		res = request("/api/exports", :get)

		exports = parse_json(res.body)
		exports.sort_by { |e| e['date'] }
	end

	# Frigate 0.18 removed DELETE /api/export/{id} in favour of a bulk
	# endpoint, POST /api/exports/delete {"ids": [...]}. Try the bulk route
	# first and fall back to the legacy one when the server doesn't have it
	# (a route miss is a 404), so both old and new Frigate versions work.
	def delete(id)
		res = request_raw("/api/exports/delete", :post, { ids: [id] })
		res = request_raw("/api/export/#{id}", :delete) if res.kind_of?(Net::HTTPNotFound)
		raise_unless_success(res)
		res
	end

	def create(camera, start_time, end_time)
		body = {
			playback: 'realtime',
			source: 'recordings'
		}

		res = request("/api/export/#{escape_path_segment(camera)}/start/#{start_time.to_i}/end/#{end_time.to_i}", :post, body)

		parsed = parse_json(res.body)

		unless parsed['export_id']
			raise "Frigate export response did not include an export_id. Body: #{res.body}"
		end

		parsed
	end

	private

	# Percent-encodes a value for use as a single URL path segment. Camera
	# names come from Frigate's own MQTT payload and are normally simple
	# identifiers, but escaping defensively here means a name containing
	# "/", "?", or spaces can't be misread as a different API path.
	# (Deliberately not URI.encode_www_form_component, which encodes spaces
	# as "+" — correct for query strings, not for a path segment.)
	def escape_path_segment(value)
		URI::DEFAULT_PARSER.escape(value.to_s, /[^a-zA-Z0-9\-_.]/)
	end

	def parse_json(body)
		JSON.parse(body)
	rescue JSON::ParserError => e
		raise "Frigate returned invalid JSON: #{e.message}"
	end

	def request(uri, method, body = nil)
		res = request_raw(uri, method, body)
		raise_unless_success(res)
		res
	end

	def raise_unless_success(res)
		unless res.kind_of?(Net::HTTPSuccess)
			raise "Frigate error: #{res.code} #{res.message}\nBody: #{res.body}"
		end
	end

	# perform the request and return the response without raising
	def request_raw(uri, method, body = nil)
		url = URI("#{@url}#{uri}")

		req = case method
		when :get
			Net::HTTP::Get.new(url)
		when :delete
			Net::HTTP::Delete.new(url)
		when :post
			Net::HTTP::Post.new(url)
		else
			raise "\"#{method}\" is an unsupported method"
		end

		req['Authorization'] = "Bearer #{@api_key}" if @api_key

		if body
			req['Content-Type'] = 'application/json'
			req.body = JSON.dump(body)
		end

		HttpClient.perform(url, req)
	end
end
