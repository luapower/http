
## `local client = require'http_client'`

HTTP 1.1 coroutine-based async client in Lua. Supports persistent connections,
pipelining, gzip compression, multiple client IPs, resource limits,
auto-redirects, auto-retries, cookie jars, multi-level debugging, caching,
cdata-buffer-based I/O.

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

A _target_ is a combination of (host, port, client_ip) on which one or more
HTTP connections can be created subject to per-target limits.

#### Pipelined requests

A pipelined request is a request that is sent in advance of receiving the
response for the previous request. Most HTTP servers accept these but
in a limited number.

Spawning a new connection for a new request has a lot more initial latency
than pipelining the request on an existing connection. On the other hand,
the responses arrive serialized which may not be desirable depending on the
application. Even so, the server could still in theory process the requests
in parallel even though it has to wait before it can send in the results.

### `client:request(opt) -> req, res`   make a HTTP request

Make a HTTP request. This must be called from a scheduled socket thread.

The `opt` table can contain:

--------------------------------- --------------------------------------------
connection options                options to pass to `http:new()`
request options                   options to pass to `http:make_request()`
--------------------------------- --------------------------------------------

### `client:close_all()`

Close all connections. This must be called after the socket loop finishes.