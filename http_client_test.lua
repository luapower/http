
local ffi = require'ffi'
ffi.tls_libname = 'tls_libressl'

local client = require'http_client'
local s2     = require'socket2'
local s2tls  = require'socket2_libtls'
local zlib   = require'zlib'
local time   = require'time'

client.tcp           = s2.tcp
client.stcp          = s2tls.client_stcp
client.stcp_config   = s2tls.config
client.cosafewrap    = s2.cosafewrap
client.suspend       = s2.suspend
client.resume        = s2.resume
client.currentthread = s2.thread
client.http.zlib     = zlib

local function search_page_url(pn)
	return 'https://luapower.com/'
end

function kbytes(n)
	if type(n) == 'string' then n = #n end
	return n and string.format('%.1fkB', n/1024)
end

function mbytes(n)
	if type(n) == 'string' then n = #n end
	return n and string.format('%.1fmB', n/(1024*1024))
end

local client = client:new{
	max_conn = 5,
	max_pipelined_requests = 10,
	debug = {protocol = true},
}
local n = 0
for i=1,1 do
	s2.newthread(function()
		print('sleep .5')
		s2.sleep(.5)
		local res, req, err_class = client:request{
			--host = 'www.websiteoptimization.com', uri = '/speed/tweak/compress/',
			host = 'luapower.com', uri = '/',
			--https = true,
			--host = 'mokingburd.de',
			--host = 'www.google.com', https = true,
			receive_content = 'string',
			debug = {protocol = true, stream = false},
			--max_line_size = 1024,
			--close = true,
			--connect_timeout = 0.5,
			--request_timeout = 0.5,
			--reply_timeout = 0.3,
		}
		if res then
			n = n + (res and res.content and #res.content or 0)
		else
			print('sleep .5')
			s2.sleep(.5)
			print('ERROR:', req)
		end
	end)
end
local t0 = time.clock()
s2.start()
t1 = time.clock()
print(mbytes(n / (t1 - t0))..'/s')

