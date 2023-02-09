local ssl = require("ngx.ssl")
local producer = require "resty.kafka.producer"
local request = require "resty.kafka.request"
local response = require "resty.kafka.response"

local broker_list_plain = {
	{ host = "broker", port = 9092 },
}

local f, cert_data, key_data, cert, priv_key, _
-- Load certificate
repeat
  f = assert(io.open("/certs/certchain.crt"))
  cert_data = f:read("*a")
  f:close()
until cert_data
cert, _ = ssl.parse_pem_cert(cert_data)

-- Load private key
repeat
  f = assert(io.open("/certs/privkey.key"))
  key_data = f:read("*a")
  f:close()
until key_data
priv_key, _ = ssl.parse_pem_priv_key(key_data)

-- move to fixture dir or helper file
local function convert_to_hex(req)
    local str = req._req[#req._req]
    local ret = ""
    for i = 1, #str do
        ret = ret .. bit.tohex(string.byte(str, i), 2)
    end
    return ret
end

-- define topics, keys and messages etc.
local TEST_TOPIC = "test"
local TEST_TOPIC_1 = "test1"
local KEY = "key"
local MESSAGE = "message"

local function compare(func, number)
    local req = request:new(request.ProduceRequest, 1, "clientid")
    req:int32(100)
    local correlation_id = req._req[#req._req]

    req[func](req, number)
    local str = correlation_id .. req._req[#req._req]

    local resp = response:new(str, req.api_version)

    local cnumber = resp[func](resp)
    return tostring(number), number == cnumber
end


-- Create topics before running the tests
local function create_topics()
    -- Not interested in the output
    local p, err = producer:new(broker_list_plain)
    if not p then
      return nil, err
    end
    for i=1,10 do
        p:send(TEST_TOPIC, KEY, i .. " try creating_topics for " .. TEST_TOPIC )
        p:send(TEST_TOPIC_1, KEY, i .. " try creating_topics for " .. TEST_TOPIC_1)
    end
    ngx.sleep(2)
end

return {
  TEST_TOPIC = TEST_TOPIC,
  TEST_TOPIC_1 = TEST_TOPIC_1,
  KEY = KEY,
  MESSAGE = MESSAGE,
  CERT = cert,
  PRIV_KEY = priv_key,
  BROKER_LIST = broker_list_plain,
	convert_to_hex = convert_to_hex,
	compare = compare,
  create_topics = create_topics,
}