local consumer = require "resty.kafka.consumer"

local tostring = tostring
local broker_list_plain = BROKER_LIST

describe("Test consumer ", function()
  it("join a not-yet existing group", function()
    local consumer_instance = consumer:new(broker_list_plain)
    -- even if the group does not exist (ensure by a random group name)
    math.randomseed(ngx.now() * 1000)
    local group_name = "group-" .. tostring(math.random(10000000))
    local subscribe_ok, subscribe_err = consumer_instance:subscribe(group_name, { "test1" })
    assert.is_nil(subscribe_err)
    assert.is_not_nil(subscribe_ok)
  end)
end)
