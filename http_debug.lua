
local ffi = require'ffi'
local clock = require'time'.clock
local glue = require'glue'
local _ = string.format

local M = {}

function M:install_to_http(http)

	require'$log'

	local function http_dbg(module, event, fmt, ...)
		local S = http.tcp or '-'
		local T = http.currentthread()
		local dt = clock() - http.start_time
		local s = _(fmt, debug.args(...))
		dbg(module, event, '%-4s %-4s %6.2fs %s', T, S, dt, s)
	end

	if http.debug.protocol then

		function http:dbg(event, ...)
			http_dbg('http', event, ...)
		end

	end

	if http.debug.stream then

		local P = function(event, s)
			http_dbg('http', event, '%5s %s', s and #s or '', s or '')
		end

		glue.override(http.tcp, 'recv', function(inherited, self, buf, ...)
			local sz, err, errcode = inherited(self, buf, ...)
			if not sz then return nil, err, errcode end
			P('<', ffi.string(buf, sz))
			return sz
		end)

		glue.override(http.tcp, 'send', function(inherited, self, buf, ...)
			local sz, err, errcode = inherited(self, buf, ...)
			if not sz then return nil, err, errcode end
			P('>', ffi.string(buf, sz))
			return sz
		end)

		glue.override(http.tcp, 'close', function(inherited, self, ...)
			local ok, err, errcode = inherited(self, ...)
			if not ok then return nil, err, errcode  end
			P('CC')
			return ok
		end)

	end

end

function M:install_to_client(client)
	if not client.debug then return end

	require'$log'

	function client:dbg(target, event, fmt, ...)
		local T = self.currentthread()
		local s =_(fmt, debug.args(...))
		dbg('http-c', event, '%-4s %-4s %s', T, target, s)
	end

	local function pass(rc, ...)
		dbg(('<'):rep(1+rc)..('-'):rep(78-rc))
		return ...
	end
	glue.override(client, 'request', function(inherited, self, t, ...)
		local rc = t.redirect_count or 0
		dbg(('>'):rep(1+rc)..('-'):rep(78-rc))
		return pass(rc, inherited(self, t, ...))
	end)

end

function M:install_to_server(server)
	if not server.debug then return end

	require'$log'

	function server:dbg(event, tcp, fmt, ...)
		local T = self.currentthread()
		local s =_(fmt, debug.args(...))
		dbg('http-s', event, '%-4s %-4s %s', T, tcp, s)
	end

	function server:err(event, tcp, fmt, ...)
		local T = self.currentthread()
		local s =_(fmt, debug.args(...))
		logerror('http-s', event, '%-4s %-4s %s', T, tcp, s)
	end

end

return M
