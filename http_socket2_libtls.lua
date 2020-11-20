
--(secure) sockets for http client and server protocols based on socket2 and libtls.
--Written by Cosmin Apreutesei. Public Domain.

local socket = require'socket2'

local M = {}

M.tcp       = socket.tcp
M.suspend   = socket.suspend
M.resume    = socket.resume
M.thread    = socket.thread
M.newthread = socket.newthread
M.start     = socket.start

--http<->socket2 binding -----------------------------------------------------

function M.http_bind_socket(http, sock)

	function http:getsocket() return sock end
	function http:setsocket(newsock) sock = newsock end

	function http:read(buf, sz)
		return sock:recv(buf, sz, self.read_expires)
	end

	function http:send(buf, sz)
		return sock:send(buf, sz, self.send_expires)
	end

	function http:close()
		sock:close()
		self.closed = true
	end

end

--http<->libtls binding ------------------------------------------------------

local function load_file(self, kf, ks)
	if self[ks] then return self[ks] end
	local t = rawget(self, kf) and self or self.__index --load in instance or in class.
	t[ks] = assert(glue.readfile(t[kf]))
end

function M.http_bind_tls(self, http, tcp, vhost, mode)

	local stcp = require'socket2_libtls'

	assert(mode == 'client' or mode == 'server')
	if mode == 'client' then
		load_file(self, 'tls_ca_file', 'tls_ca')
	end
	local stcp, err = stcp.new(tcp, {
		mode = mode,
		ca = self.tls_ca,
		servername = vhost,
		insecure_noverifycert = self.tls_insecure_noverifycert,
	})
	if not stcp then
		http:close()
		return nil, err
	end
	http:setsocket(stcp)
	return true
end


return M
