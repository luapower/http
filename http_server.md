
## `local server = require'http_server'`

HTTP 1.1 coroutine-based async server in Lua.

Features, https, gzip compression, persistent connections, pipelining,
resource limits, multi-level debugging, cdata-buffer-based I/O.

Uses [socket2] and [libtls] for I/O and TLS or you can bring your own stack
(see `loop` option below).

GZip compression can be enabled with `client.http.zlib = require'zlib'`.

## Status

<warn>WIP<warn>

## Configuration

~~~{.lua}
local s2    = require'socket2'
local s2tls = require'socket2_libtls'
local zlib  = require'zlib'

server.tcp           = s2.tcp             --required, for I/O
server.stcp          = s2tls.server_stcp  --optional, for TLS
client.stcp_config   = s2tls.config       --optional, for TLS
server.newthread     = s2.newthread       --required, for scheduling
server.http.zlib     = zlib               --optional, for compression
~~~

## API

--------------------------------- --------------------------------------------
`server:new(opt) -> server`       create a server object
--------------------------------- --------------------------------------------

#### Server options

--------------------------------- --------------------------------------------
`listen`                          `{host=, port=, tls=t|f, tls_options=}`
`tls_options`                     options for [libtls]
--------------------------------- --------------------------------------------
