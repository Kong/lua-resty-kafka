local consumer = require "resty.kafka.consumer"

local tostring = tostring
local broker_list_plain = BROKER_LIST

describe("Test consumer ", function()
  it("subscribe to a non-existing topic fails", function()
    local consumer_instance = consumer:new(broker_list_plain)
    -- test only works the first time as the topic is created
    -- when the consumer is created, hence the random topic
    math.randomseed(ngx.now() * 1000)
    local topic_name = "topic-" .. tostring(math.random(10000000))
    local subscribe_ok, subscribe_err = consumer_instance:subscribe("testing-consume",
      { topic_name },
      {
        commit_strategy = "auto",
        auto_offset_reset = "latest"
      })
      assert.is_not_nil(subscribe_err)
      assert.is_nil(subscribe_ok)
      assert.is_same(subscribe_err, "LeaderNotAvailable")
  end)

  it("poll can't be called before subscribe", function()
    local consumer_instance = consumer:new(broker_list_plain)
    local records, poll_err = consumer_instance:poll()
    assert.is_nil(records)
    assert.is_not_nil(poll_err)
    assert.is_same(poll_err, "call subscribe() first")
  end)
end)
