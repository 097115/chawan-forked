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
import net
import options
import posix
import streams
import strutils
import tables

import bindings/curl
import io/posixstream
import io/promise
import io/serialize
import io/serversocket
import io/socketstream
import io/urlfilter
import js/error
import js/javascript
import loader/about
import loader/connecterror
import loader/curlhandle
import loader/data
import loader/file
import loader/ftp
import loader/gopher
import loader/headers
import loader/http
import loader/loaderhandle
import loader/request
import loader/response
import types/cookie
import types/referer
import types/url
import utils/mimeguess
import utils/twtstr

import chakasu/charset

export request
export response

type
  FileLoader* = ref object
    process*: Pid
    connecting*: Table[int, ConnectData]
    ongoing*: Table[int, OngoingData]
    unregistered*: seq[int]
    registerFun*: proc(fd: int)
    unregisterFun*: proc(fd: int)

  ConnectData = object
    promise: Promise[JSResult[Response]]
    stream: Stream
    request: Request

  OngoingData = object
    buf: string
    readbufsize: int
    response: Response
    bodyRead: Promise[string]

  LoaderCommand = enum
    LOAD
    QUIT

  LoaderContext = ref object
    ssock: ServerSocket
    alive: bool
    curlm: CURLM
    config: LoaderConfig
    extra_fds: seq[curl_waitfd]
    handleList: seq[CurlHandle]

  LoaderConfig* = object
    defaultheaders*: Headers
    filter*: URLFilter
    cookiejar*: CookieJar
    referrerpolicy*: ReferrerPolicy
    proxy*: URL
    # When set to false, requests with a proxy URL are overridden by the
    # loader proxy.
    acceptProxy*: bool

  FetchPromise* = Promise[JSResult[Response]]

proc addFd(ctx: LoaderContext, fd: int, flags: int) =
  ctx.extra_fds.add(curl_waitfd(
    fd: cast[cint](fd),
    events: cast[cshort](flags)
  ))

proc loadResource(ctx: LoaderContext, request: Request, handle: LoaderHandle) =
  case request.url.scheme
  of "file":
    handle.loadFilePath(request.url)
    handle.close()
  of "http", "https":
    let handleData = handle.loadHttp(ctx.curlm, request)
    if handleData != nil:
      ctx.handleList.add(handleData)
  of "about":
    handle.loadAbout(request)
    handle.close()
  of "data":
    handle.loadData(request)
    handle.close()
  of "ftp", "ftps", "sftp":
    let handleData = handle.loadFtp(ctx.curlm, request)
    if handleData != nil:
      ctx.handleList.add(handleData)
  of "gopher", "gophers":
    let handleData = handle.loadGopher(ctx.curlm, request)
    if handleData != nil:
      ctx.handleList.add(handleData)
  else:
    discard handle.sendResult(ERROR_UNKNOWN_SCHEME)
    handle.close()

proc onLoad(ctx: LoaderContext, stream: Stream) =
  var request: Request
  stream.sread(request)
  if not ctx.config.filter.match(request.url):
    stream.swrite(ERROR_DISALLOWED_URL)
    stream.close()
  else:
    let handle = newLoaderHandle(stream, request.canredir)
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
    if request.proxy == nil or not ctx.config.acceptProxy:
      request.proxy = ctx.config.proxy
    ctx.loadResource(request, handle)

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

proc finishCurlTransfer(ctx: LoaderContext, handleData: CurlHandle, res: int) =
  if res != int(CURLE_OK):
    discard handleData.handle.sendResult(int(res))
  if handleData.finish != nil:
    handleData.finish(handleData)
  discard curl_multi_remove_handle(ctx.curlm, handleData.curl)
  handleData.cleanup()

proc exitLoader(ctx: LoaderContext) =
  for handleData in ctx.handleList:
    ctx.finishCurlTransfer(handleData, ERROR_LOADER_KILLED)
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
  #TODO ideally, buffered would be true. Unfortunately this conflicts with
  # sendFileHandle/recvFileHandle.
  ctx.ssock = initServerSocket(buffered = false)
  # The server has been initialized, so the main process can resume execution.
  var writef: File
  if not open(writef, FileHandle(fd), fmWrite):
    raise newException(Defect, "Failed to open input handle.")
  writef.write(char(0u8))
  writef.flushFile()
  close(writef)
  discard close(fd)
  onSignal SIGTERM, SIGINT:
    discard sig
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

proc getAttribute(contentType, attrname: string): string =
  let kvs = contentType.after(';')
  var i = kvs.find(attrname)
  var s = ""
  if i != -1 and kvs.len > i + attrname.len and
      kvs[i + attrname.len] == '=':
    i += attrname.len + 1
    while i < kvs.len and kvs[i] in AsciiWhitespace:
      inc i
    var q = false
    for j in i ..< kvs.len:
      if q:
        s &= kvs[j]
      else:
        if kvs[j] == '\\':
          q = true
        elif kvs[j] == ';' or kvs[j] in AsciiWhitespace:
          break
        else:
          s &= kvs[j]
  return s

proc applyHeaders(loader: FileLoader, request: Request, response: Response) =
  if "Content-Type" in response.headers.table:
    #TODO this is inefficient and broken on several levels. (In particular,
    # it breaks mailcap named attributes other than charset.)
    # Ideally, contentType would be a separate object type.
    let header = response.headers.table["Content-Type"][0].toLowerAscii()
    response.contenttype = header.until(';').strip().toLowerAscii()
    response.charset = getCharset(header.getAttribute("charset"))
  else:
    response.contenttype = guessContentType($response.url.path,
      "application/octet-stream", DefaultGuess)
  if "Location" in response.headers.table:
    if response.status in 301u16..303u16 or response.status in 307u16..308u16:
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
proc fetch*(loader: FileLoader, input: Request): FetchPromise =
  let stream = connectSocketStream(loader.process, false, blocking = true)
  stream.swrite(LOAD)
  stream.swrite(input)
  stream.flush()
  let fd = int(stream.source.getFd())
  loader.registerFun(fd)
  let promise = FetchPromise()
  loader.connecting[fd] = ConnectData(
    promise: promise,
    request: input,
    stream: stream
  )
  return promise

const BufferSize = 4096

proc handleHeaders(loader: FileLoader, request: Request, response: Response,
    stream: Stream): bool =
  var status: int
  stream.sread(status)
  response.status = cast[uint16](status)
  response.headers = newHeaders()
  stream.sread(response.headers)
  loader.applyHeaders(request, response)
  # Only a stream of the response body may arrive after this point.
  response.body = stream
  return true # success

proc onConnected*(loader: FileLoader, fd: int) =
  let connectData = loader.connecting[fd]
  let stream = connectData.stream
  let promise = connectData.promise
  let request = connectData.request
  var res: int
  stream.sread(res)
  let response = newResponse(res, request, fd, stream)
  if res == 0 and loader.handleHeaders(request, response, stream):
    assert loader.unregisterFun != nil
    let realCloseImpl = stream.closeImpl
    stream.closeImpl = nil
    response.unregisterFun = proc() =
      loader.ongoing.del(fd)
      loader.unregistered.add(fd)
      loader.unregisterFun(fd)
      realCloseImpl(stream)
    loader.ongoing[fd] = OngoingData(
      response: response,
      readbufsize: BufferSize,
      bodyRead: response.bodyRead
    )
    SocketStream(stream).source.getFd().setBlocking(false)
    promise.resolve(JSResult[Response].ok(response))
  else:
    loader.unregisterFun(fd)
    loader.unregistered.add(fd)
    let err = newTypeError("NetworkError when attempting to fetch resource")
    promise.resolve(JSResult[Response].err(err))
  loader.connecting.del(fd)

proc onRead*(loader: FileLoader, fd: int) =
  loader.ongoing.withValue(fd, buffer):
    let response = buffer[].response
    while true:
      let olen = buffer[].buf.len
      buffer[].buf.setLen(olen + buffer.readbufsize)
      try:
        let n = response.body.readData(addr buffer[].buf[olen],
          buffer.readbufsize)
        if n != 0:
          if buffer[].readbufsize < BufferSize:
            buffer[].readbufsize = min(BufferSize, buffer[].readbufsize * 2)
        buffer[].buf.setLen(olen + n)
        if response.body.atEnd():
          buffer[].bodyRead.resolve(buffer[].buf)
          buffer[].bodyRead = nil
          buffer[].buf = ""
          response.unregisterFun()
        break
      except ErrorAgain, ErrorWouldBlock:
        assert buffer.readbufsize > 1
        buffer.readbufsize = buffer.readbufsize div 2

proc onError*(loader: FileLoader, fd: int) =
  loader.onRead(fd)

proc doRequest*(loader: FileLoader, request: Request, blocking = true,
    canredir = false): Response =
  let response = Response(url: request.url)
  let stream = connectSocketStream(loader.process, false, blocking = true)
  if canredir:
    request.canredir = true #TODO set this somewhere else?
  stream.swrite(LOAD)
  stream.swrite(request)
  stream.flush()
  stream.sread(response.res)
  if response.res == 0:
    if loader.handleHeaders(request, response, stream):
      if not blocking:
        stream.source.getFd().setBlocking(blocking)
  return response

proc quit*(loader: FileLoader) =
  let stream = connectSocketStream(loader.process)
  if stream != nil:
    stream.swrite(QUIT)