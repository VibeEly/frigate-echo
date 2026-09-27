require 'json'

class Message

  class ParseError < StandardError; end

  def initialize(json_string)
    @json = JSON.parse(json_string)
  rescue JSON::ParserError => e
    # A single malformed MQTT payload shouldn't be able to crash the
    # listener — wrap it in our own error type so callers can rescue it
    # specifically and move on to the next message.
    raise ParseError, "invalid message JSON: #{e.message}"
  end

  def end_alert?
    @json['type'] == 'end' &&
    @json.dig('before', 'severity') == 'alert'
  end

  def internal_id
    @json.dig('after', 'id').to_s.split('-').last
  end

  def camera_name
    @json.dig('after', 'camera')
  end

  def start_time
    @json.dig('after', 'start_time')
  end

  def end_time
    @json.dig('after', 'end_time')
  end

end
