require 'net/http'
require 'json'
require 'uri'

class FrigateExport
	def initialize(url, api_key)
		@url = url
		@api_key = api_key
	end

	def list
		res = request("/api/exports", :get)

		exports = JSON.parse(res.body)
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

		res = request("/api/export/#{camera}/start/#{start_time}/end/#{end_time}", :post, body)

		unless [Net::HTTPSuccess, Net::HTTPCreated].any? { |i| res.kind_of?(i) }
			raise "Error: #{res.code} #{res.message}\nBody: #{res.body}"
		end

		JSON.parse(res.body)
	end

	private

	def request(uri, method, body = nil)
		res = request_raw(uri, method, body)
		raise_unless_success(res)
		res
	end

	def raise_unless_success(res)
		unless res.kind_of?(Net::HTTPSuccess)
			raise "Error: #{res.code} #{res.message}\nBody: #{res.body}"
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

		Net::HTTP.start(url.hostname, url.port) { |http| http.request(req) }
	end
end
