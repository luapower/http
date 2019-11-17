
## `local http = require'http'`

HTTP 1.1 client & server protocol in Lua.

Works on an abstract I/O API made of two functions:

	* `http:read(buf, maxsz) -> sz | nil,err`
	* `http:write(buf, sz) -> true | nil,'closed'|err`

Supports

## Status

<warn>Work-in-progress.<warn>
