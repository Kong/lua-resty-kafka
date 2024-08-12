local client = require "resty.kafka.client"

describe("Client", function()

  describe(":new", function()
    it("accepts a client_id", function()
      local c = client:new({ host = "foo", port = 123 }, { client_id = "test-override" })
      assert.are.equal("test-override", c.client_id)
    end)

    it("defaults to a computed value when client_id is not provided", function()
      local c = client:new({ host = "foo", port = 123 }, { client_id = nil })
      assert.matches("worker%d", c.client_id)
    end)
  end)
end)
