local uv  = require "lluv"
local ut  = require "lluv.utils"
local ssl = require "openssl"

local function load(path)
  local f, err = io.open(path,'rb')
  if not f then return nil, err end
  local c = f:read('*a')
  f:close()
  return c
end

local function load_key(key, path, ...)
  local data, err = load(path)
  if not data then return nil, err end
  return key.read(data, ...)
end

local function iclone(t)
  local o = {}
  for i = 1, #t do o[i] = t[i] end
  return o
end

local function clone(t)
  local o = {}
  for k,v in pairs(t) do o[k] = v end
  return o
end

local unpack = table.unpack or unpack

-- opt is LuaSEC compatiable table
local function make_ctx(opt)
  local proto = opt.protocol or 'SSLv3' 
  proto = proto:sub(1,3):upper() .. proto:sub(4)

  local ctx, err = ssl.ssl.ctx_new(proto, opt.ciphers)
  if not ctx then return nil, err end

  local password = opt.password
  if password and type(password) == 'function' then password = password() end

  local xkey, xcert, err
  if opt.key then
    if password then
      xkey, err = load_key(ssl.pkey, opt.key, true, 'pem', password)
    else
      xkey, err = load_key(ssl.pkey, opt.key, true, 'pem')
    end
    if not xkey then return nil, err end

    if opt.certificate then
      xcert, err = load_key(ssl.x509, opt.certificate)
    end
    if not xcert then
      xkey:close()
      return nil, err
    end

    ctx:use(xkey, xcert)
  end

  if opt.cafile or opt.capath then
    ctx:verify_locations(opt.cafile, opt.capath)
  end

  if opt.verify then
    ctx:set_verify(iclone(opt.verify))
  end

  if opt.options then
    for i = 1, #opt.options do
      local name = opt.options[i]
      local code = assert(ssl.ssl[name], "unkown option:" .. tostring(opt))
      ctx:options(code)
    end
  end

  if opt.verifyext then
    local t = clone(opt.verifyext)
    for k, v in pairs(t) do
      t[k] = string.gsub(v, 'lsec_', '')
    end
    ctx:set_cert_verify(t)
  end

  if opt.dhparam then
    ctx:set_tmp('dh',opt.dhparam)
  end

  if opt.curve then
    ctx:set_tmp('ecdh',opt.curve)
  end

  return ctx
end

local SSLSocket = ut.class() do

local BUFFER_SIZE = 8192

function SSLSocket:__init(ctx, mode, socket)
  self._ctx  = assert(ctx)
  self._skt  = socket or uv.tcp()
  self._mode = (mode == 'server')
  self._inp  = ssl.bio.mem(BUFFER_SIZE)
  self._out  = ssl.bio.mem(BUFFER_SIZE)
  self._ssl  = self._ctx:_ssl(self._inp, self._out, self._mode)
  return self
end

function SSLSocket:handshake(cb)
  self._skt:start_read(function(cli, err, chunk)
    if err then return cb(self, err) end
    self._inp:write(chunk)
    self:_handshake(cb)
  end)
  self:_handshake(cb)
end

function SSLSocket:_handshake(cb)
  local ret, err, e = self._ssl:handshake()
  if ret == nil then
    return uv.defer(cb, self, err)
  end

  local i = self._out:pending()
  if i > 0 then
    local msg, err = self._out:read()
    self._skt:write(msg, function() self:_handshake(cb) end)
    return
  end
  if ret == false then return end
  self._skt:stop_read()
  uv.defer(cb, self)
end

function SSLSocket:close(cb)
  if not self._skt then return end
  self._inp:close()
  self._out:close()
  if cb then self._skt:close(cb) else self._skt:close() end
  self._inp, self._out, self._skt = nil
end

function SSLSocket:start_read(cb)
  self._skt:start_read(function(cli, err, data)
    if err then return cb(self, err) end

    local ret, err = self._inp:write(data)
    if ret == nil then
      cli:stop_read()
      return cb(self, err)
    end

    while true do
      ret, err = self._ssl:read()
      if not ret or #ret == 0 then break end
      cb(self, nil, ret)
    end
  end)

  while true do
    ret, err = self._ssl:read()
    if not ret or #ret == 0 then break end
    uv.defer(cb, self, nil, ret)
  end

  return self
end

function SSLSocket:stop_read()
  local ok, err = self._skt:stop_read()
  if not ok then return nil, err end
  return self
end

function SSLSocket:write(data, cb)
  local ret, err = self._ssl:write(data)
  if ret == nil then
    if cb then
      return uv.defer(cb, self, err)
    else
      return nil, err
    end
  end

  local msg = {}
  while true do
    local chunk, err = self._out:read()
    if not chunk or #chunk == 0 then break end
    msg[#msg + 1] = chunk
  end

  if #msg > 0 then
    if cb then return self._skt:write(msg, cb)
    else return self._skt:write(msg) end
  end

  if cb then uv.defer(cb, self) end

  return self
end

function SSLSocket:connect(host, port, cb)
  self._skt:connect(host, port, function(cli, err)
    if err then return cb(self, err) end
    self:handshake(cb)
  end)
end

function SSLSocket:bind(host, port, cb)
  if cb then
    self._skt:bind(host, port, function(cli, err)
      if err then return cb(self, err) end
      cb(self)
    end)
  end
  local ok, err = self._skt:bind(host, port)
  if not ok then return nil, err end
  return self
end

function SSLSocket:accept()
  local cli, err = self._skt:accept()
  if not cli then return nil, err end
  return self._ctx:server(cli)
end

function SSLSocket:listen(cb)
  self._skt:listen(function(cli, ...) cb(self, ...) end)
  return self
end

function SSLSocket:loop()
  return self._skt:loop()
end

function SSLSocket:closed()
  return not not self._skt
end

function SSLSocket:ref()
  return self._skt:ref()
end

function SSLSocket:unref()
  return self._skt:unref()
end

function SSLSocket:has_ref()
  return self._skt:has_ref()
end

function SSLSocket:active()
  return self._skt:active()
end

function SSLSocket:closing()
  return self._skt:closing()
end

function SSLSocket:send_buffer_size()
  return self._skt:send_buffer_size()
end

function SSLSocket:recv_buffer_size()
  return self._skt:recv_buffer_size()
end

function SSLSocket:lock()
  self._skt:lock()
  return self
end

function SSLSocket:unlock()
  self._skt:unlock()
  return self
end

function SSLSocket:locked()
  return self._skt:locked()
end

function SSLSocket:__tostring()
  return "Lua-UV ssl (" .. tostring(self._skt) .. ")"
end

function SSLSocket:shutdown(cb)
  if not self._shutdowned then
    self._ssl:shutdown()
    if cb then self._skt:shutdown(cb)
    else self._skt:shutdown() end
    self._shutdowned = true
  end
end

function SSLSocket:getsockname()
  return self._skt:getsockname(cb)
end

function SSLSocket:getpeername()
  return self._skt:getpeername(cb)
end

end

local SSLContext = ut.class() do

function SSLContext:__init(cfg)
  local ctx, err = make_ctx(cfg)
  if not ctx then return nil, err end
  self._ctx  = ctx
  self._mode = cfg.mode
  return self
end

function SSLContext:_ssl(...)
  return self._ctx:ssl(...)
end

function SSLContext:client(socket)
  return SSLSocket.new(self, "client", socket)
end

function SSLContext:server(socket)
  return SSLSocket.new(self, "server", socket)
end

end

return {
  context = function(...) return SSLContext.new(...) end
}