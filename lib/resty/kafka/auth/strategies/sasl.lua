local response = require "resty.kafka.response"
local request = require "resty.kafka.request"
local scramformatter = require "resty.kafka.auth.scram.scramformatter"

local to_int32 = response.to_int32
local pid = ngx.worker.pid

local _M = {}
local mt = { __index = _M }

local MECHANISM_PLAINTEXT = "PLAIN"
local MECHANISM_SCRAMSHA256 = "SCRAM-SHA-256"
local SEP = string.char(0)

local function normalize_username(username)
    -- TODO:
    -- * add SASLprep from external C lib
    -- * also use SASLprep for passwords
    username = username:gsub("=2C", ",");
	username = username:gsub("=3D", "=");
    return username
end

local function gen_nonce()
    -- the nonces must be normalized with the SASLprep algorithm
    -- see: https://datatracker.ietf.org/doc/html/rfc3454#section-7
    local openssl_rand = require("resty.openssl.rand")

    -- '18' is the number set by postgres on the server side
    -- todo: does thsi change anything for us? Don't think so
    local rand_bytes, err = openssl_rand.bytes(18)

    if not (rand_bytes) then
        return nil, "failed to generate random bytes: " .. tostring(err)
    end

    return ngx.encode_base64(rand_bytes)
end

local c_nonce = gen_nonce()

local function _encode_plaintext(user, pwd)
    return (SEP..user)..(SEP..pwd)
end

local function _encode(mechanism, user, pwd, tokenauth)
    if mechanism  == MECHANISM_PLAINTEXT then
        return _encode_plaintext(user, pwd)
    elseif mechanism== MECHANISM_SCRAMSHA256 then
        -- constructing the client-first-message
        user = normalize_username(user)
        return "n,,n="..user..",r="..c_nonce..",tokenauth=" .. tokenauth
    else
        return ""
    end
end

-- TODO: Duplicate function in broker.lua
local function _sock_send_receive(sock, request)
    local bytes, err = sock:send(request:package())
    if not bytes then
        return nil, err, true
    end

    -- Reading a 4 byte `message_size`
    local len, err = sock:receive(4)

    if not len then
        if err == "timeout" then
            sock:close()
            return nil, err
        end
        return nil, err, true
    end

    local data, err = sock:receive(to_int32(len))
    if not data then
        if err == "timeout" then
            sock:close()
            return nil, err, true
        end
    end

    return response:new(data, request.api_version), nil, true
end

local function _sasl_handshake_decode(resp)
    -- TODO: contains mechanisms supported by the local server
    -- read this like I did with the supported api versions thing
    local err_code =  resp:int16()
    local mechanisms =  resp:string()
    if err_code ~= 0 then
        return err_code, mechanisms
    end
    return 0, nil
end


local function _sasl_auth_decode(resp)
    local err_code = resp:int16()
    local error_msg  = resp:nullable_string()
    local auth_bytes  = resp:bytes()
    if err_code ~= 0 then
        return nil, error_msg
    end
    return 0, nil, auth_bytes
end

local function be_tls_get_certificate_hash(sock)
    local signature
    local pem

    local ssl = require("resty.openssl.ssl").from_socket(sock)
    -- in case we don't have SSL enabled
    if not ssl then
        return ""
    end
    local server_cert = ssl:get_peer_certificate()

    pem = server_cert:to_PEM()

    signature = server_cert:get_signature_name()

    signature = signature:lower()

    if signature:match("md5") or signature:match("sha1") then
    signature = "sha256"
    end

    local openssl_x509 = require("resty.openssl.x509").new(pem, "PEM")

    local openssl_x509_digest, err = openssl_x509:digest(signature, "s")

    if not (openssl_x509_digest) then
    return nil, tostring(err)
    end

    return openssl_x509_digest
end

local function _sasl_auth(self, sock)
    local cli_id = "worker" .. pid()
    local req = request:new(request.SaslAuthenticateRequest, 0, cli_id, request.API_VERSION_V1)
    local mechanism = self.config.mechanism
    local user = self.config.user
    local password = self.config.password
    local tokenauth = tostring(self.config.tokenauth) or "false"
    local msg = _encode(mechanism, user, password, tokenauth)
    req:bytes(msg)

    local resp, err = _sock_send_receive(sock, req)
    if not resp  then
        return nil, err
    end
    local rc, err, server_first_message = _sasl_auth_decode(resp)
    if not rc then
        if err then
            return nil, err
        end
        return nil, "Unkown Error during _sasl_auth"
    end
    if rc and server_first_message == "" then
        return rc, err
    end
    if server_first_message then
        -- presence of 'server_first_message' indicating that we're in SASL/SCRAM land
        -- TODO: usernames and passwords need to be UTF-8
        local nonce = "r=" .. c_nonce
        local username = "n=" .. user
        local client_first_message_bare = username .. "," .. nonce .. ",tokenauth=" .. tokenauth

        local plus = false
        local bare = false

        if mechanism:match("SCRAM%-SHA%-256%-PLUS") then
            plus = true
        elseif mechanism:match("SCRAM%-SHA%-256") then
            bare = true
        else
            return nil, "unsupported SCRAM mechanism name: " .. tostring(msg)
        end

        local gs2_cbind_flag
        local gs2_header
        local cbind_input

        if bare == true then
            gs2_cbind_flag = "n"
            gs2_header = gs2_cbind_flag .. ",,"
            cbind_input = gs2_header
        elseif plus == true then
            -- PLUS isn't implemnented by kafka yet
            local cb_name = "tls-server-end-point"
            gs2_cbind_flag = "p=" .. cb_name
            gs2_header = gs2_cbind_flag .. ",,"
        end

        local cbind_data = be_tls_get_certificate_hash(sock)

        cbind_input = gs2_header .. cbind_data

        local channel_binding = "c=" .. ngx.encode_base64(cbind_input)
        local _,user_salt,iteration_count = server_first_message:match("r=(.+),s=(.+),i=(.+)")

        if tonumber(iteration_count) < 4096 then
          return nil, "Iteration count < 4096 which is the suggested minimum according to RFC 5802."
        end

        --  SaltedPassword  := Hi(Normalize(password), salt, i)
        local salted_password, err = scramformatter:hi(password, user_salt, tonumber(iteration_count))
        if not (salted_password) then
            return nil, tostring(err)
        end

        local client_final_message_without_proof = channel_binding .. "," .. nonce

        local proof, err = scramformatter:client_proof(salted_password, client_first_message_bare, server_first_message, client_final_message_without_proof)
        if not (proof) then
            return nil, tostring(err)
        end

        -- Constructing client-final-message
        local client_final_message = client_final_message_without_proof .. "," .. "p=" .. ngx.encode_base64(proof)

        local req2 = request:new(request.SaslAuthenticateRequest, 0, cli_id, request.API_VERSION_V1)
        req2:bytes(client_final_message)

        -- Sending/receiving client-final-message/server-final-message
        local resp, err = _sock_send_receive(sock, req2)
        if not resp  then
            return nil, err
        end

        -- Decoding server-final-message
        local rc, err, msg = _sasl_auth_decode(resp)
        if not rc then
            if err then
                return nil, err
            end
            return nil, "Unkown Error during _sasl_auth[client-final-message]"
        end

        --  ServerKey       := HMAC(SaltedPassword, "Server Key")
        local server_key, err = scramformatter:hmac(salted_password, "Server Key")
        if not (server_key) then
            return nil, tostring(err)
        end

        local server_signature = scramformatter:server_signature(server_key, client_first_message_bare,
            server_first_message, client_final_message_without_proof)

        local sent_server_signature = msg:match("v=([^,]+)")
        if server_signature ~= sent_server_signature then
            return nil, "authentication exchange unsuccessful"
        end

        return 0, nil
    end
end


local function _sasl_handshake(self, sock)
    local cli_id = "worker" .. pid()
    local api_version = request.API_VERSION_V1

    local req = request:new(request.SaslHandshakeRequest, 0, cli_id, api_version)
    local mechanism = self.config.mechanism
    req:string(mechanism)
    local resp, err = _sock_send_receive(sock, req)
    if not resp  then
        return nil, err
    end
    local rc, mechanism = _sasl_handshake_decode(resp)
    -- the presence of mechanisms indicate that the mechanism used isn't enabled on the Kafka server.
    if mechanism then
        return nil, mechanism
    end
    return rc, nil
end


function _M.new(opts)
    local self = {
        config = opts
    }

    return setmetatable(self, mt)
end

function _M:authenticate(sock)
    local ok, err = _sasl_handshake(self, sock)
    if not ok then
        if err then
            return nil, err
        end
        return nil, "Unkown Error"
    end

    local ok, err = _sasl_auth(self, sock)
    if not ok then
        return nil, err
    end
    return 0, nil
end

return _M
