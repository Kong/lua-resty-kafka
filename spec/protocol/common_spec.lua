local common = require "resty.kafka.protocol.common"

describe("protocol common", function()
    describe("correlation_id", function()
        it("should generate sequential IDs", function()
            local correlated = { correlation_id = 0 }
            assert.are.equal(1, common.correlation_id(correlated))
            assert.are.equal(2, common.correlation_id(correlated))
            assert.are.equal(3, common.correlation_id(correlated))
        end)

        it("should handle nil correlation_id", function()
            local correlated = {}
            assert.are.equal(1, common.correlation_id(correlated))
            assert.are.equal(2, common.correlation_id(correlated))
        end)

        it("should wrap around at 2^30", function()
            local correlated = { correlation_id = 1073741823 } -- 2^30 - 1
            assert.are.equal(0, common.correlation_id(correlated))
            assert.are.equal(1, common.correlation_id(correlated))
        end)

        it("should handle large numbers", function()
            local correlated = { correlation_id = 1073741820 } -- near 2^30
            assert.are.equal(1073741821, common.correlation_id(correlated))
            assert.are.equal(1073741822, common.correlation_id(correlated))
            assert.are.equal(1073741823, common.correlation_id(correlated))
            assert.are.equal(0, common.correlation_id(correlated))
        end)
    end)
end)
