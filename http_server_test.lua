
local ffi = require'ffi'
ffi.tls_libname = 'tls_libressl'

--USE_LUASOCKET = true

local sock    = require'sock'
local socktls = require'sock_libtls'
local server  = require'http_server'
local zlib    = require'zlib'

server.tcp        = sock.tcp
server.newthread  = sock.newthread
server.cosafewrap = sock.cosafewrap
server.stcp       = socktls.server_stcp
server.http.zlib  = zlib

local libtls = require'libtls'
libtls.debug = print

--local webb_respond = require'http_server_webb'

local server = server:new{
	listen = {
		{
			host = 'localhost',
			port = 443,
			tls = true,
			tls_options = {
				keypairs = {
					{
					cert_file = 'localhost.crt',
					key_file  = 'localhost.key',
					}
				},
			},
		},
	},
	debug = {
		protocol = true,
		stream = true,
	},
	respond = function(self, req, respond)
		local read_body = req:read_body'reader'
		while true do
			local buf, sz = read_body()
			if buf == nil and sz == 'eof' then break end
			local s = ffi.string(buf, sz)
			print(s)
		end
		local write_body = respond{
			--compress = false,
		}
		write_body(('hello '):rep(1000))
	end
}

sock.start()
