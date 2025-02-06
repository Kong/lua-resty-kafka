local consumer = require "resty.kafka.consumer"

local broker_list_plain = BROKER_LIST

describe("Test consumer ", function()
  it("two subscribes in two threads with the same group to the same topic", function()
    local consumer_instance = consumer:new(broker_list_plain)
    -- even if the group does not exist (ensure by a random group name)
    -- even if the group does not exist (ensure by a random group name)
    math.randomseed(ngx.now() * 1000)
    local group_name = "group-" .. tostring(math.random(10000000))
    local subscribe_ok, subscribe_err = consumer_instance:subscribe(group_name, { "test1" })
    assert.is_nil(subscribe_err)
    assert.is_not_nil(subscribe_ok)
    local results = consumer_instance:poll()
    assert.is_not_nil(results)
    -- assert that the next subscribe is invalid
    local subscribe_ok, subscribe_err = consumer_instance:subscribe(group_name, { "test1" })
    assert.is_not_nil(subscribe_err)
    assert.matches("failed to join group: You are not the leader of the group", subscribe_err)
    assert.is_nil(subscribe_ok)
  end)
end)
