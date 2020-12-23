
local ffi = require'ffi'
ffi.tls_libname = 'tls_libressl'
local server  = require'http_server'
local libtls = require'libtls'
libtls.debug = print

--local webb_respond = require'http_server_webb'

local server = server:new{
	libs = 'sock sock_libtls zlib',
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
		tracebacks = true,
	},
	respond = function(self, req, respond, raise)
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
		--raise{status = 404, content = 'Dude, no page here'}
	end,
	--respond = webb_respond,
}

server.start()
