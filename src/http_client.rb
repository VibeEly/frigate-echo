require 'net/http'
require 'uri'

# Shared helper for making outbound HTTP(S) requests.
module HttpClient
  OPEN_TIMEOUT = 5    # seconds to establish a connection
  READ_TIMEOUT = 15   # seconds to wait for a response

  def self.perform(uri, req)
    Net::HTTP.start(
      uri.hostname,
      uri.port,
      use_ssl: uri.scheme == 'https',
      open_timeout: OPEN_TIMEOUT,
      read_timeout: READ_TIMEOUT
    ) { |http| http.request(req) }
  end
end
