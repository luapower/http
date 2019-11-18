
-- HTTP 1.1 client & server protocol in Lua.
-- Written by Cosmin Apreutesei. Public Domain.

if not ... then require'http_test'; return end

local glue = require'glue'
local stream = require'stream'
local http_headers = require'http_headers'
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

--NOTE: http_version must be '1.0' or '1.1'
function http:send_request_line(method, uri, http_version)
	assert(http_version == '1.1' or http_version == '1.0')
	assert(method and method == method:upper())
	assert(uri)
	self:send(string.format('%s %s HTTP/%s\r\n', method, uri, http_version))
end

function http:read_request_line()
	local method, uri, http_version =
		self:read_line():match'^([%u]+)%s+([^%s]+)%s+HTTP/(%d+%.%d+)'
	assert(method, 'invalid request line')
	return http_version, method, uri
end

--NOTE: http_version must be '1.0' or '1.1'.
--NOTE: the message must not contain newlines.
function http:send_status_line(status, message, http_version)
	message = message or self.status_messages[status] or ''
	assert(status and status >= 100 and status <= 999, 'invalid status code')
	assert(http_version == '1.1' or http_version == '1.0')
	self:send(string.format('HTTP/%s %d %s\r\n', http_version, status, message))
end

function http:read_status_line()
	local http_version, status = self:read_line():match'^HTTP/(%d+%.%d+)%s+(%d%d%d)'
	status = tonumber(status)
	assert(http_version and status, 'invalid status line')
	return http_version, status
end

function http:format_header(k, v)
	return http_headers.format_header(k, v)
end

--header names are case-insensitive.
--multiple spaces in header values are equivalent to a single space.
--spaces around header values are ignored.
--header names and values must not contain newlines.
--passing a table as value will generate duplicate headers for each value
--  (set-cookie will come like that because it's not safe to send it folded).
function http:send_headers(headers)
	local names, values = {}, {}
	local i = 1
	for k, v in pairs(headers) do
		k, v = self:format_header(k, v)
		names [i] = k
		values[k] = v
		i = i + 1
	end
	table.sort(names) --to ease debugging.
	for _,name in ipairs(names) do
		local v = values[name]
		if type(v) == 'table' then --must be sent unfolded.
			for i,v in ipairs(v) do
				self:send(string.format('%s: %s\r\n', name, v))
			end
		else
			self:send(string.format('%s: %s\r\n', name, v))
		end
	end
	self:send'\r\n'
end

function http:read_headers(rawheaders)
	local line, name, value
	line = self:read_line()
	while line ~= '' do --headers end up with a blank line
		name, value = line:match'^([^:]+):%s*(.*)'
		assert(name, 'invalid header')
		name = name:lower() --header names are case-insensitive
		line = self:read_line()
		while line:find'^%s' do --unfold any folded values
			value = value .. line
			line = self:read_line()
		end
		value = value:gsub('%s+', ' ') --multiple spaces equal one space.
		value = value:gsub('%s*$', '') --around-spaces are meaningless.
		if rawheaders[name] then --headers can be duplicate.
			rawheaders[name] = rawheaders[name] .. ',' .. value
		else
			rawheaders[name] = value
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

function http:send_chunked(read_content)
	while true do
		local chunk, len = read_content()
		if chunk then
			self:send(string.format('%X\r\n', len or #chunk))
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

function http:chained_decoder(write, encodings)
	if encodings then
		for i = #encodings, 1, -1 do
			local encoding = encodings[i]
			if encoding == 'identity' or encoding == 'chunked' then
				--identity does nothing, chunked would already be set.
			elseif encoding == 'gzip' or encoding == 'deflate' then
				write = self:zlib_decoder(encoding, write)
			else
				error'unsupported encoding'
			end
		end
	end
	return write
end

function http:zlib_encoder(format, content, content_size)
	assert(self.zlib, 'zlib not loaded')
	if type(content) == 'string' then
		return zlib.deflate(content, '', nil, format)
	elseif type(content) == 'cdata' then
		return zlib.deflate(ffi.string(content, content_size), '', nil, format)
	else
		return coroutine.wrap(function()
			self.zlib.deflate(content, coroutine.yield, nil, format)
		end)
	end
end

function http:send_body(content, content_size, encoding, chunked)
	if encoding == 'gzip' or encoding == 'deflate' then
		content, content_size = self:zlib_encoder(encoding, content, content_size)
	elseif encoding ~= 'identity' then
		assert(false, 'invalid encoding')
	end
	if chunked then
		self:send_chunked(content)
	elseif type(content) == 'function' then
		while true do
			local chunk, len = content()
			if not chunk then break end
			self:send(chunk, len)
		end
	else
		self:send(content, content_size)
	end
end

function http:should_have_response_body(method, status)
	if method == 'HEAD' then return nil end
	if status == 204 or status == 304 then return nil end
	if status >= 100 and status < 200 then return nil end
	return true
end

local function null_writer() end

function http:read_body_to_writer(headers, write, from_server, close_connection)
	if not write then
		write = null_writer
	end
	write = self:chained_decoder(write, headers['content-encoding'])
	local te = headers['transfer-encoding']
	if te and te.chunked then
		self:read_chunks(write)
	elseif headers['content-length'] then
		self:read_exactly(headers['content-length'], write)
	elseif from_server and close_connection then
		self:read_until_closed(write)
	end
end

function http:read_body(headers, write, ...)
	if write == 'string' or write == 'buffer' then
		local write, get = stream.dynarray_writer()
		self:read_body_to_writer(headers, write, ...)
		local buf, sz = get()
		if write == 'string' then
			return ffi.string(buf, sz)
		else
			return buf, sz
		end
	else
		self:read_body_to_writer(headers, write, ...)
	end
end

function http:should_redirect(method, status, response_headers, nredirects)
	return response_headers['location']
		and response_headers['location']:gsub('%s', '') ~= ''
		and (status == 301 or status == 302 or status == 303 or status == 307)
		and (method == 'GET' or method == 'HEAD')
		and (not nredirects or nredirects < 20)
end

function http:set_content_headers(headers, content, content_size, close_connection)
	if type(content) == 'string' then
		assert(not content_size, 'content_size ignored')
		headers['content-length'] = #content
	elseif type(content) == 'cdata' then
		headers['content-length'] = assert(content_size, 'content_size missing')
	elseif type(content) == 'function' then
		if content_size then
			headers['content-length'] = content_size
		elseif not close_connection then
			headers['transfer-encoding'] = 'chunked'
			return true
		end
	end
end

function http:override_headers(headers, user_headers)
	if user_headers then
		for k,v in pairs(user_headers) do
			headers[k] = v
		end
	end
end

function http:send_request(t)
	local http_version = t.http_version or '1.1'
	local headers = {}
	assert(t.host, 'host missing') --the only required field, even for HTTP/1.0.
	headers['host'] = {host = t.host, port = t.port}
	local close = t.close or http_version == '1.0'
	if close then
		headers['connection'] = 'close'
	end
	if self.zlib then
		headers['accept-encoding'] = 'gzip, deflate'
	end
	local chunked = self:set_content_headers(
		headers, t.content, t.content_size, close)
	self:override_headers(headers, t.headers)
	self:send_request_line(t.method, t.uri, http_version)
	self:send_headers(headers)
	local content_encoding = self.zlib and t.compress == true and 'gzip'
		or t.compress or 'identity'
	if t.content then
		self:send_body(t.content, t.content_size, content_encoding, chunked)
	end
	return close
end

function http:parsed_headers(rawheaders)
	return http_headers.parsed_headers(rawheaders)
end

function http:read_response(method, write_content, close)
	local http_version, status = self:read_status_line()
	local rawheaders = {}
	while status == 100 do --ignore any 100-continue messages
		self:read_headers(rawheaders)
		http_version, status = self:read_status_line()
	end
	self:read_headers(rawheaders)
	local headers = self:parsed_headers(rawheaders)
	close = close or headers['connection'].close or http_version == '1.0'
	if not self:should_have_response_body(method, status) then
		write_content = nil --ignore it
	end
	local content = self:read_body(headers, write_content, true, close)
	if close then
		self:close()
	end
	return http_version, status, headers, content, close, rawheaders
end

function http:perform_request(t, write_content)
	local close = self:send_request(t)
	return self:read_response(t.method, write_content, close)
end

function http:read_request(write_content)
	local http_version, method, uri = self:read_request_line()
	local rawheaders = {}
	self:read_headers(rawheaders)
	local headers = self:parsed_headers(rawheaders)
	local content = self:read_body(headers, write_content)
	self.request = {
		http_version = http_version,
		method = method,
		uri = uri,
		headers = headers,
		content = content,
		rawheaders = rawheaders,
	}
	return self.request
end

local zlib_encodings = {gzip = true, deflate = true}
local default_encodings = {}

function http:negotiate_content_encoding(compress)
	local accept = self.request.headers['accept-encoding']
	if not accept then
		return 'identity'
	end

	local available = compress and self.zlib
		and zlib_encodings or default_encodings

	local function cmp_qs(enc1, enc2)
		return
			(accept[enc1].q or 1) <
			(accept[enc2].q or 1)
	end
	local allow_identity = true
	for encoding, params in glue.sortedpairs(accept, cmp_qs) do
		local q = params.q or 1
		if q > 0 then
			if available[encoding] then
				return encoding
			end
		elseif encoding == 'identity' or encoding == '*' then
			allow_identity = false
		end
	end
	return allow_identity and 'identity' or nil
end

function http:negotiate_content_type(default, available)
	local accept = self.request.headers['accept']
	if not accept then
		return default
	end
	local function cmp_qs(mt1, mt2)
		return accept[mt1] < accept[mt2]
	end
	local function cmp_qs(enc1, enc2)
		return
			(accept[enc1].q or 1) <
			(accept[enc2].q or 1)
	end
	local function accepts(wildcard, mediatype)
		if type(mediatype) == 'table' then
			for mediatype in pairs(mediatype) do
				if accepts(wildcard, mediatype) then
					return mediatype
				end
			end
		elseif wildcard == '*/*' then
			return mediatype
		elseif wildcard:find'/%*$' then
			return mediatype:match'^[^/]+' == wildcard:match'^[^/]+'
		else
			return wildcard == mediatype
		end
	end
	for wildcard, params in glue.sortedpairs(accept, cmp_qs) do
		if (params.q or 1) > 0 then
			if accepts(wildcard, default) then
				return default
			elseif available and accepts(wildcard, available) then
				return default
			end
		end
	end
end

function http:send_response(t)
	assert(self.request, 'request not read')

	local headers = {}

	local http_version = t.http_version or self.request.http_version
	local status, status_message

	local close = t.close or self.request.headers['connection'].close
	if close then
		headers['connection'] = 'close'
	end

	if t.allowed_methods and not t.allowed_methods[self.request.method] then
		headers['allow'] = t.allowed_methods
		status = 405 --method not allowed
	end

	local content_type
	if not status then
		content_type = self:negotiate_content_type(
			t.content_type, t.content_types)
		if not content_type then
			status = 406 --not acceptable
		else
			headers['content-type'] = content_type
		end
	end

	local content_encoding
	if not status then
		content_encoding = self:negotiate_content_encoding(t.compress)
		if not content_encoding then
			status = 406 --not acceptable
		elseif content_encoding ~= 'identity' then
			headers['content-encoding'] = content_encoding
		end
	end

	local chunked
	if not status then
		headers['date'] = os.time()
		chunked = self:set_content_headers(
			headers, t.content, t.content_size, close)
		self:override_headers(headers, t.headers)
	end

	local content = t.content
	if status then
		content = nil
	end
	status_message = not status and t.status_message or nil
	status = status or t.status or 200

	self:send_status_line(status, status_message, http_version)
	self:send_headers(headers)
	if content then
		self:send_body(content, t.content_size, content_encoding, chunked)
	end

	if close then
		self:close()
	end

	self.request = nil
	return status
end

--low-level API to implement

function http:close()           error'not implemented' end
function http:read (buf, maxsz) error'not implemented' end
function http:send (buf, sz)    error'not implemented' end

--linebuffer-based read API

function http:read_exactly(n, write)
	local read = self.linebuffer.read
	while n > 0 do
		local buf, sz = read(n)
		assert(buf, 'short read')
		write(buf, sz)
		n = n - sz
	end
end

function http:read_line()
	return assert(self.linebuffer.readline())
end

function http:read_until_closed(write_content)
	local read = self.linebuffer.read
	while true do
		local buf, sz = read(1/0)
		if not buf and sz == 'closed' then return end
		assert(buf, sz)
		write_content(buf, sz)
	end
end

--instantiation

function http:new(t)
	local self = setmetatable(t or {}, {__index = self})
	local function read(buf, sz)
		return self:read(buf, sz)
	end
	self.linebuffer = stream.linebuffer(read, '\r\n', 8192)
	return self
end

return http
