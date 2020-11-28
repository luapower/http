
if not ... then require'http_server_test'; return end

local http = require'http'
local uri = require'uri'
local time = require'time'
local glue = require'glue'

local _ = string.format
local attr = glue.attr
local push = table.insert
local pull = function(t)
	return table.remove(t, 1)
end

local server = {
	type = 'http_server', http = http,
	loadfile = glue.readfile,
	tls_options = {
		protocols = 'tlsv1.2',
		--[=[
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
		]=]
		--insecure_noverifycert = true,
		--insecure_noverifyname = true,
		--insecure_noverifytime = true,
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

	local function handler(ctcp, port)

		local http = self.http:new({
			debug = self.debug,
			max_line_size = self.max_line_size,
			tcp = ctcp,
		})

		while true do

			local req, err = http:read_request('string')
			if not req then
				if err == 'closed' then
					return
				end
				self:error('read_request(): %s', err)
				return
			end

			local res = http:make_response(req, {
				content = 'Hello',
				compress = true,
			}, self:utc_time())

			local ok, err = http:send_response(res)
			if not ok then
				self:error('send_response(): %s', err)
				ctcp:close()
				break
			end

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
			tcp:close()
			goto continue
		end
		self:dbg('LISTEN', tcp, '%s:%d', host, port)

		if t.tls then
			local opt = glue.update(self.tls_options, t.tls_options)
			for k,v in pairs(opt) do
				if glue.ends(k, '_file') then
					opt[k:gsub('_file$', '')] = assert(self.loadfile(v))
					opt[k] = nil
				end
			end
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
			if not ctcp then
				self:error('accept(): %s [d]', err, errcode)
				return
			end
			self.newthread(function()
				local ok, err = xpcall(handler, debug.traceback, ctcp)
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
