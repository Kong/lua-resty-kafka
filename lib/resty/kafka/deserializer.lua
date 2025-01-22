local cjson = require("cjson")

local DESERIALIZER_JSON = "json"
local DESERIALIZER_NOOP = "noop"

local function deserialize_noop(value)
  return value
end

local function deserialize_json(value)
  return cjson.decode(value)
end

local function deserialize(value, deserializer)
  if deserializer == DESERIALIZER_JSON then
    return deserialize_json(value)
  elseif deserializer == DESERIALIZER_NOOP then
    return deserialize_noop(value)
  end
end


return {
  deserialize = deserialize,
}
