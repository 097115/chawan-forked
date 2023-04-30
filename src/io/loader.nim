# A file loader server (?)
# The idea here is that we receive requests with a socket, then respond to each
# with a response (ideally a document.)
# For now, the protocol looks like:
# C: Request
# S: res (0 => success, _ => error)
# if success:
#  S: status code
#  S: headers
#  S: response body
#
# The body is passed to the stream as-is, so effectively nothing can follow it.

import nativesockets
import options
import streams
import tables
import net
when defined(posix):
  import posix

import bindings/curl
import io/about
import io/file
import io/http
import io/promise
import io/request
import io/urlfilter
import js/javascript
import ips/serialize
import ips/serversocket
import ips/socketstream
import types/cookie
import types/mime
import types/referer
import types/url
import utils/twtstr

type
  FileLoader* = ref object
    process*: Pid
    connecting*: Table[int, ConnectData]
    ongoing*: Table[int, Response]
    registerFun*: proc(fd: int)
    unregisterFun*: proc(fd: int)

  ConnectData = object
    promise: Promise[Response]
    stream: Stream
    request: Request

  LoaderCommand = enum
    LOAD, QUIT

  LoaderContext = ref object
    ssock: ServerSocket
    alive: bool
    curlm: CURLM
    config: LoaderConfig
    extra_fds: seq[curl_waitfd]
    handleList: seq[HandleData]

  LoaderConfig* = object
    defaultheaders*: HeaderList
    filter*: URLFilter
    cookiejar*: CookieJar
    referrerpolicy*: ReferrerPolicy

proc addFd(ctx: LoaderContext, fd: int, flags: int) =
  ctx.extra_fds.add(curl_waitfd(
    fd: cast[cint](fd),
    events: cast[cshort](flags)
  ))

proc loadResource(ctx: LoaderContext, request: Request, ostream: Stream) =
  case request.url.scheme
  of "file":
    loadFile(request.url, ostream)
    ostream.close()
  of "http", "https":
    let handleData = loadHttp(ctx.curlm, request, ostream)
    if handleData != nil:
      ctx.handleList.add(handleData)
  of "about":
    loadAbout(request, ostream)
    ostream.close()
  else:
    ostream.swrite(-1) # error
    ostream.close()

proc onLoad(ctx: LoaderContext, stream: Stream) =
  var request: Request
  stream.sread(request)
  if not ctx.config.filter.match(request.url):
    stream.swrite(-1) # error
    stream.flush()
  else:
    for k, v in ctx.config.defaultHeaders.table:
      if k notin request.headers.table:
        request.headers.table[k] = v
    if ctx.config.cookiejar != nil and ctx.config.cookiejar.cookies.len > 0:
      if "Cookie" notin request.headers.table:
        let cookie = ctx.config.cookiejar.serialize(request.url)
        if cookie != "":
          request.headers["Cookie"] = cookie
    if request.referer != nil and "Referer" notin request.headers.table:
      let r = getReferer(request.referer, request.url, ctx.config.referrerpolicy)
      if r != "":
        request.headers["Referer"] = r
    ctx.loadResource(request, stream)

proc acceptConnection(ctx: LoaderContext) =
  #TODO TODO TODO acceptSocketStream should be non-blocking here,
  # otherwise the client disconnecting between poll and accept could
  # block this indefinitely.
  let stream = ctx.ssock.acceptSocketStream()
  try:
    var cmd: LoaderCommand
    stream.sread(cmd)
    case cmd
    of LOAD:
      ctx.onLoad(stream)
    of QUIT:
      ctx.alive = false
      stream.close()
  except IOError:
    # End-of-file, broken pipe, or something else. For now we just
    # ignore it and pray nothing breaks.
    # (TODO: this is probably not a very good idea.)
    stream.close()

proc finishCurlTransfer(ctx: LoaderContext, handleData: HandleData, res: int) =
  if res != int(CURLE_OK):
    handleData.ostream.swrite(int(res))
    handleData.ostream.flush()
  discard curl_multi_remove_handle(ctx.curlm, handleData.curl)
  handleData.ostream.close()
  handleData.cleanup()

proc exitLoader(ctx: LoaderContext) =
  for handleData in ctx.handleList:
    #TODO: -1, -2, -3, ... results should be named.
    ctx.finishCurlTransfer(handleData, -3)
  discard curl_multi_cleanup(ctx.curlm)
  curl_global_cleanup()
  ctx.ssock.close()
  quit(0)

var gctx: LoaderContext
proc initLoaderContext(fd: cint, config: LoaderConfig): LoaderContext =
  if curl_global_init(CURL_GLOBAL_ALL) != CURLE_OK:
    raise newException(Defect, "Failed to initialize libcurl.")
  let curlm = curl_multi_init()
  if curlm == nil:
    raise newException(Defect, "Failed to initialize multi handle.")
  var ctx = LoaderContext(
    alive: true,
    curlm: curlm,
    config: config
  )
  gctx = ctx
  ctx.ssock = initServerSocket()
  # The server has been initialized, so the main process can resume execution.
  var writef: File
  if not open(writef, FileHandle(fd), fmWrite):
    raise newException(Defect, "Failed to open input handle.")
  writef.write(char(0u8))
  writef.flushFile()
  close(writef)
  discard close(fd)
  onSignal SIGTERM, SIGINT:
    gctx.exitLoader()
  ctx.addFd(int(ctx.ssock.sock.getFd()), CURL_WAIT_POLLIN)
  return ctx

proc runFileLoader*(fd: cint, config: LoaderConfig) =
  var ctx = initLoaderContext(fd, config)
  while ctx.alive:
    var numfds: cint = 0
    #TODO do not discard
    discard curl_multi_poll(ctx.curlm, addr ctx.extra_fds[0],
      cuint(ctx.extra_fds.len), 30_000, addr numfds)
    discard curl_multi_perform(ctx.curlm, addr numfds)
    for extra_fd in ctx.extra_fds.mitems:
      # For now, this is always ssock.sock.getFd().
      if extra_fd.events == extra_fd.revents:
        ctx.acceptConnection()
        extra_fd.revents = 0
    var msgs_left: cint = 1
    while msgs_left > 0:
      let msg = curl_multi_info_read(ctx.curlm, addr msgs_left)
      if msg == nil:
        break
      if msg.msg == CURLMSG_DONE: # the only possible value atm
        var idx = -1
        for i in 0 ..< ctx.handleList.len:
          if ctx.handleList[i].curl == msg.easy_handle:
            idx = i
            break
        assert idx != -1
        ctx.finishCurlTransfer(ctx.handleList[idx], int(msg.data.result))
        ctx.handleList.del(idx)
  ctx.exitLoader()

proc applyHeaders(request: Request, response: Response) =
  if "Content-Type" in response.headers.table:
    response.contenttype = response.headers.table["Content-Type"][0].until(';')
  else:
    response.contenttype = guessContentType($response.url.path)
  if "Location" in response.headers.table:
    if response.status in 301..303 or response.status in 307..308:
      let location = response.headers.table["Location"][0]
      let url = parseUrl(location, option(request.url))
      if url.isSome:
        if (response.status == 303 and
            request.httpmethod notin {HTTP_GET, HTTP_HEAD}) or
            (response.status == 301 or response.status == 302 and
            request.httpmethod == HTTP_POST):
          response.redirect = newRequest(url.get, HTTP_GET,
            mode = request.mode, credentialsMode = request.credentialsMode,
            destination = request.destination)
        else:
          response.redirect = newRequest(url.get, request.httpmethod,
            body = request.body, multipart = request.multipart,
            mode = request.mode, credentialsMode = request.credentialsMode,
            destination = request.destination)

#TODO: add init
proc fetch*(loader: FileLoader, input: Request): Promise[Response] =
  let stream = connectSocketStream(loader.process, false, blocking = true)
  stream.swrite(LOAD)
  stream.swrite(input)
  stream.flush()
  let fd = int(stream.source.getFd())
  loader.registerFun(fd)
  let promise = Promise[Response]()
  loader.connecting[fd] = ConnectData(promise: promise, request: input)

proc newResponse(res: int, request: Request, stream: Stream = nil): Response =
  return Response(
    res: res,
    url: request.url,
    body: stream
  )

proc onConnected*(loader: FileLoader, fd: int) =
  let connectData = loader.connecting[fd]
  let stream = connectData.stream
  let promise = connectData.promise
  let request = connectData.request
  var res: int
  stream.sread(res)
  if res == 0:
    let response = newResponse(res, request, stream)
    response.unregisterFun = proc() = loader.unregisterFun(fd)
    stream.sread(response.status)
    stream.sread(response.headers)
    applyHeaders(request, response)
    response.body = stream
    loader.ongoing[fd] = response
    promise.resolve(response)
  else:
    #TODO: reject promise instead.
    let response = newResponse(res, request)
    promise.resolve(response)
  loader.connecting.del(fd)

proc doRequest*(loader: FileLoader, request: Request, blocking = true): Response =
  new(result)
  result.url = request.url
  let stream = connectSocketStream(loader.process, false, blocking = true)
  stream.swrite(LOAD)
  stream.swrite(request)
  stream.flush()
  stream.sread(result.res)
  if result.res == 0:
    stream.sread(result.status)
    stream.sread(result.headers)
    applyHeaders(request, result)
    # Only a stream of the response body may arrive after this point.
    result.body = stream
    if not blocking:
      stream.source.getFd().setBlocking(blocking)

proc quit*(loader: FileLoader) =
  let stream = connectSocketStream(loader.process)
  if stream != nil:
    stream.swrite(QUIT)
