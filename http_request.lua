
-- HTTP/1.1 client protocol in Lua.
-- Written by Cosmin Apreutesei. Public Domain.

local url = require'url'
local b64 = require'libb64'
local headers = require'http_headers'

local request = {}

request.user_agent = 'http_request.lua' -- user agent field sent in request

function request:read_headers()
	local line, name, value
	self.response_headers = self.response_headers or {}
	local headers = self.response_headers
	line = self:read_line()
	while line ~= '' do --headers end up with a blank line
		name, value = assert(string.match(line, '^(.-):%s*(.*)', 'invalid header')
		name = string.lower(name)
		line = self:read_line()
		while string.find(line, '^%s') do --unfold any folded values
			value = value .. line
			line = self:read_line()
		end
		if headers[name] then
			headers[name] = headers[name] .. ', ' .. value
		else
			headers[name] = value
		end
	end
end

function request:read_chunks()
	while true do
		local line = self:read_line()
		local size = tonumber(string.gsub(line, ';.*', ''), 16) --size[; extension]
		assert(size, 'invalid chunk size')
		if size > 0 then --get chunk and skip terminating CRLF
			self:read_content(size)
			self:read_line()
		else --last chunk, read trailers
			self:read_headers()
			return
		end
	end
end

function request:write_chunk(chunk)
	if not chunk then
		sock:write'0\r\n\r\n'
	else
		local size = string.format('%X\r\n', string.len(chunk))
		self:write(size ..  chunk .. '\r\n')
	end
end

function request:write_request_line(method, uri)
	local method = method and method:upper() or 'GET'
	local reqline = string.format('%s %s HTTP/1.1\r\n', method, uri)
	self:write(reqline)
end

function request:write_headers()
	for k, v in pairs(self.request_headers) do
		self:write(k .. ': ' .. v .. '\r\n')
	end
	self:write'\r\n'
end

function request:write_body()
	local mode = 'http-chunked'
	if headers['content-length'] then
		mode = 'keep-open'
	end
end

function request:read_status_line()
	local code = string.match(self:read_line(), 'HTTP/%d*%.%d* (%d%d%d)')
	return assert(tonumber(code), 'invalid status line')
end

function request:read_body()
	local te = headers['transfer-encoding']
	if te and te ~= 'identity' then
		self:read_chunks()
	else
		local len = tonumber(headers['content-length'])
		if len then
			self:read_content(len)
		end
	end
end

local function adjusturi(reqt)
	local u = reqt
	-- if there is a proxy, we need the full url. otherwise, just a part.
	if not reqt.proxy and not _M.PROXY then
		u = {
		   path = socket.try(reqt.path, 'invalid path "nil"'),
		   params = reqt.params,
		   query = reqt.query,
		   fragment = reqt.fragment
		}
	end
	return url.build(u)
end

local function adjustproxy(reqt)
	local proxy = reqt.proxy or _M.PROXY
	if proxy then
		proxy = url.parse(proxy)
		return proxy.host, proxy.port or 3128
	else
		return reqt.host, reqt.port
	end
end

local function adjustheaders(reqt)
	-- default headers
	local host = reqt.host
	if reqt.port then host = host .. ':' .. reqt.port end
	local lower = {
		['user-agent'] = _M.USERAGENT,
		['host'] = host,
		['connection'] = (reqt.noclose and '' or 'close, ') .. 'TE',
		['te'] = 'trailers'
	}
	-- if we have authentication information, pass it along
	if reqt.user and reqt.password then
		lower['authorization'] =
			'Basic ' ..  (mime.b64(reqt.user .. ':' .. reqt.password))
	end
	-- override with user headers
	for i,v in pairs(reqt.headers or lower) do
		lower[string.lower(i)] = v
	end
	return lower
end

local function adjustrequest(reqt)
	-- parse url if provided
	local nreqt = reqt.url and url.parse(reqt.url, default) or {}
	-- explicit components override url
	for i,v in pairs(reqt) do nreqt[i] = v end
	if nreqt.port == '' then nreqt.port = 80 end
	socket.try(nreqt.host and nreqt.host ~= '',
		'invalid host "' .. tostring(nreqt.host) .. '"')
	-- compute uri if user hasn't overriden
	nreqt.uri = reqt.uri or adjusturi(nreqt)
	-- ajust host and port if there is a proxy
	nreqt.host, nreqt.port = adjustproxy(nreqt)
	-- adjust headers in request
	nreqt.headers = adjustheaders(nreqt)
	return nreqt
end

local function shouldredirect(reqt, code, headers)
	return headers.location and
		   string.gsub(headers.location, '%s', '') ~= '' and
		   (reqt.redirect ~= false) and
		   (code == 301 or code == 302 or code == 303 or code == 307) and
		   (not reqt.method or reqt.method == 'GET' or reqt.method == 'HEAD')
		   and (not reqt.nredirects or reqt.nredirects < 5)
end

local function shouldreceivebody(reqt, code)
	if reqt.method == 'HEAD' then return nil end
	if code == 204 or code == 304 then return nil end
	if code >= 100 and code < 200 then return nil end
	return 1
end

-- forward declarations
local trequest, tredirect

--[[local]] function tredirect(reqt, location)
	local result, code, headers, status = trequest {
		-- the RFC says the redirect URL has to be absolute, but some
		-- servers do not respect that
		url = url.absolute(reqt.url, location),
		source = reqt.source,
		sink = reqt.sink,
		headers = reqt.headers,
		proxy = reqt.proxy,
		nredirects = (reqt.nredirects or 0) + 1,
		create = reqt.create
	}
	-- pass location header back as a hint we redirected
	headers = headers or {}
	headers.location = headers.location or location
	return result, code, headers, status
end

function request:write_request(t)
	self:write_request_line(t.method, t.uri)
	self:write_headers()
	self:write_body()
end

function request:read_response()
	local code = self:read_status_line()
	while code == 100 do --ignore any 100-continue messages
		self:read_headers()
		code = h:read_status_line()
	end
	self:read_headers()
	-- at this point we should have a honest reply from the server
	-- we can't redirect if we already used the source, so we report the error
	if shouldredirect(nreqt, code, headers) and not nreqt.source then
		h:close()
		return tredirect(reqt, headers.location)
	end
	-- here we are finally done
	if shouldreceivebody(nreqt, code) then
		h:receivebody(headers, nreqt.sink, nreqt.step)
	end
	return code
end

local function srequest(u, b)
	local t = {}
	local reqt = {
		url = u,
		sink = ltn12.sink.table(t)
	}
	if b then
		reqt.source = ltn12.source.string(b)
		reqt.headers = {
			['content-length'] = string.len(b),
			['content-type'] = 'application/x-www-form-urlencoded'
		}
		reqt.method = 'POST'
	end
	local _, code, headers, status = trequest(reqt)
	return table.concat(t), code, headers, status
end

function request:new(opt, body)
	if type(opt) == 'string' then
		return self:new{url = opt, body = body}
	end
	self:write_request()
	self:read_response()
end)

return request
