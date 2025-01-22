local consumer = require "resty.kafka.consumer"
local producer = require "resty.kafka.producer"

local tostring = tostring
local broker_list_plain = BROKER_LIST

-- run it 10 times just for good measure
for i=1,1 do
describe("Test consumer run: " .. i, function()

  local function produce_messages(topic)
    -- TODO: make this a sync producer to ensure we fetch the messages in time
    local producer_instance, producer_err = producer:new(broker_list_plain)
    assert.is_nil(producer_err)
    assert.is_not_nil(producer_instance)
    -- generate random message and key
    math.randomseed(ngx.now() * 1000)
    local message = "test-message-" .. tostring(math.random(1000000))
    local key = "test-key-" .. tostring(math.random(10000000))
    local offset, err = producer_instance:send(topic, key, message)
    assert.is_not_nil(offset, "Failed to send message ")
    assert.is_nil(err, "Error sending message")
    return key, message, offset
  end

  local function find_message_by_key(results, topic, key)
    -- Check if topic exists in results
    if not results[topic] or not results[topic].partitions then
      return nil
    end

    -- Iterate through all partitions
    for partition_id, partition_data in pairs(results[topic].partitions) do
      -- Check if partition has records
      if partition_data.records and #partition_data.records > 0 then
        -- Look for message with matching offset
        for _, record in ipairs(partition_data.records) do
          if record.key == key then
            return record
          end
        end
      end
    end

    return nil
  end

  local function count_total_records(results)
    local total = 0
    for topic_name, topic_data in pairs(results) do
      if topic_data.partitions then
        for _, partition_data in pairs(topic_data.partitions) do
          if partition_data.records then
            total = total + #partition_data.records
          end
        end
      end
    end
    return total
  end

  it("subscribe and poll #latest", function()
    local key, message, offset = produce_messages(TEST_TOPIC)
    local key2, message2, offset2 = produce_messages(TEST_TOPIC_1)
    local consumer_instance = consumer:new(broker_list_plain)
    local subscribe_ok, subsribe_err = consumer_instance:subscribe("testing-consume",
      { TEST_TOPIC, TEST_TOPIC_1 },
      {
        commit_strategy = "auto",
        auto_offset_reset = "latest"
      })
    assert.is_nil(subsribe_err)
    assert.is_not_nil(subscribe_ok)
    local records, poll_err = consumer_instance:poll()
    assert.is_not_nil(records)
    assert.is_nil(poll_err)

    -- TOPIC-1
    -- assert that the message exists
    local record = find_message_by_key(records, TEST_TOPIC, key)
    assert.is_not_nil(record)
    assert.is_same(record.value, message)
    -- assert that it's actually the same message (by offset)
    assert.is_same(tonumber(record.offset), tonumber(offset - 1))


    -- TOPIC-2
    -- assert that the message exists
    local record2 = find_message_by_key(records, TEST_TOPIC_1, key2)
    assert.is_not_nil(record2)
    assert.is_same(record2.value, message2)
    -- assert that it's actually the same message (by offset)
    assert.is_same(tonumber(record2.offset), tonumber(offset2 - 1))

    -- assert that the total number of records found in the return is 2 (we produced two messages)
    local total_records = count_total_records(records)
    assert.is_same(total_records, 2, "Expected 2 records (one per topic), but found " .. total_records)
  end)

  it("subscribe and poll #earliest", function()
    local key, message, offset = produce_messages(TEST_TOPIC)
    local consumer_instance = consumer:new(broker_list_plain)
    local subscribe_ok, subsribe_err = consumer_instance:subscribe("testing-consume",
      { TEST_TOPIC },
      {
        commit_strategy = "auto",
        auto_offset_reset = "earliest"
      })
    assert.is_nil(subsribe_err)
    assert.is_not_nil(subscribe_ok)
    local records, poll_err = consumer_instance:poll()
    assert.is_nil(poll_err)

    -- TOPIC-1
    -- assert that the message exists
    local record = find_message_by_key(records, TEST_TOPIC, key)
    assert.is_not_nil(record)
    assert.is_same(record.value, message)
    -- assert that it's actually the same message (by offset)
    assert.is_same(tonumber(record.offset), tonumber(offset - 1))
    -- also, somehow (todo) check that there are more messages then those we produced
    -- this would fail the first time running this test tho.. look at other options
  end)
end)
end
