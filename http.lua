
-- HTTP 1.1 client & server protocol in Lua.
-- Written by Cosmin Apreutesei. Public Domain.

if not ... then require'http_test'; return end

local stream = require'stream'
local ffi = require'ffi'

local http = {}

--https://www.iana.org/assignments/http-status-codes/http-status-codes.txt
http.status_messages = {
	[100] = 'Continue',
	[101] = 'Switching Protocols',
	[102] = 'Processing',
	[103] = 'Early Hints',
	[200] = 'OK',
	[201] = 'Created',
	[202] = 'Accepted',
	[203] = 'Non-Authoritative Information',
	[204] = 'No Content',
	[205] = 'Reset Content',
	[206] = 'Partial Content',
	[207] = 'Multi-Status',
	[208] = 'Already Reported',
	[226] = 'IM Used',
	[300] = 'Multiple Choices',
	[301] = 'Moved Permanently',
	[302] = 'Found',
	[303] = 'See Other',
	[304] = 'Not Modified',
	[305] = 'Use Proxy',
	[306] = '(Unused)',
	[307] = 'Temporary Redirect',
	[308] = 'Permanent Redirect',
	[400] = 'Bad Request',
	[401] = 'Unauthorized',
	[402] = 'Payment Required',
	[403] = 'Forbidden',
	[404] = 'Not Found',
	[405] = 'Method Not Allowed',
	[406] = 'Not Acceptable',
	[407] = 'Proxy Authentication Required',
	[408] = 'Request Timeout',
	[409] = 'Conflict',
	[410] = 'Gone',
	[411] = 'Length Required',
	[412] = 'Precondition Failed',
	[413] = 'Payload Too Large',
	[414] = 'URI Too Long',
	[415] = 'Unsupported Media Type',
	[416] = 'Range Not Satisfiable',
	[417] = 'Expectation Failed',
	[421] = 'Misdirected Request',
	[422] = 'Unprocessable Entity',
	[423] = 'Locked',
	[424] = 'Failed Dependency',
	[425] = 'Too Early',
	[426] = 'Upgrade Required',
	[427] = 'Unassigned',
	[428] = 'Precondition Required',
	[429] = 'Too Many Requests',
	[430] = 'Unassigned',
	[431] = 'Request Header Fields Too Large',
	[451] = 'Unavailable For Legal Reasons',
	[500] = 'Internal Server Error',
	[501] = 'Not Implemented',
	[502] = 'Bad Gateway',
	[503] = 'Service Unavailable',
	[504] = 'Gateway Timeout',
	[505] = 'HTTP Version Not Supported',
	[506] = 'Variant Also Negotiates',
	[507] = 'Insufficient Storage',
	[508] = 'Loop Detected',
	[509] = 'Unassigned',
	[510] = 'Not Extended',
	[511] = 'Network Authentication Required',
}

--NOTE: method must be in uppercase.
--NOTE: http_ver must be '1.0' or '1.1'
function http:send_request_line(method, uri, http_ver)
	self:send(string.format('%s %s HTTP/%s\r\n', method, uri, http_ver))
end

function http:read_request_line()
	local method, uri, http_ver =
		self:read_line():match'^([%u]+)%s+([^%s]+)%s+HTTP/(%d+%.%d+)'
	assert(method, 'invalid request line')
	return http_ver, method, uri
end

--NOTE: status must be in [100, 999] range.
--NOTE: http_ver must be '1.0' or '1.1'.
--NOTE: the message must not contain newlines.
function http:send_status_line(status, message, http_ver)
	message = message or self.status_messages[status]
	self:send(string.format('HTTP/%s %d %s\r\n', http_ver, status, message))
end

function http:read_status_line()
	local http_ver, status = self:read_line():match'^HTTP/(%d+%.%d+)%s+(%d%d%d)'
	assert(http_ver, 'invalid status line')
	return http_ver, tonumber(status)
end

--NOTE: header names are case-insensitive.
--NOTE: multiple spaces in header values are equivalent to a single space.
--NOTE: spaces around header values are ignored.
--NOTE: header names and values must not contain newlines.
function http:send_headers(headers)
	local names, values = {}, {}
	local i = 1
	for k, v in pairs(headers) do
		local v = tostring(v)
		names [i] = k
		values[k] = v
		i = i + 1
	end
	table.sort(names) --to ease debugging.
	for _,name in ipairs(names) do
		self:send(string.format('%s: %s\r\n', name, values[name]))
	end
	self:send'\r\n'
end

function http:read_headers(headers)
	local line, name, value
	line = self:read_line()
	while line ~= '' do --headers end up with a blank line
		name, value = line:match'^(.-):%s*(.*)'
		assert(name, 'invalid header')
		name = name:lower()
		line = self:read_line()
		while line:find'^%s' do --unfold any folded values
			value = value .. line
			line = self:read_line()
		end
		value = value:gsub('%s+', ' ') --LWS -> one SP
		value = value:gsub('^%s*', ''):gsub('%s*$', '') --trim
		if headers[name] then --headers can be duplicate
			headers[name] = headers[name] .. ',' .. value
		else
			headers[name] = value
		end
	end
end

function http:read_chunks(write_content)
	while true do
		local line = self:read_line()
		local size = tonumber(string.gsub(line, ';.*', ''), 16) --size[; extension]
		assert(size, 'invalid chunk size')
		if size == 0 then break end --last chunk (trailers not supported)
		self:read_exactly(size, write_content)
		self:read_line()
	end
end

function http:send_chunks(read_content)
	while true do
		local chunk, len = read_content()
		if chunk then
			local chunk, len = stream.stringdata(chunk, len)
			self:send(string.format('%X\r\n', len))
			self:send(chunk, len)
			self:send'\r\n'
		else
			self:send'0\r\n\r\n'
			break
		end
	end
end

function http:zlib_decoder(format, write)
	assert(self.zlib, 'zlib not loaded')
	local decode = coroutine.wrap(function()
		self.zlib.inflate(coroutine.yield, write, nil, format)
	end)
	decode()
	return decode
end

function http:chain_writer(write, encodings)
	if not encodings then
		return write
	end
	local enc_list = {}
	for encoding in encodings:gmatch'[^%s,]+' do
		table.insert(enc_list, encoding)
	end
	for i = #enc_list, 1, -1 do
		local encoding = enc_list[i]
		if encoding == 'identity' or encoding == 'chunked' then
			--identity does nothing, chunked would already be set.
		elseif encoding == 'gzip' or encoding == 'deflate' then
			write = self:zlib_decoder(encoding, write)
		else
			error'unsupported encoding'
		end
	end
	return write
end

function http:send_body(content, content_size, encoding)
	if encoding == 'gzip' or encoding == 'deflate' then
		assert(self.zlib, 'zlib not loaded')
		--TODO: implement
	elseif encoding then
		assert(false, 'invalid encoding')
	end
	if type(content) == 'function' then
		self:send_chunks(content)
	elseif content then
		self:send(content, content_size)
	end
end

function http:should_read_response_body(method, status)
	if method == 'HEAD' then return nil end
	if status == 204 or status == 304 then return nil end
	if status >= 100 and status < 200 then return nil end
	return true
end

function http:read_body_to_writer(headers, write, from_server)
	write = self:chain_writer(write, headers['content-encoding'])
	if headers['transfer-encoding'] == 'chunked' then
		self:read_chunks(write)
	elseif headers['content-length'] then
		local size = assert(tonumber(headers['content-length']),
			'invalid content-length')
		self:read_exactly(size, write)
	elseif from_server and headers['connection'] ~= 'keep-alive' then
		self:read_until_closed(write)
	end
end

function http:read_body(headers, write, from_server)
	if write == 'string' or write == 'buffer' then
		local write, get = stream.dynarray_writer()
		self:read_body_to_writer(headers, write, from_server)
		local buf, sz = get()
		if write == 'string' then
			return ffi.string(buf, sz)
		else
			return buf, sz
		end
	else
		self:read_body_to_writer(headers, write, from_server)
	end
end

function http:should_redirect(method, status, response_headers, nredirects)
	return response_headers.location
		and response_headers.location:gsub('%s', '') ~= ''
		and (status == 301 or status == 302 or status == 303 or status == 307)
		and (method == 'GET' or method == 'HEAD')
		and (not nredirects or nredirects < 20)
end

function http:set_content_headers(headers, content, content_size)
	if type(content) == 'string' then
		assert(not content_size, 'content_size ignored')
		headers['content-length'] = #content
	elseif type(content) == 'cdata' then
		headers['content-length'] = assert(content_size, 'content_size missing')
	elseif type(content) == 'function' then
		if content_size then
			headers['content-length'] = content_size
		else
			headers['transfer-encoding'] = 'chunked'
		end
	end
end

function http:override_headers(headers, user_headers)
	if not user_headers then return end
	for k,v in pairs(user_headers) do
		headers[k:lower()] = v or nil
	end
end

--[[
Client sets request headers:      Based on fields:
--------------------------------- --------------------------------------------
	host                           t.host, t.port.
	connection                     t.close.
	content-length                 t.content.
	transfer-encoding              t.content.
	accept-encoding                t.zlib.
	content-encoding               t.compress.
]]
function http:send_request(t)
	local headers = {}
	assert(t.host, 'host missing') --the only required field, even for HTTP/1.0.
	headers['host'] = t.host .. (t.port and ':' .. t.port or '')
	if t.close then
		headers['connection'] = 'close'
	end
	if self.zlib then
		headers['accept-encoding'] = 'gzip, deflate'
	end
	self:set_content_headers(headers, t.content, t.content_size)
	self:override_headers(headers, t.headers)
	self:send_request_line(t.method, t.uri, t.http_version or '1.1')
	self:send_headers(headers)
	local content_encoding = self.zlib
		and t.compress == true and 'gzip' or t.compress
	self:send_body(t.content, t.content_size, content_encoding)
end

--[[
Client reads from response:       In order to:
--------------------------------- --------------------------------------------
	status, method                 decide whether to read the body or not.
	transfer-encoding              read the body in chunks.
	content-encoding               decompress the body.
	content-length                 know how much to read from the socket.
	connection                     read the body in absence of content-length.
]]
function http:read_response(method, write_content)
	local http_ver, status = self:read_status_line()
	local response_headers = {}
	while status == 100 do --ignore any 100-continue messages
		self:read_headers(response_headers)
		http_ver, status = self:read_status_line()
	end
	self:read_headers(response_headers)
	local content
	if self:should_read_response_body(method, status) then
		content = self:read_body(response_headers, write_content, true)
	end
	return http_ver, status, response_headers, content
end

--[[
Server reads request headers:     In order to:
--------------------------------- --------------------------------------------
	transfer-encoding              read the body in chunks.
	content-encoding               decompress the body.
	content-length                 know how much to read from the socket.
]]
function http:read_request(write_content)
	local http_ver, method, uri = self:read_request_line()
	local request_headers = {}
	self:read_headers(request_headers)
	local content = self:read_body(request_headers, write_content)
	return http_ver, method, uri, request_headers, content
end

function http:decide_content_encoding(compress, request_headers)

	local accept = request_headers['accept-encoding']
	if not accept then return end

	local available = compress and self.zlib
		and {gzip = true, deflate = true} or {}

	for s in accept:gmatch'[^,]+' do
		local encoding, q = s:match'%s*([^%s;])%s*;%s*q%s*=%s*(.*)'
		encoding = encoding or s:match'%s*([^%s;])' or 'identity'
		encoding = encoding:lower()
		q = tonumber(q) or 1
		--TODO: *;q=0, identity;q=0, sorting by q.
		if available[encoding] and q ~= 0 then
			return encoding
		end
	end

end

--[[
Server sets response headers:     Based on:
--------------------------------- --------------------------------------------
	connection: close              t.close.
	content-length                 t.content_size or t.content's length.
	transfer-encoding: chunked     if t.content is a reader function.
	content-encoding: gzip|deflate t.compress, self.zlib, accept-encoding header.
]]
function http:send_response(t, request_headers)
	self:send_status_line(t.status, t.status_message, t.http_version or '1.1')
	local headers = {}
	if t.close then
		headers['connection'] = 'close'
	end
	self:set_content_headers(headers, t.content, t.content_size)
	self:override_headers(headers, t.headers)
	self:send_headers(headers)
	local content_encoding =
		self:decide_content_encoding(t.compress, request_headers)
	self:send_body(t.content, t.content_size, content_encoding)
end

self.zlib and (

function http:perform_request(t, write_content)
	self:send_request(t)
	return self:read_response(t.method, write_content)
end

function http:new(t)
	local self = setmetatable(t or {}, {__index = self})

	local function read(buf, sz)
		return self:read(buf, sz)
	end
	local lb = stream.linebuffer(read, '\r\n', 8192)

	function self:read_exactly(n, write)
		while n > 0 do
			local buf, sz = assert(lb.read(n))
			write(buf, sz)
			n = n - sz
		end
	end

	function self:read_line()
		return assert(lb.readline())
	end

	function self:read_until_closed(write_content)
		while true do
			local buf, sz = lb.read(1/0)
			if not buf and sz == 'closed' then return end
			assert(buf, sz)
			write_content(buf, sz)
		end
	end

	return self
end

return http
