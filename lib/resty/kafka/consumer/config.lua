local _M = {}

-- Constants
local COMMIT_STRATEGY_AUTO = "auto"
local COMMIT_STRATEGY_OFF = "off"
local POLL_STRATEGY_LATEST = "latest"
local POLL_STRATEGY_EARLIEST = "earliest"
local DESERIALIZER_JSON = "json"
local DESERIALIZER_NOOP = "noop"

local function validate_commit_strategy(strategy)
    if not strategy then
        return COMMIT_STRATEGY_AUTO
    end

    if strategy ~= COMMIT_STRATEGY_AUTO and strategy ~= COMMIT_STRATEGY_OFF then
        return nil, "only auto or off commit strategy is supported"
    end

    return strategy
end

local function validate_offset_reset(reset)
    if not reset then
        return POLL_STRATEGY_LATEST
    end

    if reset ~= POLL_STRATEGY_LATEST and reset ~= POLL_STRATEGY_EARLIEST then
        return nil, "only latest or earliest offset reset is supported"
    end

    return reset
end

local function validate_deserializer(deserializer)
    if not deserializer then
        return DESERIALIZER_JSON
    end

    if deserializer ~= DESERIALIZER_JSON and deserializer ~= DESERIALIZER_NOOP then
        return nil, "only json or noop deserializer is supported"
    end

    return deserializer
end

function _M.parse(config)
    if not config then
        config = {}
    end

    local parsed = {}

    -- Validate and set commit strategy
    local commit_strategy, err = validate_commit_strategy(config.commit_strategy)
    if not commit_strategy then
        return nil, err
    end
    parsed.commit_strategy = commit_strategy

    -- Validate and set offset reset
    local offset_reset, err = validate_offset_reset(config.auto_offset_reset)
    if not offset_reset then
        return nil, err
    end
    parsed.auto_offset_reset = offset_reset

    -- Validate and set deserializer
    local deserializer, err = validate_deserializer(config.value_deserializer)
    if not deserializer then
        return nil, err
    end
    parsed.value_deserializer = deserializer

    return parsed
end

-- Export constants
_M.COMMIT_STRATEGY_AUTO = COMMIT_STRATEGY_AUTO
_M.COMMIT_STRATEGY_OFF = COMMIT_STRATEGY_OFF
_M.POLL_STRATEGY_LATEST = POLL_STRATEGY_LATEST
_M.POLL_STRATEGY_EARLIEST = POLL_STRATEGY_EARLIEST
_M.DESERIALIZER_JSON = DESERIALIZER_JSON
_M.DESERIALIZER_NOOP = DESERIALIZER_NOOP

return _M
