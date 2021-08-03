local bxor = bit.bxor

local _M = {}

-- HMAC(key, str): Apply the HMAC keyed hash algorithm (defined in
-- [RFC2104]) using the octet string represented by "key" as the key
-- and the octet string "str" as the input string.  The size of the
-- result is the hash result size for the hash function in use.  For
-- example, it is 20 octets for SHA-1 (see [RFC3174]).
function _M:hmac(key, str)
    local openssl_hmac = require "resty.openssl.hmac"
    local hmac, err = openssl_hmac.new(key, "sha256")

    if not (hmac) then
      return nil, tostring(err)
    end

    hmac:update(str)

    local final_hmac, err = hmac:final()

    if not (final_hmac) then
      return nil, tostring(err)
    end

    return final_hmac
end


-- H(str): Apply the cryptographic hash function to the octet string
-- "str", producing an octet string as a result.  The size of the
-- result depends on the hash result size for the hash function in
-- use.
function _M:h(str)
  local resty_sha256 = require "resty.sha256"
  local openssl_digest = resty_sha256:new()

  if not (openssl_digest) then
    return nil, tostring("TODO err")
  end

  openssl_digest:update(str)

  local digest, err = openssl_digest:final()

  if not (digest) then
    return nil, tostring(err)
  end

  return digest
end


-- XOR: Apply the exclusive-or operation to combine the octet string
-- on the left of this operator with the octet string on the right of
-- this operator.  The length of the output and each of the two
-- inputs will be the same for this use.
function _M:xor(a, b)
  local result = {}

  for i = 1, #a do
    local x = a:byte(i)
    local y = b:byte(i)

    if not (x) or not (y) then
      return
    end

    result[i] = string.char(bxor(x, y))
  end

  return table.concat(result)
end


-- Hi(str, salt, i):

-- U1   := HMAC(str, salt + INT(1))
-- U2   := HMAC(str, U1)
-- ...
-- Ui-1 := HMAC(str, Ui-2)
-- Ui   := HMAC(str, Ui-1)

-- Hi := U1 XOR U2 XOR ... XOR Ui

-- where "i" is the iteration count, "+" is the string concatenation
-- operator, and INT(g) is a 4-octet encoding of the integer g, most
-- significant octet first.

-- Hi() is, essentially, PBKDF2 [RFC2898] with HMAC() as the
-- pseudorandom function (PRF) and with dkLen == output length of
-- HMAC() == output length of H().
function _M:hi(str, salt, i)
  local openssl_kdf = require "resty.openssl.kdf"

  salt = ngx.decode_base64(salt)

  local key, err = openssl_kdf.derive({
    type = openssl_kdf.PBKDF2,
    md = "sha256",
    salt = salt,
    pbkdf2_iter = i,
    pass = str,
    outlen = 32 -- our H() produces a 32 byte hash value (SHA-256)
  })

  if not (key) then
    return nil, "failed to derive pbkdf2 key: " .. tostring(err)
  end

  return key
end


function _M:auth_message(client_first_message_bare, server_first_message, client_final_message_without_proof)
  return client_first_message_bare .. "," .. server_first_message .. "," .. client_final_message_without_proof
end


function _M:client_proof(salted_password, client_first_msg, server_first_msg, client_final_msg_without_proof)
  --  ClientKey       := HMAC(SaltedPassword, "Client Key")
  local client_key, err = self:hmac(salted_password, "Client Key")
  if not (client_key) then
    return nil, tostring(err)
  end

  --  StoredKey       := H(ClientKey)
  local stored_key, err = self:h(client_key)
  if not (stored_key) then
    return nil, tostring(err)
  end

  --  ClientSignature := HMAC(StoredKey, AuthMessage)
  local client_signature, err = self:hmac(stored_key, self:auth_message(client_first_msg, server_first_msg, client_final_msg_without_proof))
  if not (client_signature) then
    return nil, tostring(err)
  end

  --  ClientProof     := ClientKey XOR ClientSignature
  local proof = self:xor(client_key, client_signature)
  if not (proof) then
    return nil, "failed to generate the client proof"
  end

  return proof, nil
end


function _M:server_signature(server_key, client_first_msg, server_first_msg, client_final_msg)
  --  ServerSignature := HMAC(ServerKey, AuthMessage)
  local server_signature, err = self:hmac(server_key, self:auth_message(client_first_msg, server_first_msg, client_final_msg))
  if not (server_signature) then
    return nil, tostring(err)
  end

  return ngx.encode_base64(server_signature), nil
end


return _M
