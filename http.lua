
-- HTTP/1.1 client & server protocol in Lua.
-- Written by Cosmin Apreutesei. Public Domain.

if not ... then require'http_test'; return end

local url = require'url'
local b64 = require'libb64'
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

function http:read_content(size, write_content)
	local buf, sz = self:read(size)
	write_content(ffi.string(buf, sz))
end

function http:send_request_line(method, uri, http_ver)
	assert(method == method:upper())
	self:send(string.format('%s %s HTTP/%s\r\n', method, uri, http_ver))
end

function http:read_request_line()
	local method, uri, http_ver =
		self:read_line():match'^([^%s]+)%s+([^%s]+)%s+HTTP/(%d+%.%d+)'
	assert(method, 'invalid request line')
	assert(http_ver == '1.1' or http_ver== '1.0', 'invalid http version')
	return method, uri, http_ver
end

function http:send_status_line(status, message, http_ver)
	status = tostring(status)
	message = message or self.status_messages[status] or ''
	self:send(string.format('HTTP/%s %s %s\r\n', http_ver, status, message))
end

function http:read_status_line()
	local http_ver, status = self:read_line():match'^HTTP/(%d+%.%d+)%s+(%d%d%d)'
	return assert(tonumber(status), 'invalid status line'), http_ver
end

function http:send_headers(headers)
	local names, values = {}, {}
	local i = 1
	for k, v in pairs(headers) do
		v = v:gsub('%s+', ' ') --LWS -> one SP
		v = v:gsub('^%s*', ''):gsub('%s*$', '') --trim
		names [i] = k
		values[k] = v
		i = i + 1
	end
	table.sort(names)
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
		if headers[name] then --headers can be duplicate
			headers[name] = headers[name] .. ', ' .. value
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
		self:read_content(size, write_content)
		self:read_line()
	end
end

function http:send_chunks(read_content)
	while true do
		local chunk = read_content()
		if chunk then
			local size = string.format('%X\r\n', #chunk)
			self:send(size ..  chunk .. '\r\n')
		else
			self:send'0\r\n\r\n'
			break
		end
	end
end

function http:send_body(content)
	if type(content) == 'string' then
		self:send(content)
	elseif type(content) == 'cdata' then
		self:send(content, content_size)
	elseif type(content) == 'table' then
		--TODO: www-urlencoded
	elseif type(content) == 'function' then
		self:send_chunks(content)
	end
end

function http:read_body(headers, write_content)
	local te = headers['transfer-encoding']
	if te and te ~= 'identity' then
		self:read_chunks(write_content)
	else
		local size = tonumber(headers['content-length'])
		if size then
			self:read_content(size, write_content)
		end
	end
end

function http:should_redirect(method, status, headers, nredirects)
	return headers.location
		and headers.location:gsub('%s', '') ~= ''
		and (status == 301 or status == 302 or status == 303 or status == 307)
		and (method == 'GET' or method == 'HEAD')
		and (not nredirects or nredirects < 20)
end

function http:should_read_body(method, status)
	if method == 'HEAD' then return nil end
	if status == 204 or status == 304 then return nil end
	if status >= 100 and status < 200 then return nil end
	return true
end

function http:set_content_headers(t)
	if type(t.content) == 'string' then
		assert(not t.content_size, 'content_size ignored')
		headers['content-length'] = #content
	elseif type(t.content) == 'cdata' then
		headers['content-length'] = assert(t.content_size, 'content_size missing')
	elseif type(t.content) == 'table' then
		headers['content-type'] = 'application/x-www-form-urlencoded'
	end
	return t.content, t.content_size
end

function http:override_headers(headers, user_headers)
	if not user_headers then return end
	for k,v in pairs(user_headers) do
		headers[k:lower()] = v or nil
	end
end

--[[

Sets headers:                     Based on:
--------------------------------- --------------------------------------------
	user-agent                     headers['user-agent']
	content-length                 content
	host                           host
	authorization                  user, password

]]
function http:send_request(t)
	local headers = {}
	headers['user-agent'] = 'http.lua'
	local content, content_size = self:set_content_headers(t)
	headers['host'] = t.host .. (t.port and ':' .. t.port or '')
	headers['connection'] = t.close and 'close' or 'keep-alive'
	if t.user and t.password then
		headers['authorization'] = 'Basic '
			.. (b64.encode(t.user .. ':' .. t.password))
	end
	self:override_headers(headers, t.headers)
	self:send_request_line(t.method or 'GET', t.uri, t.http_version or '1.1')
	self:send_headers(headers)
	self:send_body(content, content_size)
end

--[[

Parses headers:                   To do what:
--------------------------------- --------------------------------------------

	transfer-encoding
	content-length

]]
function http:read_reply(method, write_content)
	local status = self:read_status_line()
	local headers = {}
	while status == 100 do --ignore any 100-continue messages
		self:read_headers(headers)
		status = self:read_status_line()
	end
	self:read_headers(headers)
	if self:should_read_body(method, status) then
		self:read_body(headers, write_content)
	end
	return status, headers
end

function http:read_request(t, write_content)
	local method, uri, http_ver = self:read_request_line()
	local headers = {}
	self:read_headers(headers)
	self:read_body(headers, write_content)
	return method, uri
end

function http:send_reply(t)
	self:send_status_line(t.status, t.status_message, t.http_version)
	local headers = {}
	local content, content_size = self:set_content_headers(t)
	self:override_headers(headers, t.headers)
	self:send_headers(t.headers)
	self:send_body(content, content_size)
end

function http:perform_request(t, write_content)
	self:send_request(t)
	local method = t.method or 'GET'
	return self:read_reply(method, write_content)
end

function http:new(t)
	local self = setmetatable(t or {}, {__index = self})

	local function read(sz)
		return self:read(sz)
	end
	local write, flush = stream.dynarray_writer()
	local read_line = stream.line_reader(read, write, true)

	function self:read_line()
		assert(read_line())
		return flush()
	end

	return self
end

return http
