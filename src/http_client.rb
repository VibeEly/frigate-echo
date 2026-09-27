require 'net/http'
require 'uri'

# Shared helper for making outbound HTTP(S) requests.
#
# Fixes a real bug present in the original code: Net::HTTP.start was called
# with no `use_ssl:` option, so an `https://` URL (e.g. a Home Assistant
# instance behind a reverse proxy) would silently fall back to a *plaintext*
# connection on port 443 instead of either using TLS or failing loudly. That
# would leak the bearer token/API key on the wire.
module HttpClient
  OPEN_TIMEOUT = 5    # seconds to establish a connection
  READ_TIMEOUT = 15   # seconds to wait for a response

  # Performs `req` against `uri` and returns the Net::HTTPResponse.
  # Never hangs indefinitely (unlike the original, which used the Ruby
  # defaults of "no timeout" for both connect and read).
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
