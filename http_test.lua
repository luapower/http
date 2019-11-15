
local http = require'http'
local socket = require'socket'
local ffi = require'ffi'
http.zlib = require'zlib'

local function p(s)
	return (s:gsub('[\1-\31]', function(c) return '\\'..string.byte(c) end))
end

local host = 'www.websiteoptimization.com'
local uri = '/speed/tweak/compress/'

local sock = socket.tcp()
assert(sock:connect(host, 80))
sock:settimeout(0)

local client = http:new()

function client:read(buf, sz)
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
	return n
end

function client:send(buf, sz)
	sz = sz or #buf
	local s = ffi.string(buf, sz)
	print('send', #s, p(s))
	assert(sock:send(s))
end

client:send_request{
	uri = uri,
	host = host,
	headers = {
	},
}

local t = {}
pp(client:read_reply('GET', function(buf, sz)
	local s = ffi.string(buf, sz)
	print('recv', #s, p(s))
	table.insert(t, s)
end))

local sha2 = require'sha2'
local glue = require'glue'
print(glue.tohex(sha2.sha256(table.concat(t))))
