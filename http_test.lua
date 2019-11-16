
local http = require'http'
local socket = require'socket'
local ffi = require'ffi'
http.zlib = require'zlib'

local function P(s)
	return #s, (s:gsub('[\1-\31]', function(c) return '\\'..string.byte(c) end))
end

local function wrap_sock(sock, http)

	function http:read(buf, sz)
		local s, err, p
		while true do
			s, err, p = sock:receive(sz)
			if not s and not p then
				return nil, err
			end
			if not (err == 'timeout' and #p == 0) then
				break
			end
		end
		local n = (s and #s or 0) + (p and #p or 0)
		assert(n <= sz)
		if s then
			ffi.copy(buf, s, #s)
		elseif p then
			ffi.copy(buf, p, #p)
		end
		local s = ffi.string(buf, sz)
		print('recv', P(s))
		return n
	end

	function http:send(buf, sz)
		sz = sz or #buf
		local s = ffi.string(buf, sz)
		print('send', P(s))
		assert(sock:send(s))
	end

	local t = {}
	return function(buf, sz)
		local s = ffi.string(buf, sz)
		table.insert(t, s)
	end, function()
		return table.concat(t)
	end
end

local function test_client()

	local host = 'www.websiteoptimization.com'
	local uri = '/speed/tweak/compress/'

	local sock = socket.tcp()
	assert(sock:connect(host, 80))
	sock:settimeout(0)

	local client = http:new()

	local write_body, flush_body = wrap_sock(sock, client)

	client:send_request{
		uri = uri,
		host = host,
		headers = {
		},
	}

	pp(client:read_reply('GET', write_body))
	print('body', P(flush_body()))

	local sha2 = require'sha2'
	local glue = require'glue'
	print('sha2', glue.tohex(sha2.sha256(flush_body())))

end

--server ---------------------------------------------------------------------

local function test_server()
	local ssock = socket.tcp()
	local server = http:new()
	assert(ssock:bind('127.0.0.1', 80))
	assert(ssock:listen())
	print'accepting'
	local csock = assert(ssock:accept())
	local write_body, flush_body = wrap_sock(csock, server)
	ssock:settimeout(0)
	local method, uri, headers = server:read_request({}, write_body)
	print('cbody', flush_body())
	server:send_reply{
		status = 200,
		headers = {
			['content-length'] = 10,
			content = '1234567890',
		},
	}
end

--test_client()
test_server()
