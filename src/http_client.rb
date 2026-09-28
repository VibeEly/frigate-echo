require 'net/http'
require 'openssl'
require 'uri'

# Shared helper for making outbound HTTP(S) requests.
module HttpClient
  OPEN_TIMEOUT = 5    # seconds to establish a connection
  READ_TIMEOUT = 15   # seconds to wait for a response

  # verify_ssl: false is needed for Frigate's authenticated port (8971),
  # which serves a self-signed certificate by default.
  def self.perform(uri, req, verify_ssl: true)
    https = uri.scheme == 'https'

    options = {
      use_ssl: https,
      open_timeout: OPEN_TIMEOUT,
      read_timeout: READ_TIMEOUT
    }
    options[:verify_mode] = OpenSSL::SSL::VERIFY_NONE if https && !verify_ssl

    Net::HTTP.start(uri.hostname, uri.port, **options) { |http| http.request(req) }
  end
end
