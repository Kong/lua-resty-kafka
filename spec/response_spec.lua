local request = require "resty.kafka.request"

describe("test request lib TODO", function()
  -- TODO: test the new string, nullable_string and bytes as well

  it("test packing", function()
    local req = request:new(request.ProduceRequest, 1, "clientid")
    req:int16(-1 * math.pow(2, 15))
    local hex = convert_to_hex(req)
    assert.is.equal(hex, "8000")
    req:int16(math.pow(2, 15) - 1)
    local hex = convert_to_hex(req)
    assert.is.equal(hex, "7fff")
    req:int16(-1)
    local hex = convert_to_hex(req)
    assert.is.equal(hex, "ffff")
    req:int32(-1 * math.pow(2, 31))
    local hex = convert_to_hex(req)
    assert.is.equal(hex, "80000000")
    req:int32(math.pow(2, 31) - 1)
    local hex = convert_to_hex(req)
    assert.is.equal(hex, "7fffffff")
    req:int64(-1LL * math.pow(2, 32) * math.pow(2, 31))
    local hex = convert_to_hex(req)
    assert.is.equal(hex, "8000000000000000")
    req:int64(1ULL * math.pow(2, 32) * math.pow(2, 31) - 1)
    local hex = convert_to_hex(req)
    assert.is.equal(hex, "7fffffffffffffff")
  end)

  it("test response unpacking", function()

    local num, eq = compare("int16", 0x7fff)
    assert.is.equal(num, "32767")
    assert.is_true(eq)
    local num, eq = compare("int16", 0x7fff * -1 - 1)
    assert.is.equal(num, "-32768")
    assert.is_true(eq)
    local num, eq = compare("int32", 0x7fffffff)
    assert.is.equal(num, "2147483647")
    assert.is_true(eq)
    local num, eq = compare("int32", 0x7fffffff * -1 - 1)
    assert.is.equal(num, "-2147483648")
    assert.is_true(eq)
    local num, eq = compare("int64", 1ULL * math.pow(2, 32) * math.pow(2, 31) - 1)
    assert.is.equal(num, "9223372036854775807ULL")
    assert.is_true(eq)
    local num, eq = compare("int64", -1LL * math.pow(2, 32) * math.pow(2, 31))
    assert.is.equal(num, "-9223372036854775808LL")
    assert.is_true(eq)
  end)

end)