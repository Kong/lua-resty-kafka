-- Copyright (C) Dejiang Zhu(doujiang24)


local response = require "resty.kafka.response"
local request = require "resty.kafka.request"
local broker = require "resty.kafka.broker"
local client = require "resty.kafka.client"
local Errors = require "resty.kafka.errors"
local sendbuffer = require "resty.kafka.sendbuffer"
local ringbuffer = require "resty.kafka.ringbuffer"
local tablex = require "pl.tablex"

local setmetatable = setmetatable
local timer_at = ngx.timer.at
local timer_every = ngx.timer.every
local is_exiting = ngx.worker.exiting
local ngx_sleep = ngx.sleep
local ngx_log = ngx.log
local ERR = ngx.ERR
local INFO = ngx.INFO
local DEBUG = ngx.DEBUG
local debug = ngx.config.debug
local crc32 = ngx.crc32_short
local pcall = pcall
local pairs = pairs
local tx_deepcompare = tablex.deepcompare
local tx_find = tablex.find

local API_KEY = 0

local API_VERSION_V0 = 0
local API_VERSION_V1 = 1
local API_VERSION_V2 = 2
local API_VERSION_V3 = 3

local ok, new_tab = pcall(require, "table.new")
if not ok then
    new_tab = function (narr, nrec) return {} end
end


local _M = { _VERSION = "0.17" }
local mt = { __index = _M }


-- weak value table is useless here, cause _timer_flush always ref p
-- so, weak value table won't works
local cluster_inited = {}
local DEFAULT_CLUSTER_NAME = 1


local function default_partitioner(key, num, correlation_id)
    local id = key and crc32(key) or correlation_id

    -- partition_id is continuous and start from 0
    return id % num
end


local function correlation_id(self)
    local id = (self.correlation_id + 1) % 1073741824 -- 2^30
    self.correlation_id = id

    return id
end


local function produce_encode(self, topic_partitions)
    local req = request:new(request.ProduceRequest,
                            correlation_id(self), self.client.client_id, self.api_version)

    if self.api_version == 3 then
        -- Add a (NULL) transactional_id
        req:int16(-1)
    end
    req:int16(self.required_acks)
    req:int32(self.request_timeout)
    req:int32(topic_partitions.topic_num)

    for topic, partitions in pairs(topic_partitions.topics) do
        req:string(topic)
        req:int32(partitions.partition_num)

        for partition_id, buffer in pairs(partitions.partitions) do
            req:int32(partition_id)

            -- MessageSetSize and MessageSet
            req:message_set(buffer.queue, buffer.index)
        end
    end

    return req
end


local function produce_decode(resp)
    local topic_num = resp:int32()
    local ret = new_tab(0, topic_num)
    local api_version = resp.api_version

    for i = 1, topic_num do
        local topic = resp:string()
        local partition_num = resp:int32()

        ret[topic] = {}

        -- ignore ThrottleTime
        for j = 1, partition_num do
            local partition = resp:int32()

            if api_version == API_VERSION_V0 or api_version == API_VERSION_V1 then
                ret[topic][partition] = {
                    errcode = resp:int16(),
                    offset = resp:int64(),
                }

            elseif api_version == API_VERSION_V2 or api_version == API_VERSION_V3 then
                ret[topic][partition] = {
                    errcode = resp:int16(),
                    offset = resp:int64(),
                    timestamp = resp:int64(), -- If CreateTime is used, this field is always -1
                }
            end
        end
    end

    return ret
end


local function choose_partition(self, topic, key)
    local brokers, partitions = self.client:fetch_metadata(topic)
    if not brokers then
        return nil, partitions
    end

    return self.partitioner(key, partitions.num, self.correlation_id)
end


local function _flush_lock(self)
    if not self.flushing then
        if debug then
            ngx_log(DEBUG, "flush lock accquired")
        end
        self.flushing = true
        return true
    end
    return false
end


local function _flush_unlock(self)
    if debug then
        ngx_log(DEBUG, "flush lock released")
    end
    self.flushing = false
end


local function _send(self, broker_conf, topic_partitions, sendbuffer)
    local resp, retryable = nil, true

    local bk, err = broker:new(broker_conf.host, broker_conf.port, self.socket_config, self.auth_config)
    if bk then
        local req = produce_encode(self, topic_partitions)

        resp, err, retryable = bk:send_receive(req)
        if resp then
            local result = produce_decode(resp)

            for topic, partitions in pairs(result) do
                for partition_id, r in pairs(partitions) do
                    local errcode = r.errcode

                    if errcode == 0 then
                        sendbuffer:offset(topic, partition_id, r.offset)
                        sendbuffer:clear(topic, partition_id)
                    else
                        err = Errors[errcode]

                        -- XX: only 3, 5, 6 can retry
                        local retryable0 = retryable
                        if errcode ~= 3 and errcode ~= 5 and errcode ~= 6 then
                            retryable0 = false
                        end

                        local index = sendbuffer:err(topic, partition_id, err, retryable0)

                        ngx_log(INFO, "retry to send messages to kafka err: ", err, ", retryable: ", retryable0,
                            ", topic: ", topic, ", partition_id: ", partition_id, ", length: ", index)
                    end
                end
            end

            return
        end
    end

    -- when broker new failed or send_receive failed
    for topic, partitions in pairs(topic_partitions.topics) do
        for partition_id, partition in pairs(partitions.partitions) do
            sendbuffer:err(topic, partition_id, err, retryable)
        end
    end
end


local function _batch_send(self, sendbuffer)
    local try_num = 1
    while try_num <= self.max_retry do
        -- aggregator
        local send_num, sendbroker = sendbuffer:aggregator(self.client)
        if send_num == 0 then
            if sendbuffer:done() then
                return true

            else
                ngx_log(DEBUG, "sendbuffeer queue_num = ", sendbuffer.queue_num, ", race conditions might occur")
                return
            end
        end

        for i = 1, send_num, 2 do
            local broker_conf, topic_partitions = sendbroker[i], sendbroker[i + 1]

            _send(self, broker_conf, topic_partitions, sendbuffer)
        end

        if sendbuffer:done() then
            return true
        end

        self.client:refresh()

        try_num = try_num + 1
        if try_num < self.max_retry then
            ngx_sleep(self.retry_backoff / 1000)   -- ms to s
        end
    end
end


local _flush_buffer


local function _flush(premature, self)
    if not _flush_lock(self) then
        if debug then
            ngx_log(DEBUG, "previous flush not finished")
        end
        return
    end

    local ringbuffer = self.ringbuffer
    local sendbuffer = self.sendbuffer
    while true do
        local topic, key, msg = ringbuffer:pop()
        if not topic then
            break
        end

        local partition_id, err = choose_partition(self, topic, key)
        if not partition_id then
            partition_id = -1
        end

        local overflow = sendbuffer:add(topic, partition_id, key, msg)
        if overflow then    -- reached batch_size in one topic-partition
            break
        end
    end

    local all_done = _batch_send(self, sendbuffer)

    if not all_done then
        for topic, partition_id, buffer in sendbuffer:loop() do
            local queue, index, err, retryable = buffer.queue, buffer.index, buffer.err, buffer.retryable

            if self.error_handle then
                local ok, err = pcall(self.error_handle, topic, partition_id, queue, index, err, retryable)
                if not ok then
                    ngx_log(ERR, "failed to callback error_handle: ", err)
                end
            else
                ngx_log(ERR, "buffered messages send to kafka err: ", err,
                    ", retryable: ", retryable, ", topic: ", topic,
                    ", partition_id: ", partition_id, ", length: ", index / 2)
            end

            sendbuffer:clear(topic, partition_id)
        end
    end

    _flush_unlock(self)

    -- reset _timer_flushing_buffer after flushing complete
    self._timer_flushing_buffer = false

    if ringbuffer:need_send() then
        _flush_buffer(self)

    elseif is_exiting() and ringbuffer:left_num() > 0 then
        -- still can create 0 timer even exiting
        _flush_buffer(self)
    end

    return true
end


_flush_buffer = function (self)
    if self._timer_flushing_buffer then
        if debug then
            ngx_log(DEBUG, "another timer is flushing buffer, skipping it")
        end

        return
    end

    local ok, err = timer_at(0, _flush, self)
    if ok then
        self._timer_flushing_buffer = true
        return
    end

    ngx_log(ERR, "failed to create timer_at timer, err:", err)
end


local function _timer_flush(premature, self)
    self._timer_flushing_buffer = false
    _flush_buffer(self)
end

local function negotiate_api_version(supported_version_map, api_key, max_supported_ver)
    -- Strategy: choose lowest matching version
    --
    -- This introduces less friction with this library. Using newer
    -- APIVersions would require adding new MessageFormats(Records and RecordBatches).
    -- This library currenty only supportes the legacy MessageSet(Message) format.
    -- Falling back to the oldest possible APIVersion ensures longevity of this library.

    -- check cli.supported_api_versions[API_KEY] for min_version
    -- use this if exists. Fail if min_version >= max_supported version.

    local version_map = supported_version_map[api_key]
    if not version_map then
        return nil, "Could not retrieve version map from cluster"
    end
    local min_version = version_map.min_version
    if min_version > max_supported_ver then
        return nil, "This library does not support the minumum required API version("..min_version..") that your Kafka cluster accepts ("..max_supported_ver..")"
    end
    return min_version
end


local function compare_config_opts(opts, cached_producer)
  -- compare config options with cache
  -- return true if values are equal

  local cached_client = cached_producer.client
  local cached_ringbuffer = cached_producer.ringbuffer

  for k1, v1 in pairs(opts) do
    -- compare producer options
    local pkeys = { "required_acks", "request_timeout", "batch_num", "batch_size",
                    "max_retry", "retry_backoff", "flush_time" }
    if tx_find(pkeys, k1) and cached_producer[k1] ~= v1 then
      return false, "config '" .. k1 .. "' is changed"
    end

    if k1 == "producer_type" then
      local async = (v1 == "async")
      if async ~= (not not cached_producer["async"]) then
        return false, "config '" .. k1 .. "' is changed"
      end
    end

    if k1 == "auth_config" and not tx_deepcompare(cached_producer[k1], v1, true) then
      return false, "config '" .. k1 .. "' is changed"
    end

    -- compare redis client options
    local ckeys = { "socket_timeout", "keepalive_timeout", "ssl", "client_cert", "client_priv_key" }
    if tx_find(ckeys, k1) and cached_client["socket_config"][k1] ~= v1 then
      return false, "config '" .. k1 .. "' is changed"
    end

    -- compare ringbuffer options
    if k1 == "max_buffering" and cached_ringbuffer["size"] ~= v1 * 3 then
      return false, "config '" .. k1 .. "' is changed"
    end
  end

  return true
end

local function compare_broker_list(broker_list, cached_producer)
  -- compare broker list with cache
  -- return true if values are equal

  local cached_client = cached_producer.client

  if #broker_list ~= #cached_client.broker_list then
    return false, "config 'broker_list' is changed"
  end

  for _, new_broker in ipairs(broker_list) do
    -- usually there are only a few brokers

    local flg = false
    for _, cached_broker in ipairs(cached_client.broker_list) do
      if tx_deepcompare(new_broker, cached_broker, true) then
        flg = true
        break
      end
    end
    if not flg then
      return false, "config 'broker_list' is changed"
    end
  end

  return true
end

local function is_same_producer_config(broker_list, opts, cached_producer)
  -- if new config has the same values as the cached producer, skip creating

  local ok1, ok2, err

  -- compare broker list
  ok1, err = compare_broker_list(broker_list, cached_producer)
  if not ok1 then
    ngx_log(DEBUG, err)
  end

  -- compare config options
  ok2, err = compare_config_opts(opts, cached_producer)
  if not ok2 then
    ngx_log(DEBUG, err)
  end

  if ok1 and ok2 then
    ngx_log(DEBUG, "the same producer config received")
    return true
  end
  return false
end

function _M.new(self, broker_list, producer_config, cluster_name)
    local name = cluster_name or DEFAULT_CLUSTER_NAME
    local broker_list = broker_list or {}
    local opts = producer_config or {}
    local async = opts.producer_type == "async"

    local cached_producer = cluster_inited[name]
    if async and cached_producer and is_same_producer_config(broker_list, opts, cached_producer) then
      ngx_log(DEBUG, "return cached producer for cluster '", cluster_name, "'")
      return cached_producer

    else
      ngx_log(DEBUG, "creating new producer for cluster '", cluster_name, "'")
    end

    local cli = client:new(broker_list, opts)
    -- Supported API versions obtained from a broker are only valid for the connection on which that information is obtained. In the event of disconnection, the client should obtain the information from the broker again, as the broker might have been upgraded/downgraded in the mean time.
    cli:fetch_apiversions()

    local api_version, neg_err = negotiate_api_version(cli.supported_api_versions, API_KEY, 3)
    if not api_version then
        return nil, neg_err
    end

    local p = setmetatable({
        client = cli,
        correlation_id = 1,
        request_timeout = opts.request_timeout or 2000,
        retry_backoff = opts.retry_backoff or 100,   -- ms
        max_retry = opts.max_retry or 3,
        required_acks = opts.required_acks or 1,
        partitioner = opts.partitioner or default_partitioner,
        error_handle = opts.error_handle,
        api_version = api_version,
        async = async,
        socket_config = cli.socket_config,
        auth_config = cli.auth_config,
        _timer_flushing_buffer = false,
        flush_time = opts.flush_time,
        batch_num = opts.batch_num or 200,
        batch_size = opts.batch_size or 1048576,
        ringbuffer = ringbuffer:new(opts.batch_num or 200, opts.max_buffering or 50000),   -- 200, 50K
        sendbuffer = sendbuffer:new(opts.batch_num or 200, opts.batch_size or 1048576,
                                    opts.max_retry or 3, opts.retry_backoff or 100)
                        -- default: 1K, 1M
                        -- batch_size should less than (MaxRequestSize / 2 - 10KiB)
                        -- config in the kafka server, default 100M
    }, mt)

    if async then
        cluster_inited[name] = p
        local ok, err = timer_every((opts.flush_time or 1000) / 1000, _timer_flush, p) -- default: 1s
        if not ok then
            ngx_log(ERR, "failed to create timer_every, err: ", err)
        end

    end

    return p, nil
end

local function _sync_send(self, topic, key, message)
    local partition_id, err = choose_partition(self, topic, key)
    if not partition_id then
        return nil, err
    end

    -- avoid race conditions
    -- different sendbuffers share self.client in _batch_send()
    local sendbuffer = sendbuffer:new(self.batch_num, self.batch_size, self.max_retry, self.retry_backoff)
    sendbuffer:add(topic, partition_id, key, message)

    local ok = _batch_send(self, sendbuffer)
    if not ok then
        sendbuffer:clear(topic, partition_id)
        return nil, sendbuffer:err(topic, partition_id)
    end

    return sendbuffer:offset(topic, partition_id)
end

-- offset is cdata (LL in luajit)
function _M.send(self, topic, key, message)
    if self.async then
        -- async mode
        local ringbuffer = self.ringbuffer

        local ok, err = ringbuffer:add(topic, key, message)
        if not ok then
            return nil, err
        end

        if not self.flushing and (ringbuffer:need_send() or is_exiting()) then
            _flush_buffer(self)
        end

        return true

    else
        -- sync mode
        return _sync_send(self, topic, key, message)
    end
end


function _M.flush(self)
    return _flush(nil, self)
end


-- offset is cdata (LL in luajit)
function _M.offset(self)
    local topics = self.sendbuffer.topics
    local sum, details = 0, {}

    for topic, partitions in pairs(topics) do
        details[topic] = {}
        for partition_id, buffer in pairs(partitions) do
            sum = sum + buffer.offset
            details[topic][partition_id] = buffer.offset
        end
    end

    return sum, details
end


return _M
