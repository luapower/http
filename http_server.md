
## `local server = require'http_server'`

HTTP 1.1 coroutine-based async server in Lua.

Features, https, gzip compression, persistent connections, pipelining,
resource limits, multi-level debugging, cdata-buffer-based I/O.

Uses [socket2] and [libtls] for I/O and TLS or you can bring your own stack
(see `loop` option below).

GZip compression can be enabled with `client.http.zlib = require'zlib'`.

## Status

<warn>WIP<warn>

## API

--------------------------------- --------------------------------------------
`server:new(opt) -> server`       create a server object
--------------------------------- --------------------------------------------

