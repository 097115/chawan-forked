# Interface to loader/loader. The idea is that modules don't have to
# depend on the entire loader implementation to interact with it.
#
# See loader/loader for a more detailed description of the protocol.

import std/tables

import io/bufreader
import io/bufwriter
import io/dynstream
import io/promise
import io/urlfilter
import loader/headers
import loader/request
import loader/response
import monoucha/javascript
import monoucha/jserror
import types/cookie
import types/opt
import types/referrer
import types/url

type
  FileLoader* = ref object
    key*: ClientKey
    process*: int
    clientPid*: int
    map: seq[LoaderData]
    mapFds*: int # number of fds in map
    unregistered*: seq[int]
    registerFun*: proc(fd: int)
    unregisterFun*: proc(fd: int)
    # directory where we store UNIX domain sockets
    sockDir*: string
    # (FreeBSD only) fd for the socket directory so we can connectat() on it
    sockDirFd*: int

  ConnectDataState = enum
    cdsBeforeResult, cdsBeforeStatus, cdsBeforeHeaders

  LoaderData = ref object of RootObj
    stream*: SocketStream

  ConnectData* = ref object of LoaderData
    state: ConnectDataState
    status: uint16
    res: int
    outputId: int
    redirectNum: int
    promise: FetchPromise
    request: Request

  OngoingData* = ref object of LoaderData
    response*: Response

  LoaderCommand* = enum
    lcAddCacheFile
    lcAddClient
    lcGetCacheFile
    lcLoad
    lcLoadConfig
    lcPassFd
    lcRedirectToFile
    lcRemoveCachedItem
    lcRemoveClient
    lcResume
    lcShareCachedItem
    lcSuspend
    lcTee

  ClientKey* = array[32, uint8]

  LoaderClientConfig* = object
    cookieJar*: CookieJar
    defaultHeaders*: Headers
    filter*: URLFilter
    proxy*: URL
    referrerPolicy*: ReferrerPolicy
    insecureSSLNoVerify*: bool

  FetchPromise* = Promise[JSResult[Response]]

proc getRedirect*(response: Response; request: Request): Request =
  if "Location" in response.headers.table:
    if response.status in 301u16..303u16 or response.status in 307u16..308u16:
      let location = response.headers.table["Location"][0]
      let url = parseURL(location, option(request.url))
      if url.isSome:
        let status = response.status
        if status == 303 and request.httpMethod notin {hmGet, hmHead} or
            status == 301 or
            status == 302 and request.httpMethod == hmPost:
          return newRequest(url.get, hmGet)
        else:
          return newRequest(url.get, request.httpMethod, body = request.body)
  return nil

template withLoaderPacketWriter(stream: SocketStream; loader: FileLoader;
    w, body: untyped) =
  stream.withPacketWriter w:
    w.swrite(loader.clientPid)
    w.swrite(loader.key)
    body

proc connect(loader: FileLoader): SocketStream =
  return connectSocketStream(loader.sockDir, loader.sockDirFd, loader.process,
    blocking = true)

# Start a request. This should not block (not for a significant amount of time
# anyway).
proc startRequest(loader: FileLoader; request: Request): SocketStream =
  let stream = loader.connect()
  stream.withLoaderPacketWriter loader, w:
    w.swrite(lcLoad)
    w.swrite(request)
  return stream

proc startRequest*(loader: FileLoader; request: Request;
    config: LoaderClientConfig): SocketStream =
  let stream = loader.connect()
  stream.withLoaderPacketWriter loader, w:
    w.swrite(lcLoadConfig)
    w.swrite(request)
    w.swrite(config)
  return stream

iterator data*(loader: FileLoader): LoaderData {.inline.} =
  for it in loader.map:
    if it != nil:
      yield it

iterator ongoing*(loader: FileLoader): OngoingData {.inline.} =
  for it in loader.data:
    if it of OngoingData:
      yield OngoingData(it)

func fd*(data: LoaderData): int =
  return int(data.stream.fd)

proc put*(loader: FileLoader; data: LoaderData) =
  let fd = int(data.stream.fd)
  if loader.map.len <= fd:
    loader.map.setLen(fd + 1)
  assert loader.map[fd] == nil
  loader.map[fd] = data
  inc loader.mapFds

proc get*(loader: FileLoader; fd: int): LoaderData =
  if fd < loader.map.len:
    return loader.map[fd]
  return nil

proc unset*(loader: FileLoader; data: LoaderData) =
  let fd = int(data.stream.fd)
  if loader.get(fd) != nil:
    dec loader.mapFds
    loader.map[fd] = nil

proc fetch0(loader: FileLoader; input: Request; promise: FetchPromise;
    redirectNum: int) =
  let stream = loader.startRequest(input)
  loader.registerFun(int(stream.fd))
  loader.put(ConnectData(
    promise: promise,
    request: input,
    stream: stream,
    redirectNum: redirectNum
  ))

proc fetch*(loader: FileLoader; input: Request): FetchPromise =
  let promise = FetchPromise()
  loader.fetch0(input, promise, 0)
  return promise

proc reconnect*(loader: FileLoader; data: ConnectData) =
  data.stream.sclose()
  let stream = loader.startRequest(data.request)
  let data = ConnectData(
    promise: data.promise,
    request: data.request,
    stream: stream
  )
  loader.put(data)
  loader.registerFun(data.fd)

proc suspend*(loader: FileLoader; fds: seq[int]) =
  let stream = loader.connect()
  stream.withLoaderPacketWriter loader, w:
    w.swrite(lcSuspend)
    w.swrite(fds)
  stream.sclose()

proc resume*(loader: FileLoader; fds: openArray[int]) =
  let stream = loader.connect()
  stream.withLoaderPacketWriter loader, w:
    w.swrite(lcResume)
    w.swrite(fds)
  stream.sclose()

proc resume*(loader: FileLoader; fds: int) =
  loader.resume([fds])

proc tee*(loader: FileLoader; sourceId, targetPid: int): (SocketStream, int) =
  let stream = loader.connect()
  stream.withLoaderPacketWriter loader, w:
    w.swrite(lcTee)
    w.swrite(sourceId)
    w.swrite(targetPid)
  var outputId: int
  var r = stream.initPacketReader()
  r.sread(outputId)
  return (stream, outputId)

proc addCacheFile*(loader: FileLoader; outputId, targetPid: int): int =
  let stream = loader.connect()
  if stream == nil:
    return -1
  stream.withLoaderPacketWriter loader, w:
    w.swrite(lcAddCacheFile)
    w.swrite(outputId)
    w.swrite(targetPid)
  var r = stream.initPacketReader()
  var outputId: int
  r.sread(outputId)
  stream.sclose()
  return outputId

proc getCacheFile*(loader: FileLoader; cacheId: int): string =
  let stream = loader.connect()
  if stream == nil:
    return ""
  stream.withLoaderPacketWriter loader, w:
    w.swrite(lcGetCacheFile)
    w.swrite(cacheId)
  var r = stream.initPacketReader()
  var s: string
  r.sread(s)
  stream.sclose()
  return s

proc redirectToFile*(loader: FileLoader; outputId: int; targetPath: string):
    bool =
  let stream = loader.connect()
  if stream == nil:
    return false
  stream.withLoaderPacketWriter loader, w:
    w.swrite(lcRedirectToFile)
    w.swrite(outputId)
    w.swrite(targetPath)
  var r = stream.initPacketReader()
  var res: bool
  r.sread(res)
  stream.sclose()
  return res

proc onConnected(loader: FileLoader; connectData: ConnectData) =
  let stream = connectData.stream
  let promise = connectData.promise
  let request = connectData.request
  var r = stream.initPacketReader()
  case connectData.state
  of cdsBeforeResult:
    var res: int
    r.sread(res) # packet 1
    if res == 0:
      r.sread(connectData.outputId) # packet 1
      inc connectData.state
    else:
      var msg: string
      # msg is discarded.
      #TODO maybe print if called from trusted code (i.e. global == client)?
      r.sread(msg) # packet 1
      let fd = connectData.fd
      loader.unregisterFun(fd)
      loader.unregistered.add(fd)
      stream.sclose()
      # delete before resolving the promise
      loader.unset(connectData)
      let err = newTypeError("NetworkError when attempting to fetch resource")
      promise.resolve(JSResult[Response].err(err))
  of cdsBeforeStatus:
    r.sread(connectData.status) # packet 2
    inc connectData.state
  of cdsBeforeHeaders:
    let response = newResponse(connectData.res, request, stream,
      connectData.outputId, connectData.status)
    r.sread(response.headers) # packet 3
    # Only a stream of the response body may arrive after this point.
    response.body = stream
    # delete before resolving the promise
    loader.unset(connectData)
    let data = OngoingData(response: response, stream: stream)
    loader.put(data)
    assert loader.unregisterFun != nil
    response.unregisterFun = proc() =
      loader.unset(data)
      let fd = data.fd
      loader.unregistered.add(fd)
      loader.unregisterFun(fd)
    response.resumeFun = proc(outputId: int) =
      loader.resume(outputId)
    stream.setBlocking(false)
    let redirect = response.getRedirect(request)
    if redirect != nil:
      response.unregisterFun()
      stream.sclose()
      let redirectNum = connectData.redirectNum + 1
      if redirectNum < 5: #TODO use config.network.max_redirect?
        loader.fetch0(redirect, promise, redirectNum)
      else:
        let err = newTypeError("NetworkError when attempting to fetch resource")
        promise.resolve(JSResult[Response].err(err))
    else:
      promise.resolve(JSResult[Response].ok(response))

proc onRead*(loader: FileLoader; data: OngoingData) =
  let response = data.response
  response.onRead(response)
  if response.body.isend:
    if response.onFinish != nil:
      response.onFinish(response, true)
    response.onFinish = nil
    response.close()

proc onRead*(loader: FileLoader; fd: int) =
  let data = loader.map[fd]
  if data of ConnectData:
    loader.onConnected(ConnectData(data))
  else:
    loader.onRead(OngoingData(data))

proc onError*(loader: FileLoader; data: OngoingData) =
  let response = data.response
  if response.onFinish != nil:
    response.onFinish(response, false)
  response.onFinish = nil
  response.close()

proc onError*(loader: FileLoader; fd: int): bool =
  let data = loader.map[fd]
  if data of ConnectData:
    # probably shouldn't happen. TODO
    return false
  else:
    loader.onError(OngoingData(data))
    return true

# Note: this blocks until headers are received.
proc doRequest*(loader: FileLoader; request: Request): Response =
  let stream = loader.startRequest(request)
  let response = Response(url: request.url)
  var r = stream.initPacketReader()
  r.sread(response.res) # packet 1
  if response.res == 0:
    r.sread(response.outputId) # packet 1
    r = stream.initPacketReader()
    r.sread(response.status) # packet 2
    r = stream.initPacketReader()
    r.sread(response.headers) # packet 3
    # Only a stream of the response body may arrive after this point.
    response.body = stream
    response.resumeFun = proc(outputId: int) =
      loader.resume(outputId)
  else:
    var msg: string
    r.sread(msg) # packet 1
    stream.sclose()
  return response

proc shareCachedItem*(loader: FileLoader; id, targetPid: int; sourcePid = -1) =
  let stream = loader.connect()
  if stream != nil:
    let sourcePid = if sourcePid != -1: sourcePid else: loader.clientPid
    stream.withLoaderPacketWriter loader, w:
      w.swrite(lcShareCachedItem)
      w.swrite(sourcePid)
      w.swrite(targetPid)
      w.swrite(id)
    stream.sclose()

proc passFd*(loader: FileLoader; id: string; fd: FileHandle) =
  let stream = loader.connect()
  if stream != nil:
    stream.withLoaderPacketWriter loader, w:
      w.swrite(lcPassFd)
      w.swrite(id)
    stream.sendFileHandle(fd)
    stream.sclose()

proc removeCachedItem*(loader: FileLoader; cacheId: int) =
  let stream = loader.connect()
  if stream != nil:
    stream.withLoaderPacketWriter loader, w:
      w.swrite(lcRemoveCachedItem)
      w.swrite(cacheId)
    stream.sclose()

proc addClient*(loader: FileLoader; key: ClientKey; pid: int;
    config: LoaderClientConfig; clonedFrom: int): bool =
  let stream = loader.connect()
  stream.withLoaderPacketWriter loader, w:
    w.swrite(lcAddClient)
    w.swrite(key)
    w.swrite(pid)
    w.swrite(config)
    w.swrite(clonedFrom)
  var r = stream.initPacketReader()
  var res: bool
  r.sread(res)
  stream.sclose()
  return res

proc removeClient*(loader: FileLoader; pid: int) =
  let stream = loader.connect()
  if stream != nil:
    stream.withLoaderPacketWriter loader, w:
      w.swrite(lcRemoveClient)
      w.swrite(pid)
    stream.sclose()

when defined(freebsd):
  let O_DIRECTORY* {.importc, header: "<fcntl.h>", noinit.}: cint

proc setSocketDir*(loader: FileLoader; path: string) =
  loader.sockDir = path
  when defined(freebsd):
    loader.sockDirFd = open(cstring(path), O_DIRECTORY)
  else:
    loader.sockDirFd = -1
