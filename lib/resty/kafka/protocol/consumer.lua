local protocol                 = require "resty.kafka.protocol.common"
local proto_record             = require "resty.kafka.protocol.record"
local request                  = require "resty.kafka.request"

local table_insert             = table.insert

local _M                       = {}

-- Constants for consumer protocol
_M.LIST_OFFSET_TIMESTAMP_LAST  = -1
_M.LIST_OFFSET_TIMESTAMP_FIRST = -2
_M.LIST_OFFSET_TIMESTAMP_MAX   = -3

-- Join Group Request/Response encoding/decoding
function _M.join_group_encode(consumer, request_data)
  local client = consumer.client

  local api_key = protocol.JoinGroupRequest

  local api_version = client.negotiated_api_versions[api_key]

  local req = request:new(api_key,
    protocol.correlation_id(consumer),
    client.client_id,
    api_version)

  -- JoinGroupRequest fields
  req:string(request_data.group_id)            -- GroupId
  req:int32(request_data.session_timeout_ms)   -- SessionTimeout

  if api_version >= 1 then
    req:int32(request_data.rebalance_timeout_ms)     -- RebalanceTimeout
  end

  req:string(request_data.member_id)   -- MemberId

  if api_version >= 5 then
    req:string(request_data.group_instance_id or "")     -- GroupInstanceId
  end

  req:string(request_data.protocol_type)   -- ProtocolType ("consumer")

  -- GroupProtocols array
  req:int32(#request_data.protocols)
  for _, proto in ipairs(request_data.protocols) do
    req:string(proto.name)     -- ProtocolName (AssignmentStrategy)

    -- Encode ProtocolMetadata as bytes
    local metadata = proto.metadata
    local metadata_len = 2 + 4                       -- version + topics array length
    for _, topic in ipairs(metadata.topics or {}) do
      metadata_len = metadata_len + 2 + #topic       -- string length + string
    end
    -- Handle nil or missing user_data
    local user_data = metadata.user_data or ""
    metadata_len = metadata_len + 4 + #user_data     -- bytes length + bytes

    req:int32(metadata_len)                          -- Length prefix for bytes
    req:int16(metadata.version)                      -- Version
    req:int32(#(metadata.topics or {}))              -- Topics array length
    for _, topic in ipairs(metadata.topics or {}) do
      req:string(topic)                              -- Topic
    end
    req:bytes(user_data)                             -- UserData
  end

  return req
end

function _M.join_group_decode(resp)
  local api_version = resp.api_version

  if api_version >= 2 then
    resp:int32()     -- throttle_time_ms
  end

  local result = {
    error_code = resp:int16(),
    generation_id = resp:int32(),
    protocol_name = resp:string(),
    leader = resp:string(),
    member_id = resp:string(),
  }

  -- Decode members array
  local member_count = resp:int32()
  result.members = {}
  for i = 1, member_count do
    local member = {
      member_id = resp:string(),
      group_instance_id = nil       -- for api_version >= 5
    }

    if api_version >= 5 then
      member.group_instance_id = resp:nullable_string()
    end

    -- Read metadata size first
    local metadata_size = resp:int32()
    if metadata_size > 0 then
      local metadata = {
        version = resp:int16(),
        topics = {}
      }

      local topic_count = resp:int32()
      for j = 1, topic_count do
        table.insert(metadata.topics, resp:string())
      end

      -- Read user data at the end
      metadata.user_data = resp:bytes()
      member.metadata = metadata
    end

    table.insert(result.members, member)
  end

  return result
end

-- Sync Group Request/Response encoding/decoding
function _M.sync_group_encode(consumer, request_data)
  local client = consumer.client
  local api_key = protocol.SyncGroupRequest

  local api_version = client.negotiated_api_versions[api_key]

  local req = request:new(api_key,
    protocol.correlation_id(consumer),
    client.client_id,
    api_version)

  -- SyncGroupRequest => GroupId GenerationId MemberId GroupAssignment
  req:string(request_data.group_id)
  req:int32(request_data.generation_id)
  req:string(request_data.member_id)

  -- GroupAssignment => [MemberId MemberAssignment]
  local assignments = request_data.group_assignments or {}
  req:int32(#assignments)

  for _, assignment in ipairs(assignments) do
    req:string(assignment.member_id)

    -- MemberAssignment => Version PartitionAssignment UserData
    -- First calculate total size
    local size = 2      -- version (int16)
    size = size + 4     -- topics array length (int32)

    for _, topic_data in ipairs(assignment.assignment.topics) do
      size = size + 2 + #topic_data.topic              -- topic string length + topic
      size = size + 4                                  -- partitions array length
      size = size + (4 * #topic_data.partitions)       -- each partition is int32
    end

    size = size + 4     -- user_data length
    if assignment.assignment.user_data then
      size = size + #assignment.assignment.user_data
    end

    -- Write total size of member assignment
    req:int32(size)

    -- Write member assignment content
    req:int16(assignment.assignment.version)
    req:int32(#assignment.assignment.topics)

    for _, topic_data in ipairs(assignment.assignment.topics) do
      req:string(topic_data.topic)
      req:int32(#topic_data.partitions)
      for _, partition in ipairs(topic_data.partitions) do
        req:int32(partition)
      end
    end

    req:bytes(assignment.assignment.user_data or "")
  end

  return req
end

function _M.sync_group_decode(resp)
  local api_version = resp.api_version

  if api_version >= 1 then
    resp:int32()     -- throttle_time_ms
  end

  -- SyncGroupResponse => ErrorCode MemberAssignment
  local result = {
    error_code = resp:int16()
  }

  -- Read member assignment directly
  local assignment_size = resp:int32()   -- Get size first
  if assignment_size > 0 then
    local assignment = {
      version = resp:int16(),
      topics = {}
    }

    -- Decode PartitionAssignment => [Topic [Partition]]
    local topic_count = resp:int32()
    for i = 1, topic_count do
      local topic = {
        topic = resp:string(),
        partitions = {}
      }

      local partition_count = resp:int32()
      for j = 1, partition_count do
        table.insert(topic.partitions, resp:int32())
      end

      table.insert(assignment.topics, topic)
    end

    -- UserData => bytes
    assignment.user_data = resp:bytes()
    result.member_assignment = assignment
  end

  return result
end

-- Heartbeat Request/Response encoding/decoding
function _M.heartbeat_encode(consumer, request_data)
  local client = consumer.client
  local api_key = protocol.HeartBeatRequest

  local api_version = client.negotiated_api_versions[api_key]

  local req = request:new(api_key,
    protocol.correlation_id(consumer),
    client.client_id,
    api_version)

  req:string(request_data.group_id)
  req:int32(request_data.generation_id)
  req:string(request_data.member_id)

  return req
end

function _M.heartbeat_decode(resp)
  local api_version = resp.api_version

  if api_version >= 1 then
    resp:int32()     -- throttle_time_ms
  end

  return {
    error_code = resp:int16()
  }
end

-- Offset Commit Request/Response encoding/decoding
function _M.offset_commit_encode(consumer, request_data)
  local client = consumer.client
  local api_key = request.OffsetCommitRequest

  local api_version = client.negotiated_api_versions[api_key]

  local req = request:new(api_key,
    protocol.correlation_id(consumer),
    client.client_id,
    api_version)

  req:string(request_data.group_id)
  req:int32(request_data.generation_id)
  req:string(request_data.member_id)

  if api_version >= 2 then
    req:int64(request_data.retention_time or -1)
  end

  -- Encode topics
  local topics = request_data.topics
  req:int32(#topics)
  for _, topic in ipairs(topics) do
    req:string(topic.name)
    -- Encode partitions
    req:int32(#topic.partitions)
    for _, partition in ipairs(topic.partitions) do
      req:int32(partition.partition)
      req:int64(partition.offset)
      if api_version >= 1 then
        req:int64(partition.timestamp or -1)
      end
      req:string(partition.metadata or "")
    end
  end

  return req
end

function _M.offset_commit_decode(resp)
  local api_version = resp.api_version

  if api_version >= 3 then
    resp:int32()     -- throttle_time_ms
  end

  local result = {
    topics = {}
  }

  local topic_count = resp:int32()
  for i = 1, topic_count do
    local topic = {
      name = resp:string(),
      partitions = {}
    }

    local partition_count = resp:int32()
    for j = 1, partition_count do
      table.insert(topic.partitions, {
        partition = resp:int32(),
        error_code = resp:int16()
      })
    end

    table.insert(result.topics, topic)
  end

  return result
end

local function _list_offset_encode(req, isolation_level, topic_partitions)
  req:int32(-1)   -- replica_id

  if req.api_version >= protocol.API_VERSION_V2 then
    req:int8(isolation_level)     -- isolation_level
  end

  req:int32(topic_partitions.topic_num)   -- [topics] array length

  for topic, partitions in pairs(topic_partitions.topics) do
    req:string(topic)                       -- [topics] name
    req:int32(partitions.partition_num)     -- [topics] [partitions] array length

    for partition_id, partition_info in pairs(partitions.partitions) do
      req:int32(partition_id)                   -- [topics] [partitions] partition_index
      req:int64(partition_info.timestamp)       -- [topics] [partitions] timestamp

      if req.api_version == protocol.API_VERSION_V0 then
        req:int32(1)         -- [topics] [partitions] max_num_offsets
      end
    end
  end

  return req
end


local function _fetch_encode(req, isolation_level, topic_partitions, rack_id)
  req:int32(-1)    -- replica_id
  req:int32(100)   -- max_wait_ms
  req:int32(0)     -- min_bytes

  if req.api_version >= protocol.API_VERSION_V3 then
    req:int32(10 * 1024 * 1024)     -- max_bytes: 10MB
  end

  if req.api_version >= protocol.API_VERSION_V4 then
    req:int8(isolation_level)     -- isolation_level
  end

  if req.api_version >= protocol.API_VERSION_V7 then
    req:int32(0)      -- session_id
    req:int32(-1)     -- session_epoch
  end

  req:int32(topic_partitions.topic_num)   -- [topics] array length

  for topic, partitions in pairs(topic_partitions.topics) do
    req:string(topic)                       -- [topics] name
    req:int32(partitions.partition_num)     -- [topics] [partitions] array length

    for partition_id, partition_info in pairs(partitions.partitions) do
      req:int32(partition_id)       -- [topics] [partitions] partition

      if req.api_version >= protocol.API_VERSION_V9 then
        req:int32(-1)         -- [topics] [partitions] current_leader_epoch
      end

      req:int64(partition_info.offset)       -- [topics] [partitions] fetch_offset

      if req.api_version >= protocol.API_VERSION_V5 then
        req:int64(-1)         -- [topics] [partitions] log_start_offset
      end

      req:int32(10 * 1024 * 1024)       -- [topics] [partitions] partition_max_bytes
    end
  end

  if req.api_version >= protocol.API_VERSION_V7 then
    -- ForgottenTopics list add by KIP-227, only brokers use it, consumers do not use it
    req:int32(0)     -- [forgotten_topics_data] array length
  end

  if req.api_version >= protocol.API_VERSION_V11 then
    req:string(rack_id)     -- rack_id
  end

  return req
end


function _M.list_offset_encode(consumer, topic_partitions, isolation_level)
  local client = consumer.client
  local api_key = request.OffsetRequest

  isolation_level = isolation_level or 0

  local api_version = client.negotiated_api_versions[api_key]

  if api_version < 0 then
    return nil, "API version choice failed"
  end

  local req = request:new(api_key,
    protocol.correlation_id(consumer),
    client.client_id, api_version)

  return _list_offset_encode(req, isolation_level, topic_partitions)
end

function _M.list_offset_decode(resp)
  local api_version = resp.api_version

  local throttle_time_ms   -- throttle_time_ms
  if api_version >= protocol.API_VERSION_V2 then
    throttle_time_ms = resp:int32()
  end

  local topic_num = resp:int32()   -- [topics] array length

  local topic_partitions = {
    topic_num = topic_num,
    topics = {},
  }

  for i = 1, topic_num do
    local topic = resp:string()            -- [topics] name
    local partition_num = resp:int32()     -- [topics] [partitions] array length

    topic_partitions.topics[topic] = {
      partition_num = partition_num,
      partitions = {}
    }

    for j = 1, partition_num do
      local partition = resp:int32()       -- [topics] [partitions] partition_index

      if api_version == protocol.API_VERSION_V0 then
        topic_partitions.topics[topic].partitions[partition] = {
          errcode = resp:int16(),                    -- [topics] [partitions] error_code
          offset = tostring(resp:int64()),           -- [topics] [partitions] offset
        }
      else
        topic_partitions.topics[topic].partitions[partition] = {
          errcode = resp:int16(),                       -- [topics] [partitions] error_code
          timestamp = tostring(resp:int64()),           -- [topics] [partitions] timestamp
          offset = tostring(resp:int64()),              -- [topics] [partitions] offset
        }
      end
    end
  end

  return topic_partitions, throttle_time_ms
end

function _M.fetch_encode(consumer, topic_partitions)
  local client = consumer.client

  local isolation_level = 0
  local client_rack = "default"
  local api_key = request.FetchRequest
  local api_version = client.negotiated_api_versions[api_key]

  local req = request:new(api_key,
    protocol.correlation_id(consumer),
    client.client_id, api_version)


  local req = _fetch_encode(req, isolation_level, topic_partitions, client_rack)
  return req
end

function _M.fetch_decode(resp, fetch_offset)
  local fetch_info = {}
  local api_version = resp.api_version

  if api_version >= protocol.API_VERSION_V1 then
    fetch_info.throttle_time_ms = resp:int32()     -- throttle_time_ms
  end

  if api_version >= protocol.API_VERSION_V7 then
    fetch_info.errcode = resp:int16()        -- error_code
    fetch_info.session_id = resp:int32()     -- session_id
  end

  local topic_num = resp:int32()   -- [responses] array length

  local topic_partitions = {
    topic_num = topic_num,
    topics = {},
  }

  for i = 1, topic_num do
    local topic = resp:string()            -- [responses] topic
    local partition_num = resp:int32()     -- [responses] [partitions] array length

    topic_partitions.topics[topic] = {
      partition_num = partition_num,
      partitions = {}
    }

    for j = 1, partition_num do
      local partition = resp:int32()       -- [responses] [partitions] partition_index

      local partition_ret = {
        errcode = resp:int16(),                -- [responses] [partitions] error_code
        high_watermark = resp:int64(),         -- [responses] [partitions] high_watermark
      }

      if api_version >= protocol.API_VERSION_V4 then
        partition_ret.last_stable_offset = resp:int64()         -- [responses] [partitions] last_stable_offset

        if api_version >= protocol.API_VERSION_V5 then
          partition_ret.log_start_offset = resp:int64()           -- [responses] [partitions] log_start_offset
        end

        local aborted_transactions_num = resp:int32()
        partition_ret.aborted_transactions = {}
        for k = 1, aborted_transactions_num do
          table_insert(partition_ret.aborted_transaction, {
            producer_id = resp:int64(),              -- [responses] [partitions] [aborted_transactions] producer_id
            first_offset = resp:int64(),             -- [responses] [partitions] [aborted_transactions] first_offset
          })
        end
      end

      if api_version >= protocol.API_VERSION_V11 then
        partition_ret.preferred_read_replica = resp:int32()         -- [responses] [partitions] preferred_read_replica
      end

      partition_ret.records = proto_record.message_set_decode(resp, fetch_offset)       -- [responses] [partitions] records

      topic_partitions.topics[topic].partitions[partition] = partition_ret
    end
  end

  return topic_partitions, fetch_info
end

function _M.offset_fetch_encode(consumer, request_data)
  local client = consumer.client
  local api_key = protocol.OffsetFetchRequest
  local api_version = client.negotiated_api_versions[api_key]

  local req = request:new(api_key,
    protocol.correlation_id(consumer),
    client.client_id,
    api_version)

  -- OffsetFetch Request fields
  req:string(request_data.group_id)   -- group_id

  -- Topics array
  req:int32(#request_data.topics)   -- [topics] array length
  for _, topic in pairs(request_data.topics) do
    req:string(topic.topic)         -- name

    -- Partition indexes array
    req:int32(#topic.partitions)     -- [partition_indexes] array length
    for _, partition in ipairs(topic.partitions) do
      req:int32(partition)           -- partition index
    end
  end

  return req
end

function _M.offset_fetch_decode(resp)
  local error_codes = {}

  local result = {
    topics = {}
  }

  local topic_count = resp:int32()
  for i = 1, topic_count do
    local topic = {
      name = resp:string(),
      partitions = {}
    }

    local partition_count = resp:int32()
    for j = 1, partition_count do
      local partition = {
        partition_index = resp:int32(),
        committed_offset = resp:int64(),
        metadata = resp:nullable_string(),
        error_code = resp:int16()
      }
      if partition.error_code ~= 0 then
        error_codes[partition.partition_index] = partition.error_code
      end


      table.insert(topic.partitions, partition)
    end

    table.insert(result.topics, topic)
  end

  return result, error_codes
end

return _M
