local producer = require "resty.kafka.producer"
local tablex = require "pl.tablex"

local tostring = tostring
local tx_deepcopy = tablex.deepcopy
local broker_list_plain = BROKER_LIST
local key = KEY
local message = MESSAGE
local tonumber = tonumber
local ngx_sleep = ngx.sleep

describe("Test producers: ", function()

  before_each(function()
      create_topics()
  end)

  it("sends two messages and the offset is one apart", function()
    local p, err = producer:new(broker_list_plain)
    assert.is_nil(err)
    local offset1, err = p:send(TEST_TOPIC, key, message)
    assert.is_nil(err)
    local offset2, err = p:send(TEST_TOPIC, key, message)
    assert.is_nil(err)
    local diff = tonumber(offset2) - tonumber(offset1)
    assert.is.equal(diff, 1)
  end)

  it("avoid duplicate messages in sync mode", function()
    local spawn = ngx.thread.spawn
    local wait = ngx.thread.wait
    local kill = ngx.thread.kill

    local function co_send(p, num)
      local offset, err = p:send(TEST_TOPIC, key, message .. num)
      assert.is_nil(err)

      return offset
    end

    local p, err = producer:new(broker_list_plain, { producer_type = "sync" })
    assert.is_nil(err)

    local co1 = spawn(co_send, p, 1)
    local co2 = spawn(co_send, p, 2)

    local _, res1 = wait(co1)
    local _, res2 = wait(co2)

    local diff = tonumber(res1) - tonumber(res2)
    assert.is.equal(math.abs(diff), 1)

    kill(co1)
    kill(co2)
  end)

  it("avoid cached producer when cluster config is updated", function()
    local producer_config = { producer_type = "async" }
    local cluster_name = "kong"
    local p1, p2, p3, p4, p5, err

    p1, err = producer:new(broker_list_plain, producer_config, cluster_name)
    assert.is_nil(err)

    -- avoid cache and error
    local broker_list_plain_new = tx_deepcopy(broker_list_plain)
    broker_list_plain_new[1].port = 9091
    p2, err = producer:new(broker_list_plain_new, producer_config, cluster_name)
    assert.is_nil(p2)
    assert.are.equal("Could not retrieve version map from cluster", err)

    -- empty broker list
    p3, err = producer:new(nil, producer_config, cluster_name)
    assert.is_nil(p3)
    assert.are.equal("Could not retrieve version map from cluster", err)

    -- reuse cache
    local broker_list_plain_dup = tx_deepcopy(broker_list_plain)
    p4, err = producer:new(broker_list_plain_dup, producer_config, cluster_name)
    assert.is_nil(err)
    assert.are.equal(p4, p1)

    -- avoid cache and create new
    local broker_list_plain_dup = tx_deepcopy(broker_list_plain)
    p5, err = producer:new(broker_list_plain_dup, { request_timeout = 1000 } , cluster_name)
    assert.is_nil(err)
    assert.are_not.equals(p5, p1)
  end)

  it("sends two messages to two different topics", function()
    local p, err = producer:new(broker_list_plain)
    assert.is_nil(err)
    local offset1, err = p:send(TEST_TOPIC, key, message)
    assert.is_nil(err)
    assert.is_number(tonumber(offset1))
    local offset2, err = p:send(TEST_TOPIC_1, key, message)
    assert.is_nil(err)
    assert.is_number(tonumber(offset2))
  end)

  it("fails when topic_partitions are empty", function()
    local p, err = producer:new(broker_list_plain)
    p.client.topic_partitions.test = { [2] = { id = 2, leader = 0 }, [1] = { id = 1, leader = 0 }, [0] = { id = 0, leader = 0 }, num = 3 }
    local offset, err = p:send(TEST_TOPIC, key, message)
    assert.is_not_nil(err)
    assert.is_nil(offset)
    assert.is_same("not found broker; not found partition; not found partition", err)
  end)

  it("sends a lot of messages", function()
    local producer_config = { producer_type = "async", flush_time = 100}
    local p, err = producer:new(broker_list_plain, producer_config)
    assert.is_nil(err)
    -- init offset
    p:send(TEST_TOPIC, key, message)
    p:flush()
    local offset,_ = p:offset()
    local i = 0
    while i < 2000 do
          p:send(TEST_TOPIC, key, message..tostring(i))
          i = i + 1
    end
    ngx_sleep(0.2)
    local offset2, _ = p:offset()
    local diff = tostring(offset2 - offset)
    assert.is.equal(diff, "2000LL")
  end)

  it("test message buffering", function()
    local p = producer:new(broker_list_plain, { producer_type = "async", flush_time = 1000 })
    ngx_sleep(0.1) -- will have an immediately flush by timer_flush
    local size, err = p:send(TEST_TOPIC, key, message)
    assert.is_not_nil(size)
    assert.is_nil(err)
    ngx_sleep(1.1)
    local offset = p:offset()
    assert.is_true(tonumber(offset) > 0)
    p:flush()
    local offset0 = p:offset()

    local ok, err = p:send(TEST_TOPIC, key, message)
    assert.is_nil(err)
    assert.is_not_nil(ok)

    p:flush()
    local offset1 = p:offset()

    assert.is.equal(tonumber(offset1 - offset0), 1)
  end)

  it("timer flush", function()
    local p = producer:new(broker_list_plain, { producer_type = "async", flush_time = 1000 })
    ngx_sleep(0.1) -- will have an immediately flush by timer_flush

    local size, err = p:send(TEST_TOPIC, key, message)
    assert.is_not_nil(size)
    assert.is_nil(err)
    ngx_sleep(1.1)
    local offset = p:offset()
    assert.is_true(tonumber(offset) > 0)
  end)

  it("multi topic batch send", function()
    local p = producer:new(broker_list_plain, { producer_type = "async", flush_time = 10000})
    ngx_sleep(0.01)
    -- 2 message
    local size, err = p:send(TEST_TOPIC, key, message)
    assert.is_not_nil(size)
    assert.is_nil(err)
    local size, err = p:send(TEST_TOPIC_1, key, message)
    assert.is_not_nil(size)
    assert.is_nil(err)
    p:flush()
    local offset0 = p:offset()

    local size, err = p:send(TEST_TOPIC, key, message)
    assert.is_not_nil(size)
    assert.is_nil(err)
    local size, err = p:send(TEST_TOPIC_1, key, message)
    assert.is_not_nil(size)
    assert.is_nil(err)
    p:flush()

    local offset1 = p:offset()

    local offset_diff = tonumber(offset1 - offset0)
    assert.is.equal(offset_diff, 2)
  end)

  it("is not retryable ", function()
    local p = producer:new(broker_list_plain, { producer_type = "async", flush_time = 10000})
    ngx_sleep(0.01)
    local size, err = p:send(TEST_TOPIC, key, message)
    assert.is_not_nil(size)
    assert.is_nil(err)
    p:flush()
    local offset0 = p:offset()

    p.sendbuffer.topics.test[0].retryable = false

    local size, err = p:send(TEST_TOPIC, key, message)
    assert.is_not_nil(size)
    assert.is_nil(err)
    p:flush()

    local offset1 = p:offset()
    local offset_diff = tonumber(offset1 - offset0)

    assert.is.equal(offset_diff, 1)
  end)

  it("sends in batches to two topics", function()
    local p = producer:new(broker_list_plain, { producer_type = "async", flush_time = 10000})
    ngx_sleep(0.01)
    -- 2 message
    local size, err = p:send(TEST_TOPIC, key, message)
    assert.is_not_nil(size)
    assert.is_nil(err)
    p:flush()
    local offset0 = p:offset()
    local size, err = p:send(TEST_TOPIC, key, message)
    assert.is_not_nil(size)
    assert.is_nil(err)
    local size, err = p:send(TEST_TOPIC, key, message)
    assert.is_not_nil(size)
    assert.is_nil(err)
    p:flush()

    local offset1 = p:offset()
    local offset_diff = tonumber(offset1 - offset0)
    assert.is.equal(offset_diff, 2)
  end)

  it("buffer flush", function()
    local p = producer:new(broker_list_plain, { producer_type = "async", batch_num = 1, flush_time = 10000})
    ngx_sleep(0.1) -- will have an immediately flush by timer_flush

    local ok, err = p:send(TEST_TOPIC, nil, message)
    assert.is_not_nil(ok)
    assert.is_nil(err)
    ngx_sleep(1)
    local offset0 = p:offset()
    p:flush()
    local offset1 = p:offset()
    local offset_diff = tonumber(offset1) - tonumber(offset0)
    assert.is.equal(offset_diff, 0)
  end)

  it("works when broker is down and brought back online (sync)", function()
    local p, offset, ok, err

    p, err = producer:new({ { host = "broker", port = 9092 } }, { socket_timeout = 15 * 1000, max_retry = 3, retry_backoff = 5 * 1000 })
    assert.is_truthy(p)
    assert.is_nil(err)
    offset, err = p:send("brokerdown", key, "beforestop message")
    assert.is_truthy(tonumber(offset) > 0)
    assert.is_nil(err)

    ok = os.execute(string.format("docker compose -p dev %s broker2", "stop"))
    assert.is_truthy(ok)

    ngx_sleep(5)
    offset, err = p:send("brokerdown", key, "afterstop message")
    assert.is_nil(offset)
    assert.is_same("not found broker; not found broker; not found broker", err)

    ok = os.execute(string.format("docker compose -p dev %s broker2", "start"))
    assert.is_truthy(ok)

    ngx_sleep(15)  -- wait for rediscovery
    offset, err = p:send("brokerdown", key, "backonline message")
    assert.is_truthy(tonumber(offset) > 0)
    assert.is_nil(err)
  end)

  it("works when broker is down and brought back online (async)", function()
    local p, ok, err

    p, err = producer:new({ { host = "broker", port = 9092 } }, { producer_type = "async" })
    assert.is_truthy(p)
    assert.is_nil(err)
    ngx_sleep(0.1)  -- immediate timer_flush
    ok, err = p:send("brokerdown", key, "beforestop message")
    assert.is_truthy(ok)
    assert.is_nil(err)

    ngx_sleep(1) -- make sure the previous msg is sent before stop
    ok = os.execute(string.format("docker compose -p dev %s broker2", "stop"))
    assert.is_truthy(ok)

    ok, err = p:send("brokerdown", key, "afterstop message")
    assert.is_truthy(ok)
    assert.is_nil(err)

    ok = os.execute(string.format("docker compose -p dev %s broker2", "start"))
    assert.is_truthy(ok)

    ngx_sleep(15)  -- wait for rediscovery
    ok, err = p:send("brokerdown", key, "backonline message")
    assert.is_truthy(ok)
    assert.is_nil(err)
  end)

end)
