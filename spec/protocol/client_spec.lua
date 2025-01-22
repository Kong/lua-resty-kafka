local client_protocol = require "resty.kafka.protocol.client"
local response = require "resty.kafka.response"
local protocol = require "resty.kafka.protocol.common"
local request = require "resty.kafka.request"

describe("client protocol", function()
    describe("metadata_encode", function()
        it("should encode basic metadata request correctly", function()
            local topics = {"test-topic"}
            local client_id = "test-client"
            local req = client_protocol.metadata_encode(client_id, topics)

            assert.is_not_nil(req)
            assert.are.equal(request.MetadataRequest, req.api_key)
            assert.are.equal(0, req.api_version)  -- Default version is 0
        end)

        it("should handle empty topics list", function()
            local client_id = "test-client"
            local req = client_protocol.metadata_encode(client_id, {})

            assert.is_not_nil(req)
            assert.are.equal(request.MetadataRequest, req.api_key)
            assert.are.equal(0, req.api_version)
        end)
    end)

    describe("metadata_decode", function()
        it("should decode metadata response correctly", function()
            -- Create a mock response that matches the expected format
            -- From wireshark
            -- Transmission Control Protocol, Src Port: 9092, Dst Port: 49242, Seq: 1, Ack: 34, Len: 581
            -- Kafka (Metadata v0 Response)
            --     Length: 577
            --     Correlation ID: 0
            --     [Request Frame: 18]
            --     [API Key: Metadata (3)]
            --     [API Version: 0]
            --     Broker Metadata
            --         Broker (node 2: broker2:9092)
            --         Broker (node 1: broker:9092)
            --     Topic Metadata
            --         Topic (test)
            --             Error: No Error (0)
            --             Topic Name: test
            --             Partition (ID=0)
            --             Partition (ID=5)
            --             Partition (ID=10)
            --             Partition (ID=15)
            --             Partition (ID=9)
            --             Partition (ID=11)
            --             Partition (ID=16)
            --             Partition (ID=4)
            --             Partition (ID=17)
            --             Partition (ID=3)
            --             Partition (ID=13)
            --             Partition (ID=18)
            --             Partition (ID=2)
            --             Partition (ID=8)
            --             Partition (ID=12)
            --             Partition (ID=19)
            --             Partition (ID=14)
            --             Partition (ID=1)
            --             Partition (ID=6)
            --             Partition (ID=7)

            local b64_resp = "AAACQQAAAAAAAAACAAAAAgAHYnJva2VyMgAAI4QAAAABAAZicm9rZXIAACOEAAAAAQAAAAR0ZXN0AAAAFAAAAAAAAAAAAAEAAAABAAAAAQAAAAEAAAABAAAAAAAFAAAAAgAAAAEAAAACAAAAAQAAAAIAAAAAAAoAAAABAAAAAQAAAAEAAAABAAAAAQAAAAAADwAAAAIAAAABAAAAAgAAAAEAAAACAAAAAAAJAAAAAgAAAAEAAAACAAAAAQAAAAIAAAAAAAsAAAACAAAAAQAAAAIAAAABAAAAAgAAAAAAEAAAAAEAAAABAAAAAQAAAAEAAAABAAAAAAAEAAAAAQAAAAEAAAABAAAAAQAAAAEAAAAAABEAAAACAAAAAQAAAAIAAAABAAAAAgAAAAAAAwAAAAIAAAABAAAAAgAAAAEAAAACAAAAAAANAAAAAgAAAAEAAAACAAAAAQAAAAIAAAAAABIAAAABAAAAAQAAAAEAAAABAAAAAQAAAAAAAgAAAAEAAAABAAAAAQAAAAEAAAABAAAAAAAIAAAAAQAAAAEAAAABAAAAAQAAAAEAAAAAAAwAAAABAAAAAQAAAAEAAAABAAAAAQAAAAAAEwAAAAIAAAABAAAAAgAAAAEAAAACAAAAAAAOAAAAAQAAAAEAAAABAAAAAQAAAAEAAAAAAAEAAAACAAAAAQAAAAIAAAABAAAAAgAAAAAABgAAAAEAAAABAAAAAQAAAAEAAAABAAAAAAAHAAAAAgAAAAEAAAACAAAAAQAAAAI="
            local resp_str = ngx.decode_base64(b64_resp)

            local resp = response:new(resp_str, 2)
            resp:int4()  -- Skip message size

            local brokers, topics, errors = client_protocol.metadata_decode(resp)
            assert.is_table(brokers)
            assert(#brokers > 0)
            assert.is_table(topics)
            -- has topic test and has partitions
            assert(#topics["test"] > 0)
            -- has no errors
            assert.is_table(errors)
            assert(#errors == 0)
        end)
    end)
end)
