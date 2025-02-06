local client            = require("resty.kafka.client")
local broker            = require("resty.kafka.broker")
local protocol_consumer = require("resty.kafka.protocol.consumer")
local Errors            = require("resty.kafka.errors")
local protocol_client   = require("resty.kafka.protocol.client")
local config_parser     = require "resty.kafka.consumer.config"

local ngx_log           = ngx.log
local INFO              = ngx.INFO
local ERR               = ngx.ERR
local WARN              = ngx.WARN
local DEBUG             = ngx.DEBUG


local _M = {}
local mt = { __index = _M }

local COMMIT_STRATEGY_AUTO = "auto"
local POLL_STRATEGY_EARLIEST = "earliest"

function _M.new(self, broker_list, client_config)
  local opts = client_config or {}

  local cli = client:new(broker_list, client_config)
  local p = setmetatable({
    client = cli,
    correlation_id = 0,
    isolation_level = opts.isolation_level or 0,
    client_rack = opts.client_rack or "default",
    socket_config = cli.socket_config,
    auth_config = cli.auth_config,
    coordinator = nil,
  }, mt)

  return p
end

--- Fetch message
-- The maximum waiting time is 100 ms, and the maximum message response is 100 MiB.
-- @author bzp2010 <bzp2010@apache.org>
-- @param self
-- @param topic      The name of topic
-- @param partition  The partition of topic
-- @param offset     The starting offset of the message to get
-- @return messages  The obtained offset messages, which is in a table, may be nil
-- @return err       The error of request, may be nil
function _M:fetch(topic, partition, offset)
  local cli = self.client
  local broker_conf, err = cli:choose_broker(topic, partition)
  if not broker_conf then
    return nil, err
  end

  -- Create connection to broker, this broker is the leader of the topic[partition]
  local bk, bk_err = broker:new(broker_conf.host, broker_conf.port, self.socket_config, self.auth_config)
  if not bk then
    return nil, bk_err
  end

  local req = protocol_consumer.fetch_encode(self, {
    topic_num = 1,
    topics = {
      [topic] = {
        partition_num = 1,
        partitions = {
          [partition] = {
            offset = offset
          }
        },
      }
    },
  })
  if not req then
    return nil, "failed to encode fetch request"
  end

  local resp, send_rec_err = bk:send_receive(req)
  if not resp then
    return nil, send_rec_err
  end

  local result = protocol_consumer.fetch_decode(resp, offset)

  return result
end

function _M:fetch_metadata(topics)
  local metdata_req, mr_err = protocol_client.metadata_encode(self.client.client_id, topics)
  if not metdata_req then
    return nil, mr_err
  end
  -- TODO: Are we sending the metadata request to the coordinator?
  -- seems correct so far
  local metdata_resp, mrp_err = self.coordinator:send_receive(metdata_req)
  if not metdata_resp then
    return nil, mrp_err
  end
  return protocol_client.metadata_decode(metdata_resp)
end

function _M:_join_group(group_id, topics, configuration)
  -- Prepare join group request
  local config = configuration or {}
  local req = protocol_consumer.join_group_encode(self, {
    group_id = group_id,
    session_timeout_ms = config.session_timeout_ms or 30000,
    -- delay rebalancing events, we are the only consumer in that group
    rebalance_timeout_ms = 100000,
    member_id = config.member_id or "",
    protocol_type = "consumer",
    -- Signalizes that we're a static consumer
    group_instance_id = "kong/lua-resty-kafka",
    protocols = {
      {
        name = "all-on-leader", -- AssignmentStrategy
        metadata = {
          version = 1,
          topics = topics,
          user_data = ""
        }
      }
    }
  })
  if not req then
    return nil, "failed to encode join group request"
  end

  -- Send join group request
  local resp, err = self.coordinator:send_receive(req)
  if not resp then
    return nil, "failed to join group: " .. (err or "unknown error")
  end

  -- Decode response
  local result = protocol_consumer.join_group_decode(resp)
  if not result then
    return nil, "failed to decode join group response"
  end


  -- If I'm not the leader of the group, abort here. This isn't currently supported
  -- There be dragons. In the current partition assignment strategy, every member of a group
  -- can read from all subscribed topics and all partitions
  -- This may cause race-conditions when data is read from the same partition by multiple consumers
  -- and commits are not respected. This can result in data being read twice (or however times a subscription is created)
  if result.leader ~= result.member_id then
    return nil, "You are not the leader of the group. Currently only one consumer can be part of a group"
  end

  -- Check for errors
  if result.error_code and result.error_code ~= 0 then
    local err_msg = Errors[result.error_code] or "unknown error"
    ngx_log(WARN, "join group error: ", err_msg, ", group_id: ", group_id)
    return nil, err_msg
  end

  return result
end

function _M:heartbeat(group_id, generation_id, member_id)
  -- send heartbeat, TODO: this should be on a timer
  local heartbeat_req = protocol_consumer.heartbeat_encode(self, {
    group_id = group_id,
    generation_id = generation_id,
    member_id = member_id
  })

  local heartbeat_resp, err = self.coordinator:send_receive(heartbeat_req)
  if not heartbeat_resp then
    return nil, "failed to send heartbeat: " .. (err or "unknown error")
  end

  local heartbeat_result = protocol_consumer.heartbeat_decode(heartbeat_resp)
  if not heartbeat_result then
    return nil, "failed to decode heartbeat response"
  end

  if heartbeat_result.error_code and heartbeat_result.error_code ~= 0 then
    local err_msg = Errors[heartbeat_result.error_code] or "unknown error"
    ngx_log(WARN, "heartbeat error: ", err_msg, ", group_id: ", group_id)
    return nil, err_msg
  end
  return true
end

function _M:partition_assignment(group_metadata)
  local group_id = group_metadata.group_id
  local leader = group_metadata.leader
  local member_id = group_metadata.member_id
  local members = group_metadata.members


  -- an array of topics
  --[[
  local topics_data = {
    {
      topic = "test",
      partitions = { 0, 1, 2 }
    }
  }
  --]]
  local topics_data = {}
  for topic_name, topic_info in pairs(self.topics) do
    local partitions = {}
    -- Extract partition IDs from topic_info

    for i = 0, topic_info.num do
      local part = topic_info[i]
      if part and next(part) and part.errcode == 0 then
        table.insert(partitions, part.id)
      else
        ngx_log(WARN, "something off here -> ", require("inspect")(part))
      end
    end

    table.insert(topics_data, {
      topic = topic_name,
      partitions = partitions
    })
  end

  -- create partition assignment when leader
  local group_assignment = {}
  if leader == member_id then
    ngx_log(INFO, "I am the leader: ", leader, ", for group_id: ", group_id)
    -- As leader, create assignments for all members
    for _, member in ipairs(members) do
      -- Create member assignment in protocol format
      table.insert(group_assignment, {
        member_id = member.member_id,
        -- Assignment bytes will be encoded by protocol layer
        assignment = {
          version = 0,
          topics = topics_data,
          user_data = ""
        }
      })
    end
  else
    ngx_log(INFO, "I am not the leader: ", group_metadata.leader, ", group_id: ", group_id)
    -- Non-leaders send empty assignments and receive them from the leader
    group_assignment = {}
  end
  return group_assignment
end

function _M:sync_group(group_id, generation_id, member_id, group_assignment)
  -- Prepare sync group request
  local sync_req = protocol_consumer.sync_group_encode(self, {
    group_id = group_id,
    generation_id = generation_id,
    member_id = member_id,
    group_assignments = group_assignment
  })
  if not sync_req then
    return nil, "failed to encode sync group request"
  end


  -- Send sync group request
  local sync_resp, err = self.coordinator:send_receive(sync_req)
  if not sync_resp then
    return nil, "failed to sync group: " .. (err or "unknown error")
  end

  -- Decode response
  local sync_result = protocol_consumer.sync_group_decode(sync_resp)
  if not sync_result then
    return nil, "failed to decode sync group response"
  end

  -- Check for errors
  if sync_result.error_code and sync_result.error_code ~= 0 then
    local err_msg = Errors[sync_result.error_code] or "unknown error"
    ngx_log(WARN, "sync group error: ", err_msg, ", group_id: ", group_id)
    return nil, err_msg
  end
  return sync_result
end

function _M:offset_fetch(group_id)
  -- Prepare offset fetch request
  -- get this dynamically from the assignment

  local offset_fetch_data = self.partition_assignment_for_self
  offset_fetch_data.group_id = group_id
  local offset_fetch_req = protocol_consumer.offset_fetch_encode(self, offset_fetch_data)

  local offset_fetch_resp, err = self.coordinator:send_receive(offset_fetch_req)
  if not offset_fetch_resp then
    return nil, "failed to offset fetch: " .. (err or "unknown error")
  end

  local offset_fetch_result, error_codes = protocol_consumer.offset_fetch_decode(offset_fetch_resp)
  if error_codes then
    for partition_id, error_code in pairs(error_codes) do
      local error = Errors[error_code]
      -- TODO: decide when to fail and when to warn
      ngx_log(ERR, "error encountered when fetching offsets for partition: ", partition_id, ", error: ", error)
    end
  end
  if not offset_fetch_result then
    return nil, "failed to decode offset fetch response"
  end
  return offset_fetch_result
end

function _M:subscribe(group_id, topics, configuration)
  local cli = self.client

  -- TODO: Do we need to check if we're already subscribed?
  -- as in, do we need to avoid multiple calls to subscribe()

  -- Parse and validate configuration
  local config, err = config_parser.parse(configuration)
  if not config then
    return nil, err
  end

  -- Set validated configuration
  self.commit_strategy = config.commit_strategy
  self.auto_offset_reset = config.auto_offset_reset
  self.value_deserializer = config.value_deserializer


  if not self.coordinator then
    -- for robustness, try this 3 times
    local coordinator_conf, coord_err
    for _ = 1, 3 do
      coordinator_conf, coord_err = cli:get_group_coordinator(group_id)
      if coordinator_conf then
        break
      end
      ngx_log(WARN, "failed to get group coordinator, retrying : " .. (coord_err or "unknown error"))
      ngx.sleep(1)
    end
    if not coordinator_conf then
      return nil, "failed to get group coordinator: " .. (coord_err or "unknown error")
    end

    local coordinator, coord_get_err = broker:new(coordinator_conf.host, coordinator_conf.port, self.socket_config,
      self.auth_config)
    if not coordinator then
      return nil, "failed to create connection to coordinator: " .. coord_get_err
    end

    self.coordinator = coordinator
  end

  -- TODO: This also contains the brokers we need to talk to (not the coordinator, but the broker)
  -- info we need to fetch data from, also this calls happens on the client
  -- initialization, but just not yet on the topics we need. Calling it twice is
  -- probably okay still
  local _, topics_data, topics_err = self:fetch_metadata(topics)
  if topics_err and next(topics_err) then
    for topic, error_code in pairs(topics_err) do
      local error = Errors[error_code]
      ngx_log(ERR, "error encountered when fetching metadata for topic: ", topic, ", error: ", error or "")
      return nil, error
    end
  end
  if not topics_data then
    return nil, "failed to fetch metadata: " .. (topics_data or "unknown error")
  end
  self.topics = topics_data

  -- TODO: ensure that we're the only ones in the group
  local group_metadata, join_group_err = self:_join_group(group_id, topics, configuration)
  if not group_metadata then
    return nil, "failed to join group: " .. (join_group_err or "unknown error")
  end

  local group_assignment = self:partition_assignment(group_metadata)

  local sync_group_ok, sync_group_err = self:sync_group(group_id, group_metadata.generation_id,
    group_metadata.member_id, group_assignment)

  if not sync_group_ok then
    return nil, "failed to sync group: " .. (sync_group_err or "unknown error")
  end

  self.partition_assignment_for_self = sync_group_ok.member_assignment
  self.generation_id = group_metadata.generation_id
  self.member_id = group_metadata.member_id
  self.group_id = group_id

  -- Create a recurring timer for heartbeats (every 3 seconds is a common interval)
  local ok, err = ngx.timer.every(1, function(premature)
    if premature then
      return
    end
    ngx_log(INFO, "sending heartbeat")
    local _, err = self:heartbeat(group_id, group_metadata.generation_id, group_metadata.member_id)
    if err then
      ngx_log(WARN, "heartbeat failed: ", err)
    end

    -- TODO: periodically check for new metadata and update assignments
    -- if metadata has changed, trigger a sync_group call
    -- (or a new join process alltogether as we're a static member)
  end)

  if not ok then
    return nil, "failed to create heartbeat timer: " .. (err or "unknown error")
  end

  return true
end

function _M:poll()
  local group_id = self.group_id
  if not group_id then
    return nil, "call subscribe() first"
  end


  local offset_reset = self.auto_offset_reset

  -- fetch current offsets
  local offset_fetch_result, offset_fetch_err = self:offset_fetch(group_id)
  if not offset_fetch_result then
    return nil, "failed to offset fetch: " .. (offset_fetch_err or "unknown error")
  end


  local record_of_records = {}
  for _, topic in ipairs(offset_fetch_result.topics) do
    local topic_name = topic.name
    for _, partition in ipairs(topic.partitions) do
      local offset = partition.committed_offset
      -- -1LL represents NO_OFFSET in Kafka (no committed offset exists)
      -- This typically happens when:
      -- 1. The consumer group is new
      -- 2. The offset has been expired (based on retention policy)
      -- 3. The topic-partition is being read for the first time
      if offset == -1LL then
        -- For now, treat it as 0
        offset = 0
      else
        offset = tonumber(offset)
      end
      if offset_reset == POLL_STRATEGY_EARLIEST then
        offset = 0
      end
      local data, fetch_err = self:fetch(topic_name, partition.partition_index, offset)
      if fetch_err then
        ngx_log(WARN, "failed to fetch data: ", fetch_err)
      end
      if data and data.topics and data.topics[topic_name] then
        local partition_data = data.topics[topic_name]['partitions'][partition.partition_index]

        -- Initialize topic table if it doesn't exist
        if not record_of_records[topic_name] then
          record_of_records[topic_name] = {
            partitions = {}
          }
        end

        -- Store partition data
        record_of_records[topic_name]['partitions'][partition.partition_index] = partition_data
      end
    end
  end

  if self.commit_strategy == COMMIT_STRATEGY_AUTO then
    ngx_log(INFO, "committing offsets")
    local commit_result, commit_err = self:commit_offsets(record_of_records)
    if not commit_result then
      return nil, "failed to commit offset: " .. (commit_err or "unknown error")
    end
  end


  -- TODO: this is rather stupid but this needs to be done in order to properly json encode the result
  local function sanitize_table(t)
    for k, v in pairs(t) do
      if type(v) == "cdata" then
        t[k] = tonumber(v)     -- Convert cdata to a normal Lua number
      elseif type(v) == "table" then
        sanitize_table(v)      -- Recursively sanitize nested tables
      end
    end
  end

  sanitize_table(record_of_records)

  return record_of_records
end

local function build_commit_data(records, group_id, generation_id, member_id)
  local commit_data = {
    group_id = group_id,
    generation_id = generation_id,
    member_id = member_id,
    topics = {}
  }

  -- records structure is now directly a map of topics to partition data
  -- e.g. { test = { partitions = { [0] = { records = {...} } } } }
  for topic_name, topic_data in pairs(records) do
    local topic_entry = {
      name = topic_name,
      partitions = {}
    }

    for partition_id, partition_data in pairs(topic_data.partitions) do
      if not next(partition_data.records) then
        -- do not commit offsets for partitions with no records
        -- this would reset the offset to the beginning of the partition
        ngx_log(DEBUG, "no records for partition: ", partition_id, ", topic: ", topic_name)
        goto continue
      end

      -- Get the last record's offset
      local last_seen_offset = 0
      if partition_data.records and #partition_data.records > 0 then
        last_seen_offset = tonumber(partition_data.records[#partition_data.records].offset) + 1
      end

      table.insert(topic_entry.partitions, {
        partition = tonumber(partition_id),
        offset = last_seen_offset
      })

      ::continue::
    end

    table.insert(commit_data.topics, topic_entry)
  end

  return commit_data
end

function _M:commit_offsets(records)
  local commit_data = build_commit_data(records, self.group_id, self.generation_id, self.member_id)
  local offset_commit_req = protocol_consumer.offset_commit_encode(self, commit_data)

  local offset_commit_resp, com_err = self.coordinator:send_receive(offset_commit_req)
  if not offset_commit_resp then
    return nil, "failed to commit offset: " .. (com_err or "unknown error")
  end
  local offset_commit_result = protocol_consumer.offset_commit_decode(offset_commit_resp)
  -- datastrtucture:
  --[[
  commit_result = {
  topics = { {
      name = "test",
      partitions = { {
          error_code = 0,
          partition = 0
        } }
    }, {
      name = "test1",
      partitions = { {
          error_code = 0,
          partition = 0
        } }
    } }
}
  --]]

  return offset_commit_result
end

return _M
