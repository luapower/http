
--async http(s) downloader.
--Written by Cosmin Apreutesei. Public Domain.

if not ... then require'http_client_test'; return end

local loop = require'socketloop'
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

local client = {
	type = 'http_client', http = http,
	max_conn = 50,
	max_conn_per_target = 20,
	max_pipelined_requests = 10,
	socket_timeout = 5,
	client_ips = {},
	max_retries = 0,
	max_redirects = 20,
	max_cookie_length = 8192,
	max_cookies = 1e6,
	max_cookies_per_host = 1000,
}

client.dbg = glue.noop

function client:utc_time(date)
	return glue.time(date, true)
end

--targets --------------------------------------------------------------------

--A target is a combination of (vhost, port, client_ip) on which one or more
--HTTP connections can be created subject to per-target limits.

function client:assign_client_ip(host, port)
	if #self.client_ips == 0 then
		return nil
	end
	local ci = self.last_client_ip_index(host, port)
	local i = (ci.index or 0)
	if i > #self.client_ips then i = 1 end
	ci.index = i
	return self.client_ips[i]
end

function client:target(t)
	local host = assert(t.host, 'host missing'):lower()
	local https = t.https and true or false
	local port = t.port and assert(tonumber(t.port), 'invalid port')
		or (https and 443 or 80)
	local client_ip = t.client_ip or self:assign_client_ip(host, port)
	local target = self.targets(host, port, client_ip)
	if not target.http_args then
		target.type = 'http_target'
		target.host = host
		target.http_args = {
			target = target,
			port = port,
			client_ip = client_ip,
			https = https,
			max_line_size = t.max_line_size,
			debug = t.debug,
		}
		target.max_pipelined_requests = t.max_pipelined_requests
		target.max_conn = t.max_conn_per_target
		target.max_redirects = t.max_redirects
	else
		assert(https == target.http_args.https)
	end
	return target
end

--connections ----------------------------------------------------------------

function client:inc_conn_count(target, n)
	n = n or 1
	self.conn_count = (self.conn_count or 0) + n
	target.conn_count = (target.conn_count or 0) + n
	self:dbg(target, (n > 0 and '+' or '-')..'CONN_COUNT', '%s=%d, total=%d',
		target, target.conn_count, self.conn_count)
end

function client:dec_conn_count(target)
	self:inc_conn_count(target, -1)
end

function client:push_ready_conn(target, http)
	push(attr(target, 'ready'), http)
	self:dbg(target, '+READY', '%s', http)
end

function client:pull_ready_conn(target)
	local http = target.ready and pull(target.ready)
	if not http then return end
	self:dbg(target, '-READY', '%s', http)
	return http
end

function client:push_wait_conn_thread(thread, target)
	local queue = attr(self, 'wait_conn_queue')
	push(queue, {thread, target})
	self:dbg(target, '+WAIT_CONN', '%s %s', thread, target)
end

function client:pull_wait_conn_thread()
	local queue = self.wait_conn_queue
	local t = queue and pull(queue)
	if not t then return end
	local thread, target = t[1], t[2]
	self:dbg(target, '-WAIT_CONN', '%s', thread)
	return thread, target
end

function client:pull_matching_wait_conn_thread(target)
	local queue = self.wait_conn_queue
	if not queue then return end
	for i,t in ipairs(queue) do
		if t[2] == target then
			table.remove(queue, i)
			local thread = t[1]
			self:dbg(target, '-MATCHING_WAIT_CONN', '%s: %s', target, thread)
			return thread
		end
	end
end

function client:_can_connect_now(target)
	if (self.conn_count or 0) >= self.max_conn then return false end
	if target then
		local target_conn_count = target.conn_count or 0
		local target_max_conn = target.max_conn or self.max_conn_per_target
		if target_conn_count >= target_max_conn then return false end
	end
	return true
end
function client:can_connect_now(target)
	local can = self:_can_connect_now(target)
	self:dbg(target, '?CAN_CONNECT_NOW', '%s', can)
	return can
end

function client:connect_now(target)
	local host, port, client_ip = target()
	local sock, err = loop.tcp(client_ip)
	if not sock then return nil, err end
	self:inc_conn_count(target)
	local ok, err = sock:connect(host, port)
	self:dbg(target, '+CONNECT', '%s %s', sock, err or '')
	if not ok then
		self:dec_conn_count(target)
		return nil, err
	end
	glue.after(sock, 'close', function(sock)
		self:dbg(target, '-DISCONNECT', '%s', sock)
		self:dec_conn_count(target)
		self:resume_next_wait_conn_thread()
	end)
	local http = http:new(target.http_args)
	http:bind_luasocket(sock)
	self:dbg(target, ' BIND_LUASOCKET', '%s %s', sock, http)
	if http.https then
		local ok, err = http:bind_luasec(sock, host)
		self:dbg(target, ' BIND_LUASEC', '%s %s %s', sock, http, err or '')
		if not ok then return nil, err end
	end
	return http
end

function client:wait_conn(target)
	local thread = loop.current()
	self:push_wait_conn_thread(thread, target)
	self:dbg(target, '=WAIT_CONN', '%s %s', thread, target)
	local http = loop.suspend()
	if http == 'connect' then
		return self:connect_now(target)
	else
		return http
	end
end

function client:get_conn(target)
	local http, err = self:pull_ready_conn(target)
	if http then return http end
	if self:can_connect_now(target) then
		return self:connect_now(target)
	else
		return self:wait_conn(target)
	end
end

function client:resume_next_wait_conn_thread()
	local thread, target = self:pull_wait_conn_thread()
	if not thread then return end
	self:dbg(target, '^WAIT_CONN', '%s', thread)
	loop.resume(thread, 'connect')
end

function client:resume_matching_wait_conn_thread(target, http)
	local thread = self:pull_matching_wait_conn_thread(target)
	if not thread then return end
	self:dbg(target, '^WAIT_CONN', '%s < %s', thread, http)
	loop.resume(thread, http)
	return true
end

function client:can_pipeline_new_requests(http, target, req)
	local close = req.close
	local pr_count = http.wait_response_count or 0
	local max_pr = target.max_pipelined_requests or self.max_pipelined_requests
	local can = not close and pr_count < max_pr
	self:dbg(target, '?CAN_PIPELINE', '%s (wait:%d, close:%s)', can, pr_count, close)
	return can
end

--pipelining -----------------------------------------------------------------

function client:push_wait_response_thread(http, thread, target)
	push(attr(http, 'wait_response_threads'), thread)
	http.wait_response_count = (http.wait_response_count or 0) + 1
	self:dbg(target, '+WAIT_RESPONSE')
end

function client:pull_wait_response_thread(http, target)
	local queue = http.wait_response_threads
	local thread = queue and pull(queue)
	if not thread then return end
	self:dbg(target, '-WAIT_RESPONSE')
	return thread
end

function client:read_response_now(http, req)
	http.reading_response = true
	self:dbg(http.target, '+READ_RESPONSE', '%s.%s.%s', http.target, http, req)
	local res, err, errtype = http:read_response(req)
	self:dbg(http.target, '-READ_RESPONSE', '%s.%s.%s %s %s',
		http.target, http, req, err or '', errtype or '')
	http.reading_response = false
	return res, err, errtype
end

--redirects ------------------------------------------------------------------

function client:redirect_request_args(t, req, res)
	local location = assert(res.redirect_location, 'no location')
	local loc = uri.parse(location)
	local uri = uri.format{
		path = loc.path,
		query = loc.query,
		fragment = loc.fragment,
	}
	local https = loc.scheme == 'https' or nil
	return {
		http_version = res.http_version,
		method = 'GET',
		close = t.close,
		host = loc.host or t.host,
		port = loc.port or (not loc.host and t.port or nil) or nil,
		https = https,
		uri = uri,
		compress = t.compress,
		headers = glue.merge({['content-type'] = false}, t.headers),
		receive_content = res.receive_content,
		redirect_count = (t.redirect_count or 0) + 1,
	}
end

--cookie management ----------------------------------------------------------

function client:accept_cookie(cookie, host)
	return http:cookie_domain_matches_request_host(cookie.domain, host)
end

function client:cookie_jar(ip)
	return attr(attr(self, 'cookies'), ip or '*')
end

function client:remove_cookie(jar, domain, path, name)
	--
end

function client:clear_cookies(client_ip, host, utc_time)
	--
end

function client:store_cookies(target, req, res, utc_time)
	local cookies = res.headers['set-cookie']
	if not cookies then return end
	local utc_time = utc_time or self:utc_time()
	local client_jar = self:cookie_jar(target.client_ip)
	local host = target.host
	for _,cookie in ipairs(cookies) do
		if self:accept_cookie(cookie, host) then
			local expires
			if cookie.expires then
				expires = self:utc_time(cookie.expires)
			elseif cookie['max-age'] then
				expires = utc_time + cookie['max-age']
			end
			local domain = cookie.domain or host
			local path = cookie.path or http:cookie_default_path(req.uri)
			if expires and expires < utc_time then --expired: remove from jar.
				self:remove_cookie(client_jar, domain, path, cookie.name)
			else
				local sc = attr(attr(attr(client_jar, domain), path), cookie.name)
				sc.wildcard = cookie.domain and true or false
				sc.secure = cookie.secure
				sc.expires = expires
				sc.value = cookie.value
			end
		end
	end
end

function client:get_cookies(client_ip, host, uri, https, utc_time)
	local client_jar = self:cookie_jar(client_ip)
	if not client_jar then return end
	local path = uri:match'^[^%?#]+'
	local utc_time = utc_time or self:utc_time()
	local cookies = {}
	local names = {}
	for s in host:gmatch'[^%.]+' do
		push(names, s)
	end
	local domain = names[#names]
	for i = #names-1, 1, -1 do
		domain = names[i] .. '.' .. domain
		local domain_jar = client_jar[domain]
		if domain_jar then
			for cpath, path_jar in pairs(domain_jar) do
				if http:cookie_path_matches_request_path(cpath, path) then
					for name, sc in pairs(path_jar) do
						if sc.expires and sc.expires < utc_time then --expired: auto-clean.
							self:remove_cookie(client_jar, domain, cpath, sc.name)
						elseif https or not sc.secure then --allow
							cookies[name] = sc.value
						end
					end
				end
			end
		end
	end
	return cookies
end

function client:save_cookies(file)
	return glue.writefile(file, pp.format(self.cookies, '\t'), nil, file..'.tmp')
end

function client:load_cookies(file)
	local s, err = glue.readfile(file)
	if not s then return nil, err end
	local f, err = loadstring('return '..s, file)
	if not f then return nil, err end
	local ok, t = pcall(f)
	if not ok then return nil, t end
	self.cookies = t
end

--request call ---------------------------------------------------------------

function client:request(t)

	local target = self:target(t)

	self:dbg(target, '+REQUEST', '%s = %s', target, tostring(target))

	local http, err = self:get_conn(target)
	if not http then return nil, err end

	local cookies = self:get_cookies(target.client_ip, target.host,
		t.uri or '/', target.http_args.https)

	local req = http:make_request(t, cookies)

	self:dbg(target, '+SEND_REQUEST', '%s.%s.%s %s %s',
		target, http, req, req.method, req.uri)

	local ok, err = http:send_request(req)
	if not ok then return nil, err, req end

	self:dbg(target, '-SEND_REQUEST', '%s.%s.%s', target, http, req)

	local waiting_response
	if http.reading_response then
		self:push_wait_response_thread(http, loop.current(), target)
		waiting_response = true
	else
		http.reading_response = true
	end

	local taken
	if self:can_pipeline_new_requests(http, target, req) then
		taken = true
		if not self:resume_matching_wait_conn_thread(target, http) then
			self:push_ready_conn(target, http)
		end
	end

	if waiting_response then
		loop.suspend()
	end

	local res, err, errtype = self:read_response_now(http, req)
	if not res then return nil, err, errtype end

	self:store_cookies(target, req, res)

	if not taken and not http.closed then
		if not self:resume_matching_wait_conn_thread(target, http) then
			self:push_ready_conn(target, http)
		end
	end

	if not http.closed then
		local thread = self:pull_wait_response_thread(http, target)
		if thread then
			loop.resume(thread)
		end
	end

	self:dbg(target, '-REQUEST', '%s.%s.%s body: %d bytes',
		target, http, req,
		res and type(res.content) == 'string' and #res.content or 0)

	if res and res.redirect_location then
		local t = self:redirect_request_args(t, req, res)
		local max_redirects = target.max_redirects or self.max_redirects
		if t.redirect_count >= max_redirects then
			return nil, 'too many redirects', req
		end
		return self:request(t)
	end

	return res, req
end

--instantiation --------------------------------------------------------------

function client:new(t)
	local self = glue.object(self, {}, t)
	self.last_client_ip_index = glue.tuples(2)
	self.targets = glue.tuples(3)
	self.cookies = {}
	if self.debug then
		local dbg = require'http_debug'
		dbg:install_to_client(self)
	end
	return self
end

return client
