package = "kong-lua-resty-kafka"
version = "0.20-0"
source = {
   url = "git+https://github.com/Kong/lua-resty-kafka",
   tag = "v0.20"
}
description = {
   summary = "Lua Kafka client driver for the ngx_lua based on the cosocket API",
   detailed = [[
     This package is a fork of https://github.com/doujiang24/lua-resty-kafka that extends
     its functionality for:

     * mTLS support
     * SASL (PLAIN) support
     * SASL (SCRAM-SHA-256, SCRAM-SHA-512) support
     * SASL (SCRAM-SHA-256, SCRAM-SHA-512) Delegation Token support

     This Lua library requires to patch OpenResty with changes made in lua-ngx-module by this PR:
     https://github.com/openresty/lua-nginx-module/pull/1602

     This Lua library is a Kafka client driver for the ngx_lua nginx module:

     http://wiki.nginx.org/HttpLuaModule

     This Lua library takes advantage of ngx_lua's cosocket API, which ensures 100% nonblocking behavior.

     Note that at least ngx_lua 0.9.3 or ngx_openresty 1.4.3.7 is required, and unfortunately only LuaJIT supported (--with-luajit).
   ]],
   homepage = "https://github.com/kong/lua-resty-kafka",
   license = "BSD"
}
dependencies = {
   "lua >= 5.1",
   "lua-resty-openssl",
   "penlight == 1.13.1",
}
build = {
   type = "builtin",
   modules = {
      ["resty.kafka.broker"] = "lib/resty/kafka/broker.lua",
      ["resty.kafka.client"] = "lib/resty/kafka/client.lua",
      ["resty.kafka.errors"] = "lib/resty/kafka/errors.lua",
      ["resty.kafka.producer"] = "lib/resty/kafka/producer.lua",
      ["resty.kafka.request"] = "lib/resty/kafka/request.lua",
      ["resty.kafka.response"] = "lib/resty/kafka/response.lua",
      ["resty.kafka.ringbuffer"] = "lib/resty/kafka/ringbuffer.lua",
      ["resty.kafka.sendbuffer"] = "lib/resty/kafka/sendbuffer.lua",
      ["resty.kafka.auth"] = "lib/resty/kafka/auth/init.lua",
      ["resty.kafka.auth.strategies.sasl"] = "lib/resty/kafka/auth/strategies/sasl.lua",
   }
}
