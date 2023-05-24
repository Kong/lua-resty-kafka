
local client = require "resty.kafka.client"
local producer = require "resty.kafka.producer"
local key = KEY
local message = MESSAGE
local os = os

local eventhub_credentials = os.getenv("EVENTHUB_CREDENTIALS")
local eventhub_host = os.getenv("EVENTHUB_HOST")

local broker_list_sasl = {
    { host = eventhub_host, port = 9093 },
}
local sasl_config = { strategy="sasl",
                      mechanism="PLAIN",
                      user="$ConnectionString",
                      password=eventhub_credentials
                    }
local client_config_sasl_plain = {
    ssl = true,
    auth_config = sasl_config
}

local cli

if not (eventhub_credentials and eventhub_host) then
  -- do not run this file if eventhub isn't configured
  return true
end

describe("Testing Microsoft EventHub", function()

  before_each(function()
      cli = client:new(broker_list_sasl, client_config_sasl_plain)
  end)

  it("to build the metatable correctly", function()
    assert.are.equal(cli.socket_config.ssl, client_config_sasl_plain.ssl)
    assert.are.equal(cli.socket_config.ssl_verify, false)
    assert.are.equal(cli.auth_config.mechanism, sasl_config.mechanism)
    assert.are.equal(cli.auth_config.user, sasl_config.user)
    assert.are.equal(cli.auth_config.password, sasl_config.password)
  end)

  it("to fetch metadata correctly", function()
    -- Fetch metadata
    local brokers, partitions = cli:fetch_metadata("konglog")
    assert.are.equal(brokers[0].host, eventhub_host)
    assert.are.equal(brokers[0].port, 9093)
    -- Check if return was assigned to cli metatable
    assert.are.same({errcode = 0, id = 0, isr = {}, leader = 0, replicas = {}},partitions[0])
    -- Check if partitions were fetched correctly
    assert.is_not_nil(cli.topic_partitions["konglog"])
    -- Check if cli partitions metatable was set correctly
  end)

  it("setup producers correctly", function()
    local p, err = producer:new(broker_list_sasl, client_config_sasl_plain)
    assert.is_nil(err)
    local offset, err = p:send("konglog", key, message)
    assert.is_nil(err)
    assert.is_number(tonumber(offset))
  end)
end)