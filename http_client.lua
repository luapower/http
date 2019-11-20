
--async http(s) downloader.
--Written by Cosmin Apreutesei. Public Domain.

local loop = require'socketloop'
local socket = require'socket'
local http = require'http'
local uri = require'uri'
local glue = require'glue'
http.zlib = require'zlib'
local tuple2 = glue.tuples(2)

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

function client:connection_pool()

	local cct = {total = 0, now = 0, idle = 0}
	local function cc(k, n)
		cct[k] = cct[k] + n
	end

	function conn_stats()
		return 'now='..cct.now..', total='..cct.total..', idle='..cct.idle
	end

	local conns = {} --{(host, port) = {conn1, ...}}
	local pool = {}

	function pool:pull_conn(host, port)
		local k = tuple2(host, port)
		local h = conns[k] and table.remove(conns[k], 1) --FIFO order
		cc('idle', h and -1 or 0)
		return h
	end

	function pool:push_conn(host, port, h)
		local k = tuple2(host, port)
		conns[k] = conns[k] or {}
		table.insert(conns[k], h)
		cc('idle', 1)
	end

	function pool:remove_conn(host, port, h)
		local k = tuple2(host, port)
		local t = conns[k]
		if not t then return end
		for i,h1 in ipairs(t) do
			if h1 == h then
				--print('>remove_conn', k, pp.format(k), h)
				table.remove(t, i)
				break
			end
		end
	end

	function pool:close_connections()
		for _,t in pairs(conns) do
			for i=#t,1,-1 do
				local h = t[i]
				h:close(true) --force-close
			end
		end
	end

	return pool
end

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

function client:new(t)

	--self.get_source_ip = self:source_ip_roller(self.source_ips)
	--self.conn_pool = self:connection_pool()

	--[[
	local source_ip = self:get_source_ip()
	if source_ip then
		assert(c:bind(source_ip, 0))
	end

	function h:close(force)
		if force then
			remove_conn(host, port, h)
			close(h)
			cc('now', -1)
			cc('idle', -1)
		else
			push_conn(host, port, h)
		end
	end

	--override http methods so we can store and retrieve cookies.

	local sent_uri
	local sendrequestline = h.sendrequestline
	function h:sendrequestline(method, uri)
		sent_uri = uri
		sendrequestline(self, method, uri)
	end

	local sendheaders = h.sendheaders
	function h:sendheaders(headers)
		local cookies = stored_cookies(source_ip, host, sent_uri)
		if cookies and #cookies > 0 then
			headers['Cookie'] = http_cookie.build(cookies)
		end
		sendheaders(self, headers)
	end

	local receiveheaders = h.receiveheaders
	function h:receiveheaders()
		local headers = receiveheaders(self)

		local cookies = headers['set-cookie']
		if cookies then
			local cookies = http_cookie.parse(cookies)
			store_cookies(source_ip, host, sent_uri, cookies)
		end

		return headers
	end

	return h

	local function urlencode(t)
		local dt = {}
		for k,v in pairs(t) do
			dt[#dt+1] = url.escape(k)..'='..url.escape(v)
		end
		return table.concat(dt, '&')
	end

	local function download_page(req, retries)
		local url = type(req) == 'table' and assert(req.url) or req
		local useropt = type(req) == 'table' and req or nil
		retries = retries or 0

		local chunks = {}

		--note: this hack prevents parsing and rebuilding the url by the http
		--module, which doesn't escape '&' in path components, and 6pm.com
		--doesn't like that.
		local s, host, uri = url:match'^http(s?)://(.-)(/.*)$'
		local https = s == 's'

		local opt = {
			host = host,
			uri = uri,
			headers = {['accept-encoding'] = 'gzip'},
			sink = ltn12.sink.table(chunks),
			redirect = false, --redirect doesn't work with persistent connections!
			noclose = true, --don't tell the server to close the connection!
			port = https and 443 or 80,
		}

		if useropt then
			opt.method = useropt.method or 'GET'
			if useropt.form then
				local data = urlencode(useropt.form)
				opt.method = useropt.method or 'POST'
				glue.merge(opt.headers, {
					['content-length'] = #data,
					['content-type'] = 'application/x-www-form-urlencoded',
				})
				opt.source = ltn12.source.string(data)
			end
		end

		local ok, code, headers = http.request(opt)

		if not ok then
			if retries < self.maxretries then
				return download_page(req, retries + 1)
			end
			return nil, code
		end

		local body
		if headers['content-encoding'] == 'gzip' then
			body = zlib.inflate(chunks, '', 4096, 'gzip')
		else
			body = table.concat(chunks)
		end

		return body, code, headers
	end

	local known_ext = glue.index{'jpeg', 'jpg', 'png', 'gif', 'json', 'js',
		'css', 'htm', 'html'}
	local conv_ext = {jpeg = 'jpg', htm = 'html'}
	function url_fileext(url)
		local ext = url:gsub('%?.*', ''):match'%.(%a+)$'
		local ext = conv_ext[ext] or ext
		return known_ext[ext] and ext or nil
	end

	--getpage with bells:
	-- * makes an async request if a completion callback is given.
	-- * starts the loop if called from the main thread.
	function self:getpage(req, on_complete, on_error)
		if type(req) == 'string' then
			req = {url = req}
		end
		if on_complete then --async request in sub-thread
			loop.newthread(function()
				local body, code, headers = getpage(req)
				if body then
					on_complete(body, code, headers)
				elseif on_error then
					on_error(code)
				end
			end)
		elseif not coroutine.running() then --main thread: make a loop
			local body, code, headers
			loop.newthread(function()
				body, code, headers = getpage(req)
			end)
			loop.start(self.socket_timeout)
			close_connections()
			return body, code, headers
		else --normal thread: make a synchronous request
			return getpage_with_cache(req)
		end
	end
	]]

	local self, super = t or {}, self
	self.__index = super
	setmetatable(self, self)

	--

	return self
end

function client:redirect(t, req, res)
	local location = assert(res.redirect_location, 'no location')
	local loc = uri.parse(location)
	local uri = uri.format{
		path = loc.path,
		query = loc.query,
		fragment = loc.fragment,
	}
	local https = loc.scheme == 'https' or nil
	return self:call{
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
		receive_content = t.receive_content,
	}
end

function client:call(t)
	local sock = socket.tcp()
	assert(sock:connect(t.host, t.port or (t.https and 443 or 80)))
	local http = http:new()
	http:bind_luasocket(sock)
	if t.https then
		local ok, err = http:bind_luasec(sock, t.host)
		if not ok then return nil, err end
	end
	t.close = true
	local res, req = http:perform_request(t)
	if not t.noredirect then
		local n = 0
		while res.redirect_location do
			if n >= self.max_redirect_count then
				http:close()
				return nil, 'too many redirects'
			end
			res, req = self:redirect(t, req, res)
			n = n + 1
		end
	end
	return res, req
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

local function speed_test()

	local client = client:new{
		--
	}

	local pn = 0
	local bytes = 0

	local t0 = socket.gettime()

	local function timepoint(s)
		local t1 = socket.gettime()
		print((' '):rep(math.floor((t1 - t0) * 10))..'*'..(s and ' '..s or ''))
	end

	for i = 1, 10 do
		loop.newthread(function()
			for i = 1, 6 do
				pn = pn + 1
				local pn = pn
				local url = search_page_url(pn)
				local body, code, headers = client:getpage(url)
				if body then
					timepoint('http '..code .. ' - ' .. kbytes(body) ..
						' (page '.. pn .. ')')
					bytes = bytes + #body
				else
					print('ERROR: ', pp.format(code))
				end
			end
		end)
	end

	loop.start(5)
	close_connections()

	local t1 = socket.gettime()
	print('Downloaded: ', mbytes(bytes))
	print('Speed:      ', mbytes(bytes / (t1 - t0))..'/s')
end

--speed_test()

local client = client:new()
pp(client:call{
	--host = 'www.websiteoptimization.com',
	--uri = '/speed/tweak/compress/',
	host = 'luapower.com',
})

end

