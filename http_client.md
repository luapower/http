
## `local client = require'http_client'`

HTTP 1.1 coroutine-based async client in Lua. Supports persistent connections,
pipelining, gzip compression, multiple client IPs, resource limits,
auto-redirects, auto-retries, cookie jars, multi-level debugging, caching,
cdata-buffer-based I/O.

GZip compression can be enabled with `client.http.zlib = require'zlib'`.

## Status

<warn>Work-in-progress.<warn>

## API

--------------------------------- --------------------------------------------
`client:new(opt) -> client`       create a client object
`client:request(opt) -> req, res` make a HTTP request
`client:close_all()`              close all connections
--------------------------------- --------------------------------------------

### `client:new(opt) -> client`

Create a client object. The `opt` table can contain:

--------------------------------- --------------------------------------------
`max_conn`                        limit the number of total connections
`max_conn_per_target`             limit the number of connections per _target_
`max_pipelined_requests`          limit the number of pipelined requests
`client_ips`                      a list of client IPs to assign to requests
`max_retries`                     number of retries before giving up
`max_redirects`                   number of redirects before giving up
`debug`                           `true` to enable client-level debugging
--------------------------------- --------------------------------------------

A _target_ is a combination of (vhost, port, client_ip) on which one or more
HTTP connections can be created subject to per-target limits.

#### Pipelined requests

A pipelined request is a request that is sent in advance of receiving the
response for the previous request. Most HTTP servers accept these but
in a limited number.

Spawning a new connection for a new request has a lot more initial latency
than pipelining the request on an existing connection. On the other hand,
pipelined responses come serialized and also the server might decide not
to start processing pipelined requests as soon as they arrive because it
would have to buffer the results before it can start sending them.

### `client:request(opt) -> req, res`   make a HTTP request

Make a HTTP request. This must be called from a scheduled socket thread.

The `opt` table can contain:

--------------------------------- --------------------------------------------
connection options                options to pass to `http:new()`
request options                   options to pass to `http:make_request()`
`client_ip`                       client ip to bind to (optional)
--------------------------------- --------------------------------------------

### `client:close_all()`

Close all connections. This must be called after the socket loop finishes.
