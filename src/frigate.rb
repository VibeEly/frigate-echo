require 'json'
require 'uri'
require_relative 'http_client'

class FrigateExport
	class Error < StandardError; end

	# Authentication:
	# * Port 5000 (unauthenticated): leave api_key, user and password unset.
	# * Port 8971 (authenticated): set user + password. Echo logs in via
	#   POST /api/login, keeps the returned JWT and logs in again when it expires.
	# * api_key: a JWT you obtained yourself. It expires (24h by default), so
	#   prefer user/password for anything long-running.
	def initialize(url, api_key = nil, user: nil, password: nil, verify_ssl: true, cookie_name: 'frigate_token')
		@url         = url.to_s.chomp('/')
		@token       = api_key
		@user        = user
		@password    = password
		@verify_ssl  = verify_ssl
		@cookie_name = cookie_name
	end

	# Returns the export record for a single export, or nil if Frigate does not
	# know about it (yet).
	def get(id)
		res = request_raw("/api/exports/#{escape_path_segment(id)}", :get)
		return nil if res.kind_of?(Net::HTTPNotFound)
		raise_unless_success(res)
		parse_json(res.body)
	end

	def list
		res = request("/api/exports", :get)

		exports = parse_json(res.body)
		exports.sort_by { |e| e['date'] }
	end

	# Polls the export record until Frigate reports the export as finished.
	# Returns the export record, or nil on timeout.
	#
	# Frigate marks an export "in_progress" until ffmpeg is done, so that flag is
	# the source of truth. Versions that do not report the flag return the record
	# as soon as it has a video_path; the caller then has to check the file itself.
	def wait_until_complete(id, timeout:, interval: 2)
		deadline = Time.now + timeout

		loop do
			export = get(id)

			if export && export['video_path']
				return export if export['in_progress'] == false
				return export unless export.key?('in_progress')
			end

			return nil if Time.now > deadline

			sleep interval
		end
	end

	# Frigate 0.18 removed DELETE /api/export/{id} in favour of a bulk
	# endpoint, POST /api/exports/delete {"ids": [...]}.
	# Older versions do not have the bulk route (404 or 405), so fall back.
	def delete(id)
		res = request_raw("/api/exports/delete", :post, { ids: [id] })

		if res.kind_of?(Net::HTTPNotFound) || res.kind_of?(Net::HTTPMethodNotAllowed)
			res = request_raw("/api/export/#{escape_path_segment(id)}", :delete)
		end

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
			raise Error, "Frigate export response did not include an export_id. Body: #{res.body}"
		end

		parsed
	end

	private

	# Percent encodes a value for use as a single URL path segment.
	def escape_path_segment(value)
		URI::DEFAULT_PARSER.escape(value.to_s, /[^a-zA-Z0-9\-_.]/)
	end

	def parse_json(body)
		JSON.parse(body)
	rescue JSON::ParserError => e
		raise Error, "Frigate returned invalid JSON: #{e.message}"
	end

	def request(uri, method, body = nil)
		res = request_raw(uri, method, body)
		raise_unless_success(res)
		res
	end

	def raise_unless_success(res)
		unless res.kind_of?(Net::HTTPSuccess)
			raise Error, "Frigate error: #{res.code} #{res.message}\nBody: #{res.body}"
		end
	end

	# Performs the API request, logging in first when credentials are configured
	# and logging in again if Frigate says the token is no longer valid.
	def request_raw(uri, method, body = nil)
		login if @token.nil? && @user

		res = send_request(uri, method, body)

		if res.kind_of?(Net::HTTPUnauthorized) && @user
			login
			res = send_request(uri, method, body)
		end

		res
	end

	def send_request(uri, method, body)
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

		req['Authorization'] = "Bearer #{@token}" if @token

		if body
			req['Content-Type'] = 'application/json'
			req.body = JSON.dump(body)
		end

		HttpClient.perform(url, req, verify_ssl: @verify_ssl)
	end

	# POST /api/login; the JWT comes back in a cookie and is also accepted as a
	# Bearer token.
	def login
		url = URI("#{@url}/api/login")
		req = Net::HTTP::Post.new(url)
		req['Content-Type'] = 'application/json'
		req.body = JSON.dump(user: @user, password: @password)

		res = HttpClient.perform(url, req, verify_ssl: @verify_ssl)

		unless res.kind_of?(Net::HTTPSuccess)
			@token = nil
			raise Error, "Frigate login failed: #{res.code} #{res.message}"
		end

		token = extract_cookie(res, @cookie_name)
		raise Error, "Frigate login response did not set a #{@cookie_name} cookie" unless token

		@token = token
	end

	def extract_cookie(res, name)
		Array(res.get_fields('set-cookie')).each do |line|
			match = line.match(/\A\s*#{Regexp.escape(name)}=([^;]+)/)
			return match[1] if match
		end

		nil
	end
end
