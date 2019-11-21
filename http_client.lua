
--async http(s) downloader.
--Written by Cosmin Apreutesei. Public Domain.

local coro = require'coro'
local loop = require'socketloop'.coro
local http = require'http'
local uri = require'uri'
local glue = require'glue'
http.zlib = require'zlib'
local tuple2 = glue.tuples(2)
local tuple3 = glue.tuples(3)
local time = require'time'

local client = {
	socket_timeout = 5,
	source_ips = {},
	print_urls = false,
	print_redirects = false,
	maxretries = 0,
	user_agent = 'Mozilla/5.0 (Windows NT 5.1)',
	max_redirect_count = 20,
}

--return a function that cycles source ips per destination host.
--good for crawling when the server has per-client-ip throttling.
function client:source_ip_roller(source_ips)
	if not source_ips then
		return glue.noop
	end
	local last_source_ip = {} --{host = index in source_ips}
	return function(self, host)
		local i = (last_source_ip[host] or 0) + 1
		if i > #source_ips then i = 1 end
		last_source_ip[host] = i
		return source_ips[i]
	end
end

function client:connect(host, port, client_ip, https)
	local sock, err = loop.connect(host, port, client_ip)
	if not sock then return nil, err end
	local http = http:new()
	http:bind_luasocket(sock)
	if https then
		local ok, err = http:bind_luasec(sock, host)
		if not ok then return nil, err end
	end
	return http
end

function client:redirect_call(t, req, res)
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
		method = req.method,
		close = t.close,
		host = loc.host or t.host,
		port = loc.port or (not loc.host and t.port or nil) or nil,
		https = https,
		uri = uri,
		content = t.content,
		content_size = t.content_size,
		compress = t.compress,
		headers = t.headers,
		receive_content = res.receive_content,
	}
end

client.max_connections = 10

function client:request(t)
	local host = assert(t.host)
	local https = t.https
	local port = t.port or (https and 443 or 80)
	local client_ip = t.client_ip or nil
	local k = tuple3(host, port, client_ip)
	local threads = glue.attr(glue.attr(self, 'request_threads'), k)
	threads.count = threads.count or 0
	local max_connections = t.max_connections or self.max_connections
	local thread
	if threads.count < max_connections then
		local function close(...)
			threads.count = threads.count - 1
			threads[thread] = nil
			return ...
		end
		thread = loop.newthread(function(t)
			local http, err = self:connect(host, port, client_ip, https)
			if not http then return close(nil, err) end
			while t do
				assert(t.https == https)
				local req = http:make_request(t)
				local ok, err = http:send_request(req)
				if not ok then return close(nil, err) end
				-- ...
				t = coro.transfer()
			end
			close(true)
		end)
		threads.count = threads.count + 1
		threads[thread] = true
	else
		thread = threads[
	end
	coro.transfer(thread, t)
end

function client:call(t)
	local sock, err = self:connect(t.host, t.port or (t.https and 443 or 80))
	if not sock then return nil, err end
	http:bind_luasocket(sock)
	if t.https then
		local ok, err = http:bind_luasec(sock, t.host)
		if not ok then return nil, err end
	end
	t.close = true

	local req = http:make_request(t)
	local ok, err = http:send_request(req)
	if not ok then return nil, err end

	local t0 = time.clock()

	local res, err = http:read_response(req)
	if not res then return nil, err end

	local t1 = time.clock()
	print(string.format('%04.02fs  %.1fkB',
		t1 - t0,
		res.content and #res.content / 1024 or 0))

	if not t.noredirect then
		local n = 0
		while res.redirect_location do
			if n >= self.max_redirect_count then
				http:close()
				return nil, 'too many redirects'
			end
			res, req = self:redirect(t, req, res)
			if not res then return nil, req end
			n = n + 1
		end
	end

	return res, req
end

function client:new(t)
	local self, super = t or {}, self
	self.__index = super
	setmetatable(self, self)
	return self
end

--test download speed --------------------------------------------------------

if not ... then

local function search_page_url(pn)
	return 'https://luapower.com/'
end

function kbytes(n)
	if type(n) == 'string' then n = #n end
	return n and string.format('%.1fkB', n/1024)
end

function mbytes(n)
	if type(n) == 'string' then n = #n end
	return n and string.format('%.1fmB', n/(1024*1024))
end

local n = 0
for i=1,1 do
	loop.newthread(function()
		local client = client:new()
		local res, req = client:call{
			--host = 'www.websiteoptimization.com',
			--uri = '/speed/tweak/compress/',
			host = 'luapower.com',
			https = true,
			receive_content = 'string',
		}
		n = n + #res.content
	end)
end
local t0 = time.clock()
loop.start(5)
t1 = time.clock()
print(mbytes(n / (t1 - t0))..'/s')

end



--[==[
function client:cookie_jar()

	local jars = {} --{client_ip = jar}; jar = {}

	local function cookie_attrs(t)
		local dt = {}
		if t then
			for i,t in ipairs(t) do
				dt[t.name] = t.value
			end
		end
		return dt
	end

	local function parse_expires(s)
		local t = s and http_date.parse(s)
		return t and os.time(t)
	end

	--cookies: {{name=,value=,attributes={{name=,value=}}},...}
	--[[local]] function store_cookies(client_ip, host, uri, cookies)
		client_ip = client_ip or '*'
		for i,cookie in ipairs(cookies) do
			if cookie.name then
				local a = cookie_attrs(cookie.attributes)
				local jar = glue.attr(jars, client_ip)
				local k = tuple2(a.domain or host, a.path or '/')
				local cookies = glue.attr(jar, k)
				cookies[cookie.name] = {
					value = cookie.value,
					expires = parse_expires(a.expires),
				}
				--print('>store_cookie', client_ip, host, cookie.name, cookie.value)
			end
		end
	end

	--return: {{name=, value=},...}
	function stored_cookies(client_ip, host, uri)
		client_ip = client_ip or '*'
		local dt = {}
		local jar = jars[client_ip]
		if jar then
			for k, cookies in pairs(jar) do
				local domain, path = k()
				if domain == host:sub(-#domain) then
					if path == uri:sub(1, #path) then
						for name,t in pairs(cookies) do
							if not t.expires or t.expires > os.time() then
								dt[#dt+1] = {name = name, value = t.value}
							end
						end
					end
				end
			end
		end
		if #dt > 0 then
			--print('>got_cookies', client_ip, host, pp.format(dt))
		end
		return dt
	end
end
]==]
