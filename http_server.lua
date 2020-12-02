
if not ... then require'http_server_test'; return end

local http = require'http'
local time = require'time'
local glue = require'glue'

local _ = string.format
local attr = glue.attr
local push = table.insert

local server = {
	type = 'http_server', http = http,
	tls_options = {
		loadfile = glue.readfile,
		protocols = 'tlsv1.2',
		ciphers = [[
			ECDHE-ECDSA-AES256-GCM-SHA384
			ECDHE-RSA-AES256-GCM-SHA384
			ECDHE-ECDSA-CHACHA20-POLY1305
			ECDHE-RSA-CHACHA20-POLY1305
			ECDHE-ECDSA-AES128-GCM-SHA256
			ECDHE-RSA-AES128-GCM-SHA256
			ECDHE-ECDSA-AES256-SHA384
			ECDHE-RSA-AES256-SHA384
			ECDHE-ECDSA-AES128-SHA256
			ECDHE-RSA-AES128-SHA256
		]],
		prefer_ciphers_server = true,
	},
}

server.dbg = glue.noop

function server:utc_time(date)
	return glue.time(date, true)
end

function server:error(fmt, ...)
	print(string.format(fmt, ...))
end

function server:new(t)

	local self = glue.object(self, {}, t)

	if self.debug then
		local dbg = require'http_debug'
		dbg:install_to_server(self)
	end

	local function handler(ctcp, listen_opt, remote_addr, local_addr)

		local http = self.http:new({
			debug = self.debug,
			max_line_size = self.max_line_size,
			tcp = ctcp,
			cosafewrap = self.cosafewrap,
		})

		while not ctcp:closed() do

			local req, err = http:read_request()
			if not req then
				if err ~= 'closed' then
					self:error('read_request(): %s', err)
				end
				break
			end

			--TODO: clean up and publish these info fields...
			req.listen = listen_opt
			req.remote_addr = remote_addr
			req.local_addr = local_addr

			local finished, write_body

			function send_response(opt)
				local res = http:make_response(req, opt, self:utc_time())
				local ok, err = http:send_response(res)
				if not ok then
					self:error('send_response(): %s', err)
				end
				finished = true
			end

			local function respond_with(opt)
				if opt.content == nil then
					write_body = self.cosafewrap(function(yield)
						opt.content = yield
						send_response(opt)
					end)
					write_body()
					return write_body
				else
					send_response(nil, opt)
				end
			end

			self:respond(req, respond_with)

			if not finished and write_body then --eof not signaled.
				write_body()
			end
			assert(finished, 'write_body() not called')

		end
	end

	local stop
	function self:stop()
		stop = true
	end

	self.sockets = {}

	for i,t in ipairs(self.listen) do

		local tcp = assert(self.tcp())
		local host, port = t.host or '*', t.port or (t.tls and 443 or 80)

		local ok, err, errcode = tcp:listen(host, port)
		if not ok then
			self:error('listen("%s", %s): %s [%d]', host, port, err, errcode)
			goto continue
		end
		self:dbg('LISTEN', tcp, '%s:%d', host, port)

		if t.tls then
			local opt = glue.update(self.tls_options, t.tls_options)
			local stcp, err = self.stcp(tcp, opt)
			if not stcp then
				self:error('stcp(): %s', err)
				tcp:close()
				goto continue
			end
			tcp = stcp
		end
		push(self.sockets, tcp)

		function accept_connection()
			local ctcp, r2, r3 = tcp:accept()
			if not ctcp then
				local err, errcode = r2, r3
				self:error('accept(): %s [d]', err, errcode)
				return
			end
			self.newthread(function()
				local remote_addr, local_addr = r2, r3
				local ok, err = xpcall(handler, debug.traceback, ctcp, t, remote_addr, local_addr)
				if not ok then
					self:error('handler(): %s', err)
				end
				ctcp:close()
			end)
		end

		self.newthread(function()
			while not stop do
				accept_connection()
			end
		end)

		::continue::
	end

	return self
end

return server
