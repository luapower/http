
--USE_LUASOCKET = true

local server = require'http_server'
server.http.zlib = require'zlib'
local loop = require(USE_LUASOCKET and 'http_socket_luasec' or 'http_socket2_libtls')

local server = server:new{
	lopp = loop,
}

server:start()
