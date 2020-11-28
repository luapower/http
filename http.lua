
-- HTTP 1.1 client & server protocol in Lua.
-- Written by Cosmin Apreutesei. Public Domain.

if not ... then require'http_server_test'; return end

local time = require'time'
local glue = require'glue'
local stream = require'stream'
local http_headers = require'http_headers'
local ffi = require'ffi'
local _ = string.format

local http = {type = 'http_connection', dbg = glue.noop}

--error handling -------------------------------------------------------------

--raise protocol errors with check() instead of assert() or error() which
--makes functions wrapped with http:protect() return nil,err for those errors.

--we distinguish between invalid usage (bugs on this side, which raise),
--protocol errors (bugs on the other side which don't raise) and I/O errors
--(network failures which can be temporary, making the call retriable).

local error_class = {
	protocol = {id = 'protocol_error'},
	io = {id = 'io_error'},
}

local function checker(error_class, v, err)
	return function(v, err)
		if v then return v end
		error(setmetatable({
				message = err,
				traceback = debug.traceback(err and '\n'..err or ''),
			}, error_class))
	end
end
local check = checker(error_class.protocol)
local check_io = checker(error_class.io)

local function catch(err)
	if type(err) == 'string' then
		return debug.traceback('\n'..err)
	else
		return err
	end
end
local function pass(self, ok, ...)
	if ok then return ... end
	self:close()
	local err = ...
	local error_class = getmetatable(err)
	if error_class and error_class.id then
		return nil, err.message or err.traceback or error_class.id, error_class.id --, err.traceback
	else
		error(err, 2)
	end
end
function http:protect(method)
	local f = self[method]
	self[method] = function(self, ...)
		return pass(self, xpcall(f, catch, self, ...))
	end
end

--low-level I/O API ----------------------------------------------------------

function http:send(buf, sz)
	local left = sz or #buf
	while left > 0 do
		left = left - check_io(self.tcp:send(buf, sz, self.send_expires))
	end
end

function http:close()
	if self.closed then return end
	self.tcp:close()
	self.closed = true
end

--linebuffer-based read API --------------------------------------------------

function http:read_exactly(n, write)
	local read = self.linebuffer.read
	local n0 = n
	while n > 0 do
		local buf, sz = read(n)
		check_io(buf, sz)
		write(buf, sz)
		n = n - sz
	end
end

function http:read_line()
	return check_io(self.linebuffer.readline())
end

function http:read_until_closed(write_content)
	local read = self.linebuffer.read
	while true do
		local buf, sz = read(1/0)
		if not buf then
			if sz == 'closed' then return end
			check_io(nil, sz)
		end
		write_content(buf, sz)
	end
end

http.max_line_size = 8192

function http:create_linebuffer()
	local function read(buf, sz)
		return self.tcp:recv(buf, sz, self.read_expires)
	end
	self.linebuffer = stream.linebuffer(read, '\r\n', self.max_line_size)
end

--request line & status line -------------------------------------------------

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

function http:send_request_line(method, uri, http_version)
	assert(http_version == '1.1' or http_version == '1.0')
	assert(method and method == method:upper())
	assert(uri)
	self:dbg('=>', '%s %s HTTP/%s', method, uri, http_version)
	self:send(_('%s %s HTTP/%s\r\n', method, uri, http_version))
	return true
end

function http:read_request_line()
	local method, uri, http_version =
		self:read_line():match'^([%u]+)%s+([^%s]+)%s+HTTP/(%d+%.%d+)'
	self:dbg('<-', '%s %s HTTP/%s', method, uri, http_version)
	check(method, 'invalid request line')
	return http_version, method, uri
end

function http:send_status_line(status, message, http_version)
	message = message
		and message:gsub('[\r?\n]', ' ')
		or self.status_messages[status] or ''
	assert(status and status >= 100 and status <= 999, 'invalid status code')
	assert(http_version == '1.1' or http_version == '1.0')
	local s = _('HTTP/%s %d %s\r\n', http_version, status, message)
	self:dbg('=>', '%s %s %s', status, message, http_version)
	self:send(s)
end

function http:read_status_line()
	local line = self:read_line()
	local http_version, status, status_message
		= line:match'^HTTP/(%d+%.%d+)%s+(%d%d%d)%s*(.*)'
	self:dbg('<=', '%s %s %s', status, status_message, http_version)
	status = tonumber(status)
	check(http_version and status, 'invalid status line')
	return http_version, status, status_message
end

--headers --------------------------------------------------------------------

function http:format_header(k, v)
	return http_headers.format_header(k, v)
end

function http:parsed_headers(rawheaders)
	return http_headers.parsed_headers(rawheaders)
end

--special value to have a header removed because `false` might be a valid value.
http.remove = {}

--header names are case-insensitive.
--multiple spaces in header values are equivalent to a single space.
--spaces around header values are ignored.
--header names and values must not contain newlines.
--passing a table as value will generate duplicate headers for each value
--  (set-cookie will come like that because it's not safe to send it folded).
function http:send_headers(headers)
	for k, v in glue.sortedpairs(headers) do
		if v ~= http.remove then
			k, v = self:format_header(k, v)
			if v then
				if type(v) == 'table' then --must be sent unfolded.
					for i,v in ipairs(v) do
						self:dbg('->', '%-19s %s', v)
						self:send(_('%s: %s\r\n', k, v))
					end
				else
					self:dbg('->', '%-17s %s', k, v)
					self:send(_('%s: %s\r\n', k, v))
				end
			end
		end
	end
	self:send'\r\n'
end

function http:read_headers(rawheaders)
	local line, name, value
	line = self:read_line()
	while line ~= '' do --headers end up with a blank line
		name, value = line:match'^([^:]+):%s*(.*)'
		check(name, 'invalid header')
		name = name:lower() --header names are case-insensitive
		line = self:read_line()
		while line:find'^%s' do --unfold any folded values
			value = value .. line
			line = self:read_line()
		end
		value = value:gsub('%s+', ' ') --multiple spaces equal one space.
		value = value:gsub('%s*$', '') --around-spaces are meaningless.
		self:dbg('<-', '%-17s %s', name, value)
		if http_headers.nofold[name] then --prevent folding.
			if rawheaders[name] then --duplicate header: add to list.
				table.insert(rawheaders[name], value)
			else
				rawheaders[name] = {value}
			end
		else
			if rawheaders[name] then --duplicate header: fold.
				rawheaders[name] = rawheaders[name] .. ',' .. value
			else
				rawheaders[name] = value
			end
		end
	end
end

--body -----------------------------------------------------------------------

function http:set_body_headers(headers, content, content_size, close)
	if type(content) == 'string' then
		assert(not content_size, 'content_size would be ignored')
		headers['content-length'] = #content
	elseif type(content) == 'cdata' then
		headers['content-length'] = assert(content_size, 'content_size missing')
	elseif type(content) == 'function' then
		if content_size then
			headers['content-length'] = content_size
		elseif not close then
			headers['transfer-encoding'] = 'chunked'
		end
	end
end

function http:read_chunks(write_content)
	local total = 0
	local chunk_num = 0
	while true do
		chunk_num = chunk_num + 1
		local line = self:read_line()
		local len = tonumber(string.gsub(line, ';.*', ''), 16) --len[; extension]
		check(len, 'invalid chunk size')
		total = total + len
		self:dbg('<<', '%7d bytes; chunk %d', len, chunk_num)
		if len == 0 then --last chunk (trailers not supported)
			self:read_line()
			break
		end
		self:read_exactly(len, write_content)
		self:read_line()
	end
	self:dbg('<<', '%7d bytes in %d chunks', total, chunk_num)
end

function http:send_chunked(read_content)
	local total = 0
	local chunk_num = 0
	while true do
		chunk_num = chunk_num + 1
		local chunk, len = read_content()
		if chunk then
			local len = len or #chunk
			total = total + len
			self:dbg('>>', '%7d bytes; chunk %d', len, chunk_num)
			self:send(_('%X\r\n', len))
			self:send(chunk, len)
			self:send'\r\n'
		else
			seld:dbg('>>', '%7d bytes; chunk %d', 0, chunk_num)
			self:send'0\r\n\r\n'
			break
		end
	end
	self:dbg('>>', '%7d bytes in %d chunks', total, chunk_num)
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
		return self.zlib.deflate(content, '', nil, format)
	elseif type(content) == 'cdata' then
		--TODO: avoid string creation
		return self.zlib.deflate(ffi.string(content, content_size), '', nil, format)
	else
		return coroutine.wrap(function()
			--TODO: avoid string creation
			self.zlib.deflate(content, coroutine.yield, nil, format)
		end)
	end
end

function http:send_body(content, content_size, transfer_encoding)
	if not content then
		self:dbg('  ', '')
		return
	end
	if transfer_encoding == 'chunked' then
		self:send_chunked(content)
	else
		assert(not transfer_encoding, 'invalid transfer-encoding')
		if type(content) == 'function' then
			local total = 0
			while true do
				local chunk, len = content()
				if not chunk then break end
				local len = len or #chunk
				total = total + len
				seld:dbg('>>', '%7d bytes total', len)
				self:send(chunk, len)
			end
			self:dbg('>>', '%7d bytes total', total)
		else
			local len = content_size or #content
			self:dbg('>>', '%7d bytes', len)
			self:send(content, content_size)
		end
	end
	self:dbg('  ', '')
end

local function null_write() end

function http:read_body_to_writer(headers, write, from_server, close_connection)
	write = write and self:chained_decoder(write, headers['content-encoding'])
		or null_write
	local te = headers['transfer-encoding']
	if te and te[#te] == 'chunked' then
		self:read_chunks(write)
	elseif headers['content-length'] then
		local len = headers['content-length']
		self:dbg('<<', '%7d bytes total', len)
		self:read_exactly(len, write)
	elseif from_server and close_connection then
		self:dbg('<<', '?? bytes (reading until closed)')
		self:read_until_closed(write)
	end
end

function http:read_body(headers, write, ...)
	if write == 'string' or write == 'buffer' then
		local to_string = write == 'string'
		local write, get = stream.dynarray_writer()
		self:read_body_to_writer(headers, write, ...)
		local buf, sz = get()
		if to_string then
			return ffi.string(buf, sz)
		else
			return buf, sz
		end
	else
		self:read_body_to_writer(headers, write, ...)
	end
end

--client-side ----------------------------------------------------------------

function http:make_request(t, cookies)
	local req = {http = self, type = 'http_request'}

	req.http_version = t.http_version or '1.1'
	req.method = t.method or 'GET'
	req.uri = t.uri or '/'

	req.headers = {}

	assert(t.host, 'host missing') --required, even for HTTP/1.0.
	local default_port = self.https and 443 or 80
	local port = self.port ~= default_port and self.port or nil
	req.headers['host'] = {host = t.host, port = port}

	req.close = t.close or req.http_version == '1.0'
	if req.close then
		req.headers['connection'] = 'close'
	end

	if self.zlib then
		req.headers['accept-encoding'] = 'gzip, deflate'
	end

	req.headers['cookie'] = cookies

	req.content, req.content_size = t.content, t.content_size
	if req.content and self.zlib and t.compress ~= false then
		req.headers['content-encoding'] = 'gzip'
		req.content, req.content_size =
			self:encode_content(req.content, req.content_size, 'gzip')
	end

	self:set_body_headers(req.headers, req.content, req.content_size, req.close)
	glue.update(req.headers, t.headers)

	req.receive_content = t.receive_content
	req.request_timeout = t.request_timeout
	req.reply_timeout   = t.reply_timeout

	return req
end

function http:send_request(req)
	local dt = req.request_timeout
	self.send_expires = dt and time.clock() + dt or nil
	self:send_request_line(req.method, req.uri, req.http_version)
	self:send_headers(req.headers)
	self:send_body(req.content, req.content_size, req.headers['transfer-encoding'])
	return true
end
http:protect'send_request'

function http:should_have_response_body(method, status)
	if method == 'HEAD' then return nil end
	if status == 204 or status == 304 then return nil end
	if status >= 100 and status < 200 then return nil end
	return true
end

function http:should_redirect(req, res)
	local method, status = req.method, res.status
	return res.headers['location']
		and (status == 301 or status == 302 or status == 303 or status == 307)
end

local function is_ip(s)
	return s:find'^%d+%.%d+%.%d+%.%d+'
end

function http:cookie_default_path(req_uri)
	return '/' --TODO
end

--either cookie domain matches host exactly or domain is a suffix
--    - The domain string is a suffix of the string.
--	  - The last character of the string that is not included in the domain string
--	    is a %x2E (".") character.
--a host name (i.e., not an IP address).
function http:cookie_domain_matches_request_host(domain, host)
	return not domain or domain == host or (
		host:sub(-#domain) == domain
		and host:sub(-#domain-1, -#domain-1) == '.'
		and not is_ip(host)
	)
end

--cookie path matches request path exactly, or
--cookie path ends in `/` and is a prefix of the request path, or
--cookie path is a prefix of the request path, and the first
--character of the request path that is not included in the cookie path is `/`.
function http:cookie_path_matches_request_path(cpath, rpath)
	if cpath == rpath then
		return true
	elseif cpath == rpath:sub(1, #cpath) then
		if cpath:sub(-1, -1) == '/' then
			return true
		elseif rpath:sub(#cpath + 1, #cpath + 1) == '/' then
			return true
		end
	end
	return false
end

--NOTE: cookies are not port-specific nor protocol-specific.
function http:should_send_cookie(cookie, host, path, https)
	return (https or not cookie.secure)
		and self:cookie_domain_matches_request_host(cookie, host)
		and self:cookie_path_matches_request_path(cookie, path)
end

function http:read_response(req)
	local res = {}
	res.rawheaders = {}

	local dt = req.reply_timeout
	self.read_expires = dt and time.clock() + dt or nil

	res.http_version, res.status = self:read_status_line()

	while res.status == 100 do --ignore any 100-continue messages
		self:read_headers(res.rawheaders)
		res.http_version, res.status = self:read_status_line()
	end

	self:read_headers(res.rawheaders)
	res.headers = self:parsed_headers(res.rawheaders)

	res.close =
		(res.headers['connection'] and res.headers['connection'].close)
		or res.http_version == '1.0'

	local receive_content = req.receive_content
	if self:should_redirect(req, res) then
		receive_content = nil --ignore the body
		res.redirect_location = check(res.headers['location'], 'no location')
		res.receive_content = req.receive_content
	end

	if not self:should_have_response_body(req.method, res.status) then
		receive_content = nil --ignore the body
	end

	res.content, res.content_size =
		self:read_body(res.headers, receive_content, true, res.close)

	if req.close or res.close then
		self:close()
	end

	return res
end
http:protect'read_response'

--server side ----------------------------------------------------------------

function http:read_request(receive_content)
	local req = {}
	req.http_version, req.method, req.uri = self:read_request_line()
	req.rawheaders = {}
	self:read_headers(req.rawheaders)
	req.headers = self:parsed_headers(req.rawheaders)
	req.close = req.headers['connection'] and req.headers['connection'].close
	req.content, req.content_size = self:read_body(req.headers, receive_content)
	return req
end
http:protect'read_request'

local function content_size(opt)
	return type(opt.content) == 'string' and #opt.content
		or opt.content_size
end

local function no_body(res, status)
	res.status = status
	res.content, res.content_size = ''
end

local function q0(t)
	return type(t) == 'table' and t.q == 0
end

function http:accept_content_encoding(req, opt)
	local compress = opt.compress ~= false and self.zlib
		and (content_size(opt) or 0) >= 1000
	local accept = req.headers['accept-encoding']
	if accept then
		if compress and not q0(accept.gzip) then return true, 'gzip' end
		if compress and not q0(accept.deflate) then return true, 'deflate' end
	end
	return true
end

function http:encode_content(content, content_size, content_encoding)
	if content_encoding == 'gzip' or content_encoding == 'deflate' then
		content, content_size =
			self:zlib_encoder(content_encoding, content, content_size)
	else
		assert(not content_encoding, 'invalid content-encoding')
	end
	return content, content_size
end

function http:allow_method(req, opt)
	local allowed_methods = opt.allowed_methods
	return not allowed_methods or allowed_methods[req.method], allowed_methods
end

function http:accept_content_type(req, opt)
	return true, opt.content_type
end

function http:make_response(req, opt, utc_time)
	local res = {http = self, request = req, type = 'http_response'}
	res.headers = {}

	res.http_version = opt.http_version or req.http_version

	res.close = opt.close or req.close
	if res.close then
		res.headers['connection'] = 'close'
	end

	if opt.status then
		res.status = opt.status
		res.status_message = opt.status_message
	else
		res.status = 200
	end

	local allow, methods = self:allow_method(req, opt)
	if not allow then
		res.headers['allow'] = methods
		no_body(res, 405) --method not allowed
		return res
	end

	local accept, content_encoding = self:accept_content_encoding(req, opt)
	if not accept then
		no_body(res, 406) --not acceptable
		return res
	else
		res.headers['content-encoding'] = content_encoding
	end

	local accept, content_type = self:accept_content_type(req, opt)
	if not accept then
		no_body(res, 406) --not acceptable
		return res
	else
		res.headers['content-type'] = content_type
	end

	res.content, res.content_size =
		self:encode_content(opt.content, opt.content_size, content_encoding)

	res.headers['date'] = utc_time

	self:set_body_headers(res.headers, res.content, res.content_size, res.close)
	glue.update(res.headers, opt.headers)

	return res
end

function http:send_response(res)
	self:send_status_line(res.status, res.status_message, res.http_version)
	self:send_headers(res.headers)
	self:send_body(res.content, res.content_size, res.headers['transfer-encoding'])
	if res.close then
		self:close()
	end
	return true
end
http:protect'send_response'

--instantiation --------------------------------------------------------------

function http:new(t)
	local self = glue.object(self, {}, t)
	if self.debug then
		local dbg = require'http_debug'
		dbg:install_to_http(self)
	end
	self:create_linebuffer()
	return self
end

return http
