import lib/nimuv
import lib/mofuparser
import lib/httputils
import nativesockets
import osproc

const
  kByte* = 1024
  mByte* = 1024 * kByte

  maxBodySize = 1 * mByte

  not_found_body = HTTP404 & "\r\L" &
                   "Connection: keep-alive" & "\r\L" &
                   "Content-Length: 39"  & "\r\L" &
                   "Content-Type: text/html; charset=utf-8" & "\r\L" & "\r\L" &
                   "<center><h1>404 Not Found.</h1><center>"

type
  #mofuw_t = object
  #  server: uv_tcp_t

  http_req* = object
    handle*: ptr uv_handle_t
    req_line*: HttpReq
    req_header*: array[64, headers]
    req_header_addr*: ptr http_req.req_header
    # req_body: array[maxBodySize, char]
    # req_body_len: int

  http_res* = object
    handle*: ptr uv_handle_t
    fd*: cint
    res*: ptr uv_write_t
    body*: uv_buf_t

  router = object
    GET: seq[router_t]
    POST: seq[router_t]
    
  router_t* = object
    path*: string
    cb*: proc(req: ptr http_req, res: ptr http_res)

  thread_t = tuple[
    port: int,
    backlog: int
  ]

proc getMethod*(req: ptr http_req): string {.inline.} =
  return ($(req.req_line.method))[0 .. req.req_line.methodLen]

proc getPath*(req: ptr http_req): string {.inline.} =
  return ($(req.req_line.path))[0 .. req.req_line.pathLen]

var
  ROUTER {.threadvar.}: router

ROUTER.GET = @[]

proc after_close(handle: ptr uv_handle_t) {.cdecl.} =
  return

proc free_response(req: ptr uv_write_t, status: cint) {.cdecl.} =
  dealloc(req)

proc buf_alloc(handle: ptr uv_handle_t, size: csize, buf: ptr uv_buf_t) {.cdecl.} = 
  buf[].base = alloc(size)
  buf[].len = size

proc mofuw_send*(res: ptr http_res, body: cstring) =
  res.body.base = body
  res.body.len = body.len

  discard uv_write(res.res, cast[ptr uv_stream_t](res.handle), res.body.addr, 1, free_response)

proc notFound*(res: ptr http_res) =
  mofuw_send(res, not_found_body)

proc read_cb(stream: ptr uv_stream_t, nread: cssize, buf: ptr uv_buf_t) {.cdecl.} =
  if nread == -4095:
    dealloc(stream)
    dealloc(buf.base)
    uv_close(cast[ptr uv_handle_t](stream), after_close)
    return
  elif nread < 0:
    dealloc(stream)
    dealloc(buf.base)
    return

  var
    request: ptr http_req = cast[ptr http_req](http_req.new)
    response: ptr http_res = cast[ptr http_res](http_res.new)

  response.handle = cast[ptr uv_handle_t](stream)

  request.req_header_addr = request.req_header.addr

  response.res = cast[ptr uv_write_t](alloc(sizeof(uv_write_t)))

  let r = mp_req(cast[ptr char](buf.base), request.req_line, request.req_header_addr)

  if r <= 0:
    notFound(response)
    dealloc(stream)
    dealloc(buf.base)
    return

  #request.req_body = cast[ptr cstring](buf.base)[r]
  #request.req_body_len = cast[ptr cstring](buf.base).len - r - 1

  case getMethod(request)
  of "GET":
    if ROUTER.GET.len == 0:
      notFound(response)
    else:
      for value in ROUTER.GET:
        if getPath(request) == value.path:
          value.cb(request, response)
        else:
          notFound(response)
  else:
    notFound(response)

  dealloc(buf.base)

proc accept_cb(server: ptr uv_stream_t, status: cint) {.cdecl.} =
  if not status == 0: echo "error: ", uv_err_name(status), uv_strerror(status), "\n"

  var client = cast[ptr uv_stream_t](alloc(sizeof(uv_tcp_t)))

  discard uv_tcp_init(server.loop, cast[ptr uv_tcp_t](client))
  discard uv_accept(server, client)
  discard uv_read_start(client, buf_alloc, read_cb)

######
# MAIN
######
proc mofuw_run*(port: int = 8080, backlog: int = 128) =
  var
    server: ptr uv_tcp_t = cast[ptr uv_tcp_t](uv_tcp_t.new())
    loop: ptr uv_loop_t = uv_default_loop()
    sockaddr: SockAddrIn
    fd: uv_os_fd_t

  discard uv_ip4_addr("0.0.0.0".cstring, port.cint, sockaddr.addr)

  discard uv_tcp_init_ex(loop, server, AF_INET.cuint)

  discard uv_tcp_nodelay(server, 1)

  discard uv_tcp_simultaneous_accepts(server, 1)

  discard uv_fileno(cast[ptr uv_handle_t](server), fd.addr)

  fd.SocketHandle.setSockOptInt(cint(SOL_SOCKET), SO_REUSEPORT, 1)

  discard uv_tcp_bind(server, cast[ptr SockAddr](sockaddr.addr), 0)

  discard uv_listen(cast[ptr uv_stream_t](server), backlog.cint, accept_cb)

  discard uv_run(loop, UV_RUN_DEFAULT)

proc mofuw_GET*(path: string, cb: proc(req: ptr http_req, res: ptr http_res)) =
  var r: router_t

  r.path = path
  r.cb = cb

  ROUTER.GET.add(r)