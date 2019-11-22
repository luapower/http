
--async http(s) downloader.
--Written by Cosmin Apreutesei. Public Domain.

local loop = require'socketloop'.coro
local http = require'http'
local uri = require'uri'
local time = require'time'
local glue = require'glue'
http.zlib = require'zlib'
local attr = glue.attr

local push = table.insert
local pull = function(t)
	return table.remove(t, 1)
end

local client = {
	max_conn = 50,
	max_conn_per_session = 10, --a session is (host, port, client_ip)
	socket_timeout = 5,
	client_ips = {},
	print_urls = false,
	print_redirects = false,
	max_retries = 0,
	user_agent = 'Mozilla/5.0 (Windows NT 5.1)',
	max_redirects = 20,
}

function client:next_client_ip(host, port)
	if #self.client_ips == 0 then
		return nil
	end
	local t = attr(self, 'last_client_ip_index')
	local k = self.t2(host, port)
	local i = (t[k] or 0) + 1
	if i > #self.client_ips then i = 1 end
	t[k] = i
	return self.client_ips[i]
end

function client:conn(t)
	local host = assert(t.host)
	local https = t.https and true or false
	local port = t.port or (https and 443 or 80)
	local client_ip = t.client_ip or self:next_client_ip(host, port)
	local k = self.t3(host, port, client_ip)
	if k.https == nil then
		k.https = https
	else
		assert(k.https == https)
	end
	return k
end

function client:conn_data(k)
	return attr(self._conn_data, k)
end

function client:count_conn(k)
	self.conn_count = self.conn_count + 1
	local t = self:conn_data(k)
	t.count = (t.count or 0) + 1
end

function client:discount_conn(k)
	self.conn_count = self.conn_count - 1
	local t = self:conn_data(k)
	t.count = t.count - 1
end

function clent:can_connect_now(k)
	local conn_count = self.conn_count
	if conn_count >= self.max_conn then
		return false, 'too many connections'
	end
	if (self:conn_data(k).count or 0) >= self.max_conn_per_session then
		return false, 'too many connections for this host:port:client_ip'
	end
	return true
end

function client:connect(k)
	local host, port, client_ip = k()
	local sock, err = loop.create_connection(client_ip)
	if not sock then return nil, err end
	self:count_conn(k)
	local ok, err = sock:connect(host, port)
	if not ok then
		self:discount_conn(k)
		return nil, err
	end
	glue.after(sock, 'close', function()
		self:discount_conn(k)
	end)
	local http = http:new{
		host = host,
		port = port,
		https = k.https,
	}
	http:bind_luasocket(sock)
	if https then
		local ok, err = http:bind_luasec(sock, host)
		if not ok then return nil, err end
	end
	return http
end

function client:pull_conn(k)
	local t = self:conn_data(k).ready
	return t and pull(t)
end

function client:push_conn(k, http)
	push(attr(self:conn_data(k), 'ready'), http)
end

function client:wait_conn(k)
	push(attr(self:conn_data(k), 'wait'), loop.current())
	loop.suspend()
end

function client:wait_response(http, req)
	push(attr(http, 'wait_response_queue'), loop.current())
	loop.suspend()
end

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

function client:request(t)
	local k = self:conn(t)
	local http, err = self:pull_conn()
	if not http then
		if self:can_connect_now(k) then
			http, err = self:connect(k)
		else
			http, err = self:wait_conn(k)
		end
		if not http then return nil, err end
	end
	local req = http:make_request(t)
	local ok, err = http:send_request(req)
	if not ok then return nil, err end
	self:push_conn(k, http)
	return self:wait_response(http, req)
end

function client:new(t)
	local self = glue.object(self, t)
	self._conn_data = {}
	self.conn_count = 0
	self.t2 = glue.tuples(2)
	self.t3 = glue.tuples(3)
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
				local jar = attr(jars, client_ip)
				local k = tuple2(a.domain or host, a.path or '/')
				local cookies = attr(jar, k)
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
