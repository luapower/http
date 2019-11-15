
local http = require'http'
local socket = require'socket'
local ffi = require'ffi'

local function p(s)
	return (s:gsub('[\1-\31]', function(c) return '\\'..string.byte(c) end))
end

local sock = socket.tcp()
assert(sock:connect('mokingburd.de', 80))

local client = http:new()

function client:read(n)
	local s, err, partial = sock:receive(n)
	--print(s, err, partial)
	--print('recv', #s, (s:gsub('[\1-\31]', '.')))
	return ffi.cast('const char*', s), #s
end

function client:send(s)
	print('send', #s, p(s))
	assert(sock:send(s))
end

client:send_request{
	uri = '/',
	host = 'mokingburd.de',
	headers = {
	},
}

pp(client:read_reply('GET', function(s)
	print('recv', #s, p(s))
end))
