
if not ... then require'luapower_server'; return end

local http = require'http'
local time = require'time'
local glue = require'glue'
local errors = require'errors'
local coro = require'coro'

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
	dbg = glue.noop,
}

function server:bind_libs(libs)
	for lib in libs:gmatch'[^%s]+' do
		if lib == 'sock' then
			local sock = require'sock'
			self.tcp           = sock.tcp
			self.cosafewrap    = sock.cosafewrap
			self.newthread     = sock.newthread
			self.resume        = sock.resume
			self.thread        = sock.thread
			self.start         = sock.start
			self.sleep         = sock.sleep
			self.currentthread = sock.currentthread
		elseif lib == 'sock_libtls' then
			local socktls = require'sock_libtls'
			self.stcp          = socktls.server_stcp
		elseif lib == 'zlib' then
			self.http.zlib = require'zlib'
		else
			assert(false)
		end
	end
end

function server:time(ts)
	return glue.time(ts)
end

function server:error(fmt, ...)
	print(string.format(fmt, ...))
end

function server:new(t)

	local self = glue.object(self, {}, t)

	if self.libs then
		self:bind_libs(self.libs)
	end

	if self.debug then
		local dbg = require'http_debug'
		dbg:install_to_server(self)
	end

	local function handler(ctcp, listen_opt)

		local http = self.http:new({
			debug = self.debug,
			max_line_size = self.max_line_size,
			tcp = ctcp,
			cosafewrap = self.cosafewrap,
			currentthread = self.currentthread,
			listen_options = listen_opt,
		})

		while not ctcp:closed() do

			local req, err = http:read_request()
			if not req then
				if not (errors.is(err, 'socket') and err.message == 'closed') then
					self:error('read_request(): %s', err)
				end
				break
			end

			local finished, write_body, sending_response

			local function send_response(opt)
				sending_response = true
				local res = http:build_response(req, opt, self:time())
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
					send_response(opt)
				end
			end

			local function raise_with(err)
				errors.raise('http_response', err)
			end

			local function debug_with(s, ...)
				self:dbg(s, ctcp, ...)
			end

			local ok, err = errors.catch(nil, self.respond, req, respond_with, raise_with, debug_with)

			if not ok then
				if errors.is(err, 'http_response') then
					assert(not sending_response, 'response already sent')
					respond_with(err)
				elseif not sending_response then
					respond_with{
						status = 500,
						content = err,
					}
					self:error('respond(): %s', err)
				else
					error(('respond(): %s'):format(err))
				end
			end

			if not finished then --eof not signaled.
				if write_body then
					write_body()
				else
					send_response({content = ''})
				end
			end

			--the request must be entirely read before we can read the next request.
			if req.body_was_read == nil then
				req:read_body()
			end
			assert(req.body_was_read, 'request body was not read')

		end
	end

	local stop
	function self:stop()
		stop = true
	end

	self.sockets = {}

	for i,t in ipairs(self.listen) do
		if t.listen == false then
			goto continue
		end

		local tcp = assert(self.tcp())
		local host, port = t.host or '*', t.port or (t.tls and 443 or 80)

		local ok, err, errcode = tcp:listen(host, port)
		if not ok then
			self:error('listen("%s", %s): %s [%s]', host, port, err, errcode)
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
			local ctcp, err, errcode = tcp:accept()
			ctcp.n = n
			if not ctcp then
				self:error('accept(): %s [%s]', err, errcode)
				return
			end
			self.resume(self.newthread(function()
				local ok, err = xpcall(handler, debug.traceback, ctcp, t)
				if not ok then
					self:error('handler(): %s', err)
				end
				ctcp:close()
			end))
		end

		self.resume(self.newthread(function()
			while not stop do
				accept_connection()
			end
		end, 'SRV'))

		::continue::
	end

	return self
end

return server
