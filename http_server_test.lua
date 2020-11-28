
local ffi = require'ffi'
ffi.tls_libname = 'tls_libressl'

--USE_LUASOCKET = true

local s2     = require'socket2'
local s2tls = require'socket2_libtls'
local server = require'http_server'
local zlib   = require'zlib'

server.tcp       = s2.tcp
server.newthread = s2.newthread
server.stcp      = s2tls.server_stcp
server.http.zlib = zlib

local server = server:new{
	loop = loop,
	listen = {
		{
			host = 'localhost',
			port = 443,
			tls = true,
			tls_options = {
				cert_file = 'localhost.crt',
				key_file  = 'localhost.key',
			},
		},
	},
	debug = {protocol = true, stream = true},
}

s2.start()
