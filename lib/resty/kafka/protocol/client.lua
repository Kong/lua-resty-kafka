local request = require "resty.kafka.request"

local ok, new_tab = pcall(require, "table.new")

if not ok then
    new_tab = function (narr, nrec) return {} end
end

local _M = {}

function _M.metadata_encode(client_id, topics, api_version)
  local id = 0   -- hard code correlation_id
  local _api_version = api_version or 0
  local req = request:new(request.MetadataRequest, id, client_id, _api_version)
  local num = #topics

  req:int32(num)

  for i = 1, num do
    req:string(topics[i])
  end

  return req
end


function _M.metadata_decode(resp)
    local bk_num = resp:int32()
    local brokers = new_tab(0, bk_num)

    for i = 1, bk_num do
        local nodeid = resp:int32();
        brokers[nodeid] = {
            host = resp:string(),
            port = resp:int32(),
        }
    end

    -- records errors on a topic basis
    -- possible errors are
    -- * UnknownTopic (3)
    -- * LeaderNotAvailable (5)
    -- * InvalidTopic (17)
    -- * TopicAuthorizationFailed (29)
    -- topic
    local errors =  {}

    local topic_num = resp:int32()
    local topics = new_tab(0, topic_num)

    for i = 1, topic_num do
        local tp_errcode = resp:int16()
        local topic = resp:string()

        local partition_num = resp:int32()
        local topic_info = new_tab(partition_num - 1, 3)

        topic_info.errcode = tp_errcode
        if tp_errcode ~= 0 then
            errors[topic] = tp_errcode
        end
        topic_info.num = partition_num

        for j = 1, partition_num do
            local partition_info = new_tab(0, 5)

            partition_info.errcode = resp:int16()
            partition_info.id = resp:int32()
            partition_info.leader = resp:int32()

            local repl_num = resp:int32()
            local replicas = new_tab(repl_num, 0)
            for m = 1, repl_num do
                replicas[m] = resp:int32()
            end
            partition_info.replicas = replicas

            local isr_num = resp:int32()
            local isr = new_tab(isr_num, 0)
            for m = 1, isr_num do
                isr[m] = resp:int32()
            end
            partition_info.isr = isr

            topic_info[partition_info.id] = partition_info
        end
        topics[topic] = topic_info
    end

    return brokers, topics, errors
end

return _M
