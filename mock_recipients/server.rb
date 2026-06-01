#!/usr/bin/env ruby
# frozen_string_literal: true

# =============================================================================
# Mock Downstream Recipients + DNC Scrub + Postback Sender
# -----------------------------------------------------------------------------
# A single, dependency-free Ruby process (stdlib only) that stands in for the
# real third-party systems your service must integrate with. It deliberately
# exposes THREE recipients with DIFFERENT contracts (transport, auth, and
# success semantics) plus a DNC scrub endpoint, and it fires asynchronous
# "postbacks" (conversion callbacks) back to your service.
#
#   Run:    ruby mock_recipients/server.rb
#   Port:   3100 (override with PORT=4100 ruby mock_recipients/server.rb)
#
# Your service's postback receiver URL is read from CALLBACK_URL, e.g.:
#   CALLBACK_URL=http://localhost:3000/postbacks/recipients ruby mock_recipients/server.rb
#
# No gems. No bundler. Just `ruby`. See docs/RECIPIENT_APIS.md for the full
# contract of every endpoint below.
# =============================================================================

require "socket"
require "json"
require "uri"
require "net/http"
require "securerandom"
require "set"
require "time"

PORT         = (ENV["PORT"] || 3100).to_i
CALLBACK_URL = ENV["CALLBACK_URL"] # if nil, postbacks are logged but not sent

# In-memory state (resets when you restart the process)
SEEN_CLAIM_IDS  = Set.new          # for idempotency / duplicate simulation
RATE_WINDOW     = Hash.new { |h, k| h[k] = [] } # recipient => [timestamps]
MUTEX           = Mutex.new
DNC_NUMBERS     = %w[5550000001 5550000002 5550000003 5559990000].to_set

# -----------------------------------------------------------------------------
# Tiny HTTP layer (HTTP/1.1, Connection: close). Stdlib sockets only.
# -----------------------------------------------------------------------------
class Request
  attr_reader :method, :path, :query, :headers, :body

  def initialize(method, raw_path, headers, body)
    @method  = method
    uri      = URI.parse(raw_path)
    @path    = uri.path
    @query   = URI.decode_www_form(uri.query.to_s).to_h
    @headers = headers
    @body    = body
  end

  def header(name)
    headers[name.downcase]
  end

  def json
    @json ||= (JSON.parse(body) rescue {})
  end

  def form
    @form ||= URI.decode_www_form(body.to_s).to_h
  end
end

def read_request(conn)
  request_line = conn.gets
  return nil if request_line.nil?

  method, raw_path, _http = request_line.split(" ", 3)
  headers = {}
  while (line = conn.gets) && line != "\r\n" && line != "\n"
    k, v = line.split(":", 2)
    headers[k.strip.downcase] = v.to_s.strip if k && v
  end

  body = ""
  if (len = headers["content-length"]&.to_i) && len.positive?
    body = conn.read(len).to_s
  end

  Request.new(method, raw_path, headers, body)
end

def respond(conn, status, payload, content_type: "application/json", extra_headers: {})
  body =
    case payload
    when String then payload
    else JSON.generate(payload)
    end

  reason = {
    200 => "OK", 202 => "Accepted", 400 => "Bad Request", 401 => "Unauthorized",
    409 => "Conflict", 422 => "Unprocessable Entity", 429 => "Too Many Requests",
    500 => "Internal Server Error", 503 => "Service Unavailable", 404 => "Not Found"
  }.fetch(status, "OK")

  out = +"HTTP/1.1 #{status} #{reason}\r\n"
  out << "Content-Type: #{content_type}\r\n"
  out << "Content-Length: #{body.bytesize}\r\n"
  out << "Connection: close\r\n"
  extra_headers.each { |k, v| out << "#{k}: #{v}\r\n" }
  out << "\r\n"
  out << body
  conn.write(out)
end

def log(msg)
  puts "[#{Time.now.strftime('%H:%M:%S')}] #{msg}"
end

# -----------------------------------------------------------------------------
# Postback / conversion callback (fires asynchronously after acceptance)
# -----------------------------------------------------------------------------
# After a recipient "accepts" a lead, real partners later tell you what happened
# to it (signed / rejected / not_qualified). We simulate that here: a few seconds
# later we POST a conversion event to CALLBACK_URL. To exercise idempotency, the
# same postback is sent TWICE for ~1 in 4 leads.
def schedule_postback(recipient:, source_claim_id:, external_id:)
  return if source_claim_id.to_s.empty?

  Thread.new do
    sleep(rand(2..5))
    disposition = %w[signed signed rejected not_qualified].sample
    payload = {
      "recipient"       => recipient,
      "source_claim_id" => source_claim_id,
      "external_id"     => external_id,
      "disposition"     => disposition,
      "occurred_at"     => Time.now.utc.iso8601,
      # A signature you may choose to verify (see docs/RECIPIENT_APIS.md).
      "signature"       => signature_for(source_claim_id, disposition)
    }

    deliveries = rand(1..4) == 1 ? 2 : 1 # duplicate ~25% of the time
    deliveries.times do |i|
      send_postback(payload, attempt: i + 1)
      sleep(0.4) if deliveries > 1
    end
  end
end

def signature_for(source_claim_id, disposition)
  require "digest"
  Digest::SHA256.hexdigest("#{source_claim_id}:#{disposition}:mock-shared-secret")
end

def send_postback(payload, attempt:)
  unless CALLBACK_URL
    log("POSTBACK (not sent, CALLBACK_URL unset) #{payload['disposition']} for #{payload['source_claim_id']}")
    return
  end

  uri  = URI.parse(CALLBACK_URL)
  http = Net::HTTP.new(uri.host, uri.port)
  http.open_timeout = 3
  http.read_timeout = 5
  req = Net::HTTP::Post.new(uri.path.empty? ? "/" : uri.path,
                            "Content-Type" => "application/json")
  req.body = JSON.generate(payload)
  res = http.request(req)
  log("POSTBACK -> #{CALLBACK_URL} (attempt #{attempt}) #{payload['disposition']} " \
      "#{payload['source_claim_id']} => #{res.code}")
rescue => e
  log("POSTBACK FAILED -> #{CALLBACK_URL}: #{e.class}: #{e.message}")
end

# -----------------------------------------------------------------------------
# Auth + helpers
# -----------------------------------------------------------------------------
API_KEYS = {
  "apex"    => "apex-test-key-123",
  "beacon"  => "beacon-test-key-456",
  "citadel" => "citadel-test-token-789"
}.freeze

def rate_limited?(recipient, max:, per_seconds:)
  MUTEX.synchronize do
    now = Time.now.to_f
    RATE_WINDOW[recipient].reject! { |t| now - t > per_seconds }
    if RATE_WINDOW[recipient].size >= max
      true
    else
      RATE_WINDOW[recipient] << now
      false
    end
  end
end

# -----------------------------------------------------------------------------
# Route handlers
# -----------------------------------------------------------------------------
# Each handler returns [status, body_hash_or_string, extra_headers]

# ---- DNC scrub (third-party suppression check) ------------------------------
# POST /scrub/dnc   { "phone": "5551234567" }  ->  { "phone":..., "blocked": bool }
def handle_dnc(req)
  phone = req.json["phone"].to_s.gsub(/\D/, "")
  phone = phone[-10, 10] || phone # last 10 digits
  [200, { "phone" => phone, "blocked" => DNC_NUMBERS.include?(phone) }, {}]
end

# ---- Recipient A: Apex Legal Intake (modern JSON) ---------------------------
# POST /apex/v2/leads
#   Auth:    header  X-Api-Key: apex-test-key-123
#   Body:    nested JSON { claim: {...}, incident: {...} }
#   Success: 202 { claim_id, status: "accepted" }
#   Errors:  401 missing/invalid key; 422 missing required field;
#            503 transient (when ?flaky=1 OR ~1/6 randomly) -> tests retry
def handle_apex(req)
  return [401, { "error" => "invalid_api_key" }, {}] unless req.header("x-api-key") == API_KEYS["apex"]

  if req.query["flaky"] == "1" || rand(6).zero?
    return [503, { "error" => "upstream_unavailable" }, { "Retry-After" => "1" }]
  end

  claim = req.json["claim"] || {}
  missing = %w[first_name last_name phone email].select { |k| claim[k].to_s.strip.empty? }
  return [422, { "error" => "validation_failed", "missing" => missing }, {}] if missing.any?

  source_claim_id = req.json["source_claim_id"].to_s
  external_id = "APX-#{SecureRandom.hex(4)}"
  schedule_postback(recipient: "apex", source_claim_id: source_claim_id, external_id: external_id)
  [202, { "claim_id" => external_id, "status" => "accepted" }, {}]
end

# ---- Recipient B: Beacon Lawsuit Network (legacy form-encoded) --------------
# POST /beacon/api/addLead
#   Auth:    form field  key=beacon-test-key-456
#   Body:    application/x-www-form-urlencoded, FLAT fields, phone10 (10 digits)
#   Success: 200 { success: 1, lead_id }   <-- success is in the BODY, not status
#   Failure: 200 { success: 0, error: "..." }  <-- still HTTP 200!
#            (duplicate source_claim_id -> success: 0, error: "duplicate")
def handle_beacon(req)
  form = req.form
  return [200, { "success" => 0, "error" => "auth_failed" }, {}] unless form["key"] == API_KEYS["beacon"]

  phone = form["phone10"].to_s.gsub(/\D/, "")
  if phone.length != 10
    return [200, { "success" => 0, "error" => "phone_must_be_10_digits" }, {}]
  end
  if %w[first_name last_name].any? { |k| form[k].to_s.strip.empty? }
    return [200, { "success" => 0, "error" => "missing_name" }, {}]
  end

  scid = form["source_claim_id"].to_s
  dup = MUTEX.synchronize { !SEEN_CLAIM_IDS.add?("beacon:#{scid}") }
  return [200, { "success" => 0, "error" => "duplicate" }, {}] if dup && !scid.empty?

  external_id = "BCN#{rand(100_000..999_999)}"
  schedule_postback(recipient: "beacon", source_claim_id: scid, external_id: external_id)
  [200, { "success" => 1, "lead_id" => external_id }, {}]
end

# ---- Recipient C: Citadel Claims (JSON, bearer token, dedup + rate limit) ---
# POST /citadel/intake
#   Auth:    header  Authorization: Bearer citadel-test-token-789
#   Success: 200 { accepted: true, external_id }
#   Errors:  401 bad token; 409 duplicate source_claim_id (idempotency);
#            429 + Retry-After when >5 requests / 10s  -> tests backoff
def handle_citadel(req)
  token = req.header("authorization").to_s.sub(/\ABearer\s+/i, "")
  return [401, { "error" => "unauthorized" }, {}] unless token == API_KEYS["citadel"]

  if rate_limited?("citadel", max: 5, per_seconds: 10)
    return [429, { "error" => "rate_limited" }, { "Retry-After" => "2" }]
  end

  scid = req.json["source_claim_id"].to_s
  dup = MUTEX.synchronize { !SEEN_CLAIM_IDS.add?("citadel:#{scid}") }
  return [409, { "error" => "duplicate", "source_claim_id" => scid }, {}] if dup && !scid.empty?

  missing = %w[first_name last_name phone email accident_state].select { |k| req.json[k].to_s.strip.empty? }
  return [422, { "error" => "validation_failed", "missing" => missing }, {}] if missing.any?

  external_id = "CIT-#{SecureRandom.hex(5)}"
  schedule_postback(recipient: "citadel", source_claim_id: scid, external_id: external_id)
  [200, { "accepted" => true, "external_id" => external_id }, {}]
end

def handle_health(_req)
  [200, { "status" => "ok", "recipients" => %w[apex beacon citadel], "callback_url" => CALLBACK_URL }, {}]
end

ROUTES = {
  ["POST", "/scrub/dnc"]         => method(:handle_dnc),
  ["POST", "/apex/v2/leads"]     => method(:handle_apex),
  ["POST", "/beacon/api/addLead"] => method(:handle_beacon),
  ["POST", "/citadel/intake"]    => method(:handle_citadel),
  ["GET",  "/health"]            => method(:handle_health)
}.freeze

# -----------------------------------------------------------------------------
# Accept loop
# -----------------------------------------------------------------------------
server = TCPServer.new("0.0.0.0", PORT)
log("Mock recipients server listening on http://localhost:#{PORT}")
log("Endpoints: /health  /scrub/dnc  /apex/v2/leads  /beacon/api/addLead  /citadel/intake")
log(CALLBACK_URL ? "Postbacks will POST to #{CALLBACK_URL}" : "CALLBACK_URL unset -> postbacks only logged")

loop do
  conn = server.accept
  Thread.new(conn) do |c|
    begin
      req = read_request(c)
      next respond(c, 400, { "error" => "bad_request" }) unless req

      handler = ROUTES[[req.method, req.path]]
      if handler
        status, body, extra = handler.call(req)
        respond(c, status, body, extra_headers: extra || {})
        log("#{req.method} #{req.path} -> #{status}")
      else
        respond(c, 404, { "error" => "not_found", "path" => req.path })
        log("#{req.method} #{req.path} -> 404")
      end
    rescue => e
      log("ERROR #{e.class}: #{e.message}")
      respond(c, 500, { "error" => "server_error" }) rescue nil
    ensure
      c.close rescue nil
    end
  end
end
