--
--[[-- usage
local umc = mc.Connection("127.0.0.1:11211")

umc:open(function(err)
  if err then return print(err) end

  for i = 1, 10 do
    umc:set("test_key", "test_value " .. i, 10, function(err, result)
      print("Set #" .. i, err, result)
    end)

    umc:get("test_key", function(err, value)
      print("Get #" .. i, err, value)
    end)
  end

  umc:get("test_key", function(err, value) umc:close() end)
end)

uv.run(debug.traceback)
]]

local uv = require "lluv"
local va = require "vararg"
local ut = require "utils"

local EOL = "\r\n"

local REQ_STORE      = 0 -- single line response
local REQ_RETR       = 1 -- line + data response
local REQ_RETR_MULTI = 2 -- line + data response (many keys)

local SERVER_ERRORS = {
  ERROR        = true;
  CLIENT_ERROR = true;
  SERVER_ERROR = true
}

local STORE_RESP = {
  STORED        = true;
  DELETED       = true;
  NOT_STORED    = true;
  EXISTS        = true;
  NOT_EXISTS    = true;
}

local ocall       = ut.ocall
local usplit      = ut.usplit
local split_first = ut.split_first

local function cb_args(...)
  local n = select("#", ...)
  local cb = va.range(n, n, ...)
  if type(cb) == 'function' then
    return cb, va.remove(n, ...)
  end
  return nil, ...
end

-------------------------------------------------------------------
local Error = {} do
Error.__index = Error

function Error:new(err)
  local o = setmetatable({}, self)
  o._err = err
  return o
end

function Error:__tostring()
  return self._err
end

end
-------------------------------------------------------------------

local function make_store(cmd, key, data, exptime, flags, noreply, cas)
  assert(cmd)
  assert(key)
  assert(data)

  if type(data) == "number" then data = tostring(data) end

  exptime = exptime or 0
  noreply = noreply or false
  flags   = flags   or 0

  local buf = { cmd, key, flags or 0, exptime or 0, #data, cas}

  if noreply then buf[#buf + 1] = "noreply" end

  return table.concat(buf, " ") .. EOL ..  data .. EOL
end

local function make_retr(cmd, key)
  assert(cmd)
  assert(key)
  return cmd .. " " .. key .. EOL
end

local function make_change(cmd, key, noreply)
  assert(cmd)
  assert(key)
  return cmd .. " " .. key .. (noreply and " noreply" or "") .. EOL
end

local function make_inc(cmd, key, value, noreply)
  assert(cmd)
  assert(key)
  assert(value)
  return cmd .. " " .. key .. " " .. value .. (noreply and " noreply" or "") .. EOL
end

-------------------------------------------------------------------
local Connection = {} do
Connection.__index = Connection

function Connection:new(server)
  local o = setmetatable({}, self)

  local host, port = usplit(server, ":")
  o._host  = host or "127.0.0.1"
  o._port  = port or "11211"
  o._buff  = ut.Buffer(EOL) -- pending data
  o._queue = ut.Queue()     -- pending requests

  return o
end

function Connection:connected()
  return not not self._cnn
end

function Connection:open(cb)
  if self:connected() then return ocall(cb, self) end

  return uv.tcp():connect(self._host, self._port, function(cli, err)
    if err then
      cli:close()
      return ocall(cb, self, err)
    end

    cli.data = self
    self._cnn = cli
    self._buff.reset()
    self._queue.reset()

    cli:start_read(function(cli, err, data)
      if err then
        self:close()
        return ocall(self.on_error, self, err)
      end
      return self:_read(data)
    end)

    return ocall(cb, self)
  end)
end

function Connection:close()
  if not self:connected() then return end
  self._cnn:close()
  self._cnn = nil
end

function Connection:on_error(err) end

local WAIT = {}

function Connection:_read(data)
  local req = self._queue.peek()
  if not req then -- unexpected reply
    self:close()
    return ocall(self.on_error, self, Error:new("Protocol error"))
  end

  self._buff.append(data)

  while req do
    if req.type == REQ_STORE then
      local ret = self:_on_store(req)
      if ret == WAIT then return end
    elseif req.type == REQ_RETR then
      local ret = self:_on_retr(req)
      if ret == WAIT then return end
    else
      assert(false, "unknown request type :" .. tostring(req.type))
    end

    req = self._queue.peek()
  end
end

function Connection:_on_store(req)
  local line = self._buff.next_line()
  if not line then return WAIT end
  assert(self._queue.pop() == req)

  if STORE_RESP[line] then
    return ocall(req.cb, self, nil, line)
  end

  local res, value = split_first(line, " ", true)
  if SERVER_ERRORS[res] then
    return ocall(req.cb, self, Error:new(line))
  end

  -- for increment/decrement line is just data
  return ocall(req.cb, self, nil, line)
end

function Connection:_on_retr(req)
  if not req.len then -- we wait next value
    local line = self._buff.next_line()
    if not line then return WAIT end

    if line == "END" then -- no more data
      assert(self._queue.pop() == req)

      if req.multi then   return ocall(req.cb, self, nil, req.res) end
      if not req.res then return ocall(req.cb, self, nil, nil) end
      return ocall(req.cb, self, nil, req.res[1].data, req.res[1].flags, req.res[1].cas)
    end

    local res, key, flags, len, cas = usplit(line, " ", true)
    if res == "VALUE" then
      req.key   = key
      req.len   = tonumber(len) + #EOL
      req.flags = tonumber(flags) or 0
      req.cas   = cas ~= "" and cas or nil
    elseif SERVER_ERRORS[res] then
      assert(self._queue.pop() == req)
      return ocall(req.cb, self, Error:new(line))
    else
      self:close()
      return ocall(self.on_error, self, Error:new("Protocol error"))
    end
  end

  assert(req.len)

  local data = self._buff.next_n(nil, req.len)
  if not data then return WAIT end
  
  if not req.res then req.res = {} end
  req.res[#req.res + 1] = { data = string.sub(data, 1, -3); flags = req.flags; cas = req.cas; key = req.key; }
  req.len = nil
end

function Connection:_send(data, type, cb)
  self._cnn:write(data)
  local req
  if type == REQ_RETR_MULTI then
    req = {type = REQ_RETR, cb=cb, multi = true}
  else
    req = {type = type, cb=cb}
  end
  self._queue.push(req)
  return self
end

-- (key, data, [exptime[, flags[, noreply]]])
function Connection:_set(cmd, ...)
  local cb, key, data, exptime, flags, noreply = cb_args(...)
  return self:_send(
    make_store(cmd, key, data, exptime, flags, noreply),
    REQ_STORE, cb
  )
end

function Connection:set(...)     return self:_set("set", ...)     end

function Connection:add(...)     return self:_set("add", ...)     end

function Connection:replace(...) return self:_set("replace", ...) end

function Connection:append(...)  return self:_set("append", ...)  end

function Connection:prepend(...) return self:_set("prepend", ...) end

-- (key, data, [exptime[, flags[, noreply]]])
function Connection:cas(...)
  local cb, key, data, cas, exptime, flags, noreply = cb_args(...)
  return self:_send(
    make_store("cas", key, data, exptime, flags, noreply, cas),
    REQ_STORE, cb
  )
end

function Connection:get(key, cb)
  return self:_send(
    make_retr("get", key),
    REQ_RETR, cb
  )
end

function Connection:gets(key, cb)
  return self:_send(
    make_retr("gets", key),
    REQ_RETR, cb
  )
end

-- (key[, noreply])
function Connection:delete(...)
  local cb, key, noreply = cb_args(...)
  return self:_send(
    make_change("delete", key, noreply),
    REQ_STORE, cb
  )
end

-- (key[, value[, noreply]])
function Connection:increment(...)
  local cb, key, value, noreply = cb_args(...)
  value = value or 1
  return self:_send(
    make_inc("incr", key, value, noreply),
    REQ_STORE, cb
  )
end

-- (key[, value[, noreply]])
function Connection:decrement(...)
  local cb, key, value, noreply = cb_args(...)
  value = value or 1
  return self:_send(
    make_inc("decr", key, value, noreply),
    REQ_STORE, cb
  )
end

-- (key, value[, noreply])
function Connection:touch(...)
  local cb, key, value, noreply = cb_args(...)
  assert(value)
  return self:_send(
    make_inc("touch", key, value, noreply),
    REQ_STORE, cb
  )
end

end
-------------------------------------------------------------------

local function self_test(server, key)
  key = key or "test_key"

  Connection:new(server):open(function(self, err)
    assert(not err, tostring(err))

    function self:on_error(err)
      assert(false, tostring(err))
    end

    self:delete(key)

    uv.run("once")

    self:delete(key, function(self, err, ret)
      assert(not err, tostring(err))
      assert(ret == "NOT_FOUND", tostring(ret))
    end)

    uv.run("once")

    self:increment(key, 5, function(self, err, ret)
      assert(not err, tostring(err))
      assert(ret == "NOT_FOUND", tostring(ret))
    end)

    uv.run("once")

    self:get(key, function(self, err, ret)
      assert(not err, tostring(err))
      assert(ret == nil, tostring(ret))
    end)

    uv.run("once")

    self:replace(key, "hello", function(self, err, ret)
      assert(not err, tostring(err))
      assert(ret == "NOT_STORED", tostring(ret))
    end)

    uv.run("once")

    self:append(key, "hello", function(self, err, ret)
      assert(not err, tostring(err))
      assert(ret == "NOT_STORED", tostring(ret))
    end)

    uv.run("once")

    self:prepend(key, "hello", function(self, err, ret)
      assert(not err, tostring(err))
      assert(ret == "NOT_STORED", tostring(ret))
    end)

    uv.run("once")

    self:set(key, "72", 0, 12, function(self, err, ret)
      assert(not err, tostring(err))
      assert(ret == "STORED", tostring(ret))
    end)

    uv.run("once")

    self:get(key, function(self, err, ret, flags, cas)
      assert(not err, tostring(err))
      assert(ret   == "72", tostring(ret))
      assert(flags == 12,   tostring(flags))
      assert(cas   == nil,  tostring(cas))
    end)

    uv.run("once")

    self:gets(key, function(self, err, ret, flags, cas)
      assert(not err, tostring(err))
      assert(ret   == "72", tostring(ret))
      assert(flags == 12,   tostring(flags))
      assert(type(cas) == "string",  type(cas) .. " - " .. tostring(cas))
    end)

    uv.run("once")

    self:add(key, "hello", function(self, err, ret)
      assert(not err, tostring(err))
      assert(ret == "NOT_STORED", tostring(ret))
    end)

    uv.run("once")

    self:increment(key, 5, function(self, err, ret)
      assert(not err, tostring(err))
      assert(ret == "77", tostring(ret))
    end)

    uv.run("once")

    self:decrement(key, 2, function(self, err, ret)
      assert(not err, tostring(err))
      assert(ret == "75", tostring(ret))
    end)

    uv.run("once")

    self:prepend(key, "1", function(self, err, ret)
      assert(not err, tostring(err))
      assert(ret == "STORED", tostring(ret))
    end)

    uv.run("once")

    self:gets(key, function(self, err, ret, flags, cas)
      assert(not err, tostring(err))
      assert(ret   == "175", tostring(ret))
      assert(flags == 12,   tostring(flags))
      assert(type(cas) == "string",  type(cas) .. " - " .. tostring(cas))

      self:cas(key, "178", cas, function(self, err, ret)
        assert(not err, tostring(err))
        assert(ret == "STORED", tostring(ret))
      end)


      self:cas(key, "177", cas, function(self, err, ret)
        assert(not err, tostring(err))
        assert(ret == "EXISTS", tostring(ret))
      end)

      self:get(key, function() self:close() end)
    end)
  end)

  uv.run()

end

return {
  Connection = function(...) return Connection:new(...) end
}