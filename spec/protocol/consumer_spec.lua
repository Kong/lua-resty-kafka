local consumer_protocol = require "resty.kafka.protocol.consumer"
local response = require "resty.kafka.response"

describe("consumer protocol", function()
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
      local b64_resp =
      "AAAAyQAAAAEAAAAAAAAAAAAGAA1hbGwtb24tbGVhZGVyAC13b3JrZXI4MC05MjdjN2I2Mi02OTZiLTQ4Y2UtYmE0MS1iOWI3ZDNhYWQ2MGQALXdvcmtlcjgwLTkyN2M3YjYyLTY5NmItNDhjZS1iYTQxLWI5YjdkM2FhZDYwZAAAAAEALXdvcmtlcjgwLTkyN2M3YjYyLTY5NmItNDhjZS1iYTQxLWI5YjdkM2FhZDYwZAAAABcAAQAAAAIABHRlc3QABXRlc3QxAAAAAA=="
      local resp_str = ngx.decode_base64(b64_resp)

      local resp = response:new(resp_str, 2)
      resp:int4()       -- Skip message size

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
