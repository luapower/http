
local ffi = require'ffi'
local time = require'time'
local glue = require'glue'
local attr = glue.attr
local _ = string.format

local dbg = {getaddr = {}, is = {}, prefixes = {}}
function dbg.is.thread(t)
	return type(t) == 'thread'
end
function dbg.is.sock_tcp_socket(t) return type(t) == 'table' and t.istcpsocket and not t.istlssocket end
function dbg.is.sock_libtls_tcp_socket(t) return type(t) == 'table' and t.istcpsocket and t.istlssocket end
function dbg.is.http(t) return type(t) == 'table' and t.type == 'http_connection' end
function dbg.is.target(t) return type(t) == 'table' and t.type == 'http_target' end
function dbg.is.request(t) return type(t) == 'table' and t.type == 'http_request' end
function dbg.is.response(t) return type(t) == 'table' and t.type == 'http_response' end
function dbg:type(t)
	for k,is in pairs(self.is) do
		if is(t) then
			return k
		end
	end
end
local function getaddr_table(t)
	return (tostring(t):match'0x(%x+)')
end
dbg.getaddr.target = tostring
function dbg.getaddr.luasocket_socket(sock)
	return tostring(sock):match'tcp{%w+}: (%x+)'
end
function dbg:addr(t)
	local type = self:type(t)
	local getaddr = self.getaddr[type] or getaddr_table
	return assert(getaddr(t))
end
dbg.prefixes = {
	thread = 'T',
	sock_tcp_socket = 'S',
	sock_libtls_tcp_socket = 'X',
	http = 'H',
	target = '@',
	request = 'R',
	response = '<',
}
function dbg:id(t)
	local type = self:type(t)
	if not type then return end
	local ids = attr(self, type)
	local addr = self:addr(t)
	local id = ids[addr]
	if not id then
		id = (ids.last_id or 0) + 1
		ids.last_id = id
		ids[addr] = id
		local anchors = attr(self, 'anchors')
		table.insert(anchors, t) --so the address doesn't get recycled
	end
	return dbg.prefixes[type]..id
end

function dbg:clock_table(tag)
	return attr(attr(self, 'clocks'), assert(tag))
end

function dbg:start_clock(tag)
	local clock = self:clock_table(tag)
	clock.t0 = time.clock()
	clock.t1 = clock.t0
end

function dbg:reset_clock(tag)
	local clock = self:clock_table(tag)
	clock.t0 = nil
	clock.t1 = nil
end

function dbg:clock(tag)
	local clock = self:clock_table(tag)
	if not clock.t0 then self:start_clock(tag) end
	local t0, t1, t2 = clock.t0, clock.t1, time.clock()
	clock.t1 = t2
	return t2 - t0, t2 - t1
end

function dbg:install_to_http(http)

	local dbg = self

	local function D(tag, cmd, s)
		local S = dbg:id(http.tcp) or '-'
		local T = dbg:id(http.currentthread()) or 'TM'
		local t1, dt = dbg:clock(tag)
		print(_('%6.2fs %5.2fs %-4s %-4s %s %s', t1, dt, T, S, cmd, s))
	end

	if http.debug.protocol then

		function http:dbg(cmd, ...)
			local ok, s = pcall(_, ...)
			local ok, err = pcall(D, 'http', cmd, s)
			if not ok then print(err) end
		end

		glue.after(http, 'close', function(self)
			dbg:reset_clock'http'
		end)

	end

	if http.debug.stream then

		local P = function(cmd, s)
			local len = s and _('%5d', #s) or '     '
			local s = s and s
				:gsub('\r\n', '\n'..(' '):rep(34))
				:gsub('\n%s*$', '')
				:gsub('[%z\1-\9\11-\31\128-\255]', '.') or ''
			D('stream', cmd, _('%s %s', len, s))
		end

		glue.override(http.tcp, 'recv', function(inherited, self, buf, ...)
			local sz, err, errcode = inherited(self, buf, ...)
			if not sz then return nil, err, errcode end
			P(' <', ffi.string(buf, sz))
			return sz
		end)

		glue.override(http.tcp, 'send', function(inherited, self, buf, ...)
			local sz, err, errcode = inherited(self, buf, ...)
			if not sz then return nil, err, errcode end
			P(' >', ffi.string(buf, sz))
			return sz
		end)

		glue.override(http.tcp, 'close', function(inherited, self, ...)
			local ok, err, errcode = inherited(self, ...)
			if not ok then return nil, err, errcode  end
			P('CC')
			dbg:reset_clock'stream'
			return ok
		end)

	end

end

function dbg:format(fmt, ...)
	if not fmt then
		return ''
	end
	local args = glue.pack(...)
	for i=1,args.n do
		local arg = args[i]
		if type(arg) == 'boolean' then
			args[i] = arg and 'yes' or 'no'
		else
			local id = dbg:id(arg)
			if id then args[i] = id end
		end
	end
	return _(fmt, glue.unpack(args))
end

function dbg:install_to_client(client)
	if not client.debug then return end

	local dbg = self
	function client:dbg(target, event, fmt, ...)
		local t1, dt = dbg:clock'request'
		print(_('%6.2fs %5.2fs %-4s %-4s %-20s %s',
			t1, dt,
			dbg:id(self.currentthread()) or 'TM',
			dbg:id(target),
			event,
			dbg:format(fmt, ...)))
	end

	local function pass(rc, ...)
		print(('<'):rep(1+rc)..('-'):rep(78-rc))
		return ...
	end
	glue.override(client, 'request', function(inherited, self, t, ...)
		dbg:start_clock'request'
		local rc = t.redirect_count or 0
		print(('>'):rep(1+rc)..('-'):rep(78-rc))
		return pass(rc, inherited(self, t, ...))
	end)

end

function dbg:install_to_server(server)
	if not server.debug then return end

	local dbg = self
	function server:dbg(event, tcp, fmt, ...)
		local t1, dt = dbg:clock'request'
		print(_('%6.2fs %5.2fs %-4s %-4s %-20s %s',
			t1, dt,
			dbg:id(self.currentthread()) or 'TM',
			dbg:id(tcp),
			event,
			dbg:format(fmt, ...)))
	end

	glue.override(server, 'read_request', function(inherited, self, ...)
		return inherited(self, ...)
	end)

end

if not ... then

	local socket = require'socket'
	local ssl = require'ssl'

	local s1 = socket.tcp()
	local s2 = socket.tcp()
	local S1 = ssl.wrap(s1, {protocol = 'any', mode = 'client'})
	local S2 = ssl.wrap(s2, {protocol = 'any', mode = 'client'})
	local t1 = coroutine.create(function() end)
	local t2 = coroutine.create(function() end)

	local _ = string.format
	print(_('%f %f', dbg:clock'test'), dbg:id(s1), dbg:id(s2), dbg:id(s1))
	print(_('%f %f', dbg:clock'test'), dbg:id(S1), dbg:id(S2), dbg:id(S1))
	print(_('%f %f', dbg:clock'test'), dbg:id(t1), dbg:id(t2), dbg:id(t1))

end

return dbg
