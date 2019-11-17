
## `local http = require'http'`

HTTP 1.1 client & server protocol in Lua.

Works on an abstract I/O API made of three functions:

	* `http:read(buf, maxsz) -> sz | nil,err`
	* `http:send(s | buf,sz) -> true | nil,'closed'|err`
	* `http:close()`

GZip (de)compression can be enabled with `http.zlib = require'zlib'`.

## Status

<warn>Work-in-progress.<warn>

## API

`http:send_request(t) -> should_close`

--------------------------------- --------------------------------------------
Client sets request headers:      Based on fields:
--------------------------------- --------------------------------------------
	host                           t.host, t.port
	connection: close              t.close
	content-length                 t.content
	transfer-encoding              t.content
	accept-encoding                self.zlib
	content-encoding               t.compress
--------------------------------- --------------------------------------------

`http:read_response(method, write_content, should_close)
	-> http_ver, status, headers, content, closed`

--------------------------------- --------------------------------------------
Client reads from response:       In order to:
--------------------------------- --------------------------------------------
	status, method                 decide whether to read the body or not.
	transfer-encoding              read the body in chunks.
	content-encoding               decompress the body.
	content-length                 know how much to read from the socket.
	connection                     read the body in absence of content-length.
--------------------------------- --------------------------------------------

`http:read_request(write_content) -> http_ver, method, uri, headers, content`

--------------------------------- --------------------------------------------
Server reads request headers:     In order to:
--------------------------------- --------------------------------------------
	transfer-encoding              read the body in chunks.
	content-encoding               decompress the body.
	content-length                 know how much to read from the socket.
--------------------------------- --------------------------------------------

`http:send_response(t, request_headers)`

--------------------------------- --------------------------------------------
Server sets response headers:     Based on:
--------------------------------- --------------------------------------------
	connection: close              t.close.
	content-length                 t.content_size or t.content's length.
	transfer-encoding: chunked     if t.content is a reader function.
	content-encoding: gzip|deflate t.compress, self.zlib, accept-encoding header.
--------------------------------- --------------------------------------------
