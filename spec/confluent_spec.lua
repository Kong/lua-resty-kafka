
local client = require "resty.kafka.client"
local producer = require "resty.kafka.producer"
local key = KEY
local message = MESSAGE
local os = os

local confluent_bootstrap_server_adr = os.getenv("CONFLUENT_BOOTSTRAP_SERVER")
local confluent_bootstrap_server_port = os.getenv("CONFLUENT_BOOTSTRAP_PORT")
local confluent_api_key = os.getenv("CONFLUENT_API_KEY")
local confluent_api_secret = os.getenv("CONFLUENT_API_SECRET")
local confluent_topic = os.getenv("CONFLUENT_TOPIC")

local broker_list_sasl = {
    { host = confluent_bootstrap_server_adr, port = confluent_bootstrap_server_port },
}
local sasl_config = { strategy="sasl",
                      mechanism="PLAIN",
                      user = confluent_api_key,
                      password = confluent_api_secret
                    }
local client_config_sasl_plain = {
    ssl = true,
    auth_config = sasl_config,
    client_id =  "test-override"
}

local cli

if not (confluent_api_key and confluent_api_secret) then
  -- do not run this file if confluent isn't configured
  return true
end

describe("Testing Confluent Cloud", function()

  before_each(function()
      cli = client:new(broker_list_sasl, client_config_sasl_plain)
  end)

  it("to build the metatable correctly", function()
    assert.are.equal(cli.socket_config.ssl, client_config_sasl_plain.ssl)
    assert.are.equal(cli.socket_config.ssl_verify, false)
    assert.are.equal(cli.auth_config.mechanism, sasl_config.mechanism)
    assert.are.equal(cli.auth_config.user, sasl_config.user)
    assert.are.equal(cli.auth_config.password, sasl_config.password)
    assert.are.equal(cli.client_id, client_config_sasl_plain.client_id)
  end)

  it("to fetch metadata correctly", function()
    -- Fetch metadata
    local brokers, partitions = cli:fetch_metadata(confluent_topic)
    assert.is_not_nil(brokers)
    assert.is_same("b0-" .. confluent_bootstrap_server_adr, brokers[0].host)
    assert.are.equal(brokers[0].port, 9092)

    local first_partition = partitions[0]
    table.sort(first_partition.replicas)
    table.sort(first_partition.isr)
    -- Check if return was assigned to cli metatable
    assert.are.same({
                  errcode = 0,
                  id = 0,
                  leader = 4,
                  replicas = { [1] = 0, [2] = 4, [3] = 5},
                  isr = { [1] = 0, [2] = 4, [3] = 5},
                  }, first_partition)
    -- Check if partitions were fetched correctly
    assert.is_not_nil(cli.topic_partitions[confluent_topic])
    -- Check if cli partitions metatable was set correctly
  end)

  it("setup producers correctly", function()
    local p, err = producer:new(broker_list_sasl, client_config_sasl_plain)
    assert.is_nil(err)
    local offset, err = p:send(confluent_topic, key, message)
    assert.is_nil(err)
    assert.is_number(tonumber(offset))
  end)
end)
