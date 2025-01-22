local consumer_protocol = require "resty.kafka.protocol.consumer"
local protocol = require "resty.kafka.protocol.common"
local response = require "resty.kafka.response"

describe("consumer protocol", function()
    describe("join_group_encode", function()
        local mock_consumer
        local mock_request_data

        before_each(function()
            -- Setup mock consumer with correlation_id
            mock_consumer = {
                client = {
                    client_id = "test-client",
                    correlation_id = 0
                }
            }

            -- Setup basic request data
            mock_request_data = {
                group_id = "test-group",
                session_timeout_ms = 30000,
                rebalance_timeout_ms = 60000,
                member_id = "test-member",
                group_instance_id = "test-instance",
                protocol_type = "consumer",
                protocols = {
                    {
                        name = "range",
                        metadata = {
                            version = 1,
                            topics = {"test-topic"},
                            user_data = "test-user-data"
                        }
                    }
                }
            }
        end)

        it("should encode basic fields correctly", function()
            local req = consumer_protocol.join_group_encode(mock_consumer, mock_request_data)
            assert.is_not_nil(req)

            assert.are.equal(protocol.JoinGroupRequest, req.api_key)
            assert.are.equal(5, req.api_version)
        end)

        it("should handle nil metadata fields", function()
            mock_request_data.protocols[1].metadata = {
                version = 1
            }
            local req = consumer_protocol.join_group_encode(mock_consumer, mock_request_data)
            assert.is_not_nil(req)
        end)

        it("should handle nil topics array", function()
            mock_request_data.protocols[1].metadata.topics = nil
            local req = consumer_protocol.join_group_encode(mock_consumer, mock_request_data)
            assert.is_not_nil(req)
        end)

        it("should handle empty topics array", function()
            mock_request_data.protocols[1].metadata.topics = {}
            local req = consumer_protocol.join_group_encode(mock_consumer, mock_request_data)
            assert.is_not_nil(req)
        end)

        it("should handle nil user_data", function()
            mock_request_data.protocols[1].metadata.user_data = nil
            local req = consumer_protocol.join_group_encode(mock_consumer, mock_request_data)
            assert.is_not_nil(req)
        end)

        it("should handle empty user_data", function()
            mock_request_data.protocols[1].metadata.user_data = ""
            local req = consumer_protocol.join_group_encode(mock_consumer, mock_request_data)
            assert.is_not_nil(req)
        end)

        it("should handle empty protocols array", function()
            mock_request_data.protocols = {}
            local req = consumer_protocol.join_group_encode(mock_consumer, mock_request_data)
            assert.is_not_nil(req)
        end)

        it("should fail when required fields are missing", function()
            local required_fields = {
                "group_id",
                "session_timeout_ms",
                "member_id",
                "protocol_type",
                "protocols"
            }

            for _, field in ipairs(required_fields) do
                local saved_value = mock_request_data[field]
                mock_request_data[field] = nil

                assert.has_error(function()
                    consumer_protocol.join_group_encode(mock_consumer, mock_request_data)
                end)

                mock_request_data[field] = saved_value
            end
        end)
    end)

    describe("join_group_decode", function()

        it("should decode join group response correctly", function()
            --[[
            Kafka (JoinGroup v2 Response)
                Length: 201
                Correlation ID: 1
                [Request Frame: 99]
                [API Key: JoinGroup (11)]
                [API Version: 2]
                Throttle time: 0
                Error: No Error (0)
                Generation ID: 6
                Protocol Name: all-on-leader
                Leader ID: worker80-927c7b62-696b-48ce-ba41-b9b7d3aad60d
                Consumer Group Member ID: worker80-927c7b62-696b-48ce-ba41-b9b7d3aad60d
                Members
                    Member (Member=worker80-927c7b62-696b-48ce-ba41-b9b7d3aad60d)
                        Consumer Group Member ID: worker80-927c7b62-696b-48ce-ba41-b9b7d3aad60d
                        Member Metadata: 0001000000020004746573740005746573743100000000
            -- ]]

            -- From wireshark
            local b64_resp = "AAAAyQAAAAEAAAAAAAAAAAAGAA1hbGwtb24tbGVhZGVyAC13b3JrZXI4MC05MjdjN2I2Mi02OTZiLTQ4Y2UtYmE0MS1iOWI3ZDNhYWQ2MGQALXdvcmtlcjgwLTkyN2M3YjYyLTY5NmItNDhjZS1iYTQxLWI5YjdkM2FhZDYwZAAAAAEALXdvcmtlcjgwLTkyN2M3YjYyLTY5NmItNDhjZS1iYTQxLWI5YjdkM2FhZDYwZAAAABcAAQAAAAIABHRlc3QABXRlc3QxAAAAAA=="
            local resp_str = ngx.decode_base64(b64_resp)

            local resp = response:new(resp_str, 2)
            resp:int4()  -- Skip message size

            local result = consumer_protocol.join_group_decode(resp)

            -- Verify the decoded fields
            assert.are.equal(0, result.error_code)
            assert.are.equal("all-on-leader", result.protocol_name)

            local expected_member_id = "worker80-927c7b62-696b-48ce-ba41-b9b7d3aad60d"
            assert.are.equal(expected_member_id, result.member_id)

            -- Verify members array
            assert.are.equal(1, #result.members)
            local member = result.members[1]
            assert.are.equal(expected_member_id, member.member_id)

            -- Verify member metadata
            assert.is_table(member.metadata)
            assert.are.equal(1, member.metadata.version)
            assert.are.equal(2, #member.metadata.topics)
            assert.are.equal("test", member.metadata.topics[1])
            assert.are.equal("test1", member.metadata.topics[2])
        end)
    end)
end)
