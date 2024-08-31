# Write data to streams in packets.
# Each packet is prefixed with its length as a pointer-sized integer.

import std/options
import std/sets
import std/tables

import img/bitmap
import io/dynstream
import loader/request
import types/blob
import types/color
import types/formdata
import types/opt
import types/url

type BufferedWriter* = object
  stream: DynStream
  buffer: ptr UncheckedArray[uint8]
  bufSize: int
  bufLen: int
  sendAux: seq[FileHandle]

proc `=destroy`(writer: var BufferedWriter) =
  if writer.buffer != nil:
    dealloc(writer.buffer)
    writer.buffer = nil

proc swrite*(writer: var BufferedWriter; n: SomeNumber)
proc swrite*[T](writer: var BufferedWriter; s: set[T])
proc swrite*[T: enum](writer: var BufferedWriter; x: T)
proc swrite*(writer: var BufferedWriter; s: string)
proc swrite*(writer: var BufferedWriter; b: bool)
proc swrite*(writer: var BufferedWriter; url: URL)
proc swrite*(writer: var BufferedWriter; tup: tuple)
proc swrite*[I, T](writer: var BufferedWriter; a: array[I, T])
proc swrite*[T](writer: var BufferedWriter; s: openArray[T])
proc swrite*[U, V](writer: var BufferedWriter; t: Table[U, V])
proc swrite*(writer: var BufferedWriter; obj: object)
proc swrite*(writer: var BufferedWriter; obj: ref object)
proc swrite*(writer: var BufferedWriter; part: FormDataEntry)
proc swrite*(writer: var BufferedWriter; blob: Blob)
proc swrite*[T](writer: var BufferedWriter; o: Option[T])
proc swrite*[T, E](writer: var BufferedWriter; o: Result[T, E])
proc swrite*(writer: var BufferedWriter; c: ARGBColor) {.inline.}
proc swrite*(writer: var BufferedWriter; o: RequestBody)
proc swrite*(writer: var BufferedWriter; bmp: NetworkBitmap)

const InitLen = sizeof(int) * 2
const SizeInit = max(64, InitLen)
proc initWriter*(stream: DynStream):
    BufferedWriter =
  return BufferedWriter(
    stream: stream,
    buffer: cast[ptr UncheckedArray[uint8]](alloc(SizeInit)),
    bufSize: SizeInit,
    bufLen: InitLen
  )

proc flush*(writer: var BufferedWriter) =
  # subtract the length field's size
  let len = [writer.bufLen - InitLen, writer.sendAux.len]
  copyMem(writer.buffer, unsafeAddr len[0], sizeof(len))
  writer.stream.sendDataLoop(writer.buffer, writer.bufLen)
  for i in countdown(writer.sendAux.high, 0):
    SocketStream(writer.stream).sendFileHandle(writer.sendAux[i])
  writer.bufLen = 0
  writer.stream.sflush()

proc deinit*(writer: var BufferedWriter) =
  dealloc(writer.buffer)
  writer.buffer = nil
  writer.bufSize = 0
  writer.bufLen = 0
  writer.sendAux.setLen(0)

template withPacketWriter*(stream: DynStream; w, body: untyped) =
  block:
    var w = stream.initWriter()
    body
    w.flush()
    w.deinit()

proc writeData(writer: var BufferedWriter; buffer: pointer; len: int) =
  let targetLen = writer.bufLen + len
  let missing = targetLen - writer.bufSize
  if missing > 0:
    let target = writer.bufSize + missing
    writer.bufSize *= 2
    if writer.bufSize < target:
      writer.bufSize = target
    let p = realloc(writer.buffer, writer.bufSize)
    writer.buffer = cast[ptr UncheckedArray[uint8]](p)
  copyMem(addr writer.buffer[writer.bufLen], buffer, len)
  writer.bufLen = targetLen

proc swrite*(writer: var BufferedWriter; n: SomeNumber) =
  writer.writeData(unsafeAddr n, sizeof(n))

proc swrite*[T: enum](writer: var BufferedWriter; x: T) =
  static:
    doAssert sizeof(int) >= sizeof(T)
  writer.swrite(int(x))

proc swrite*[T](writer: var BufferedWriter; s: set[T]) =
  writer.swrite(s.card)
  for e in s:
    writer.swrite(e)

proc swrite*(writer: var BufferedWriter; s: string) =
  writer.swrite(s.len)
  if s.len > 0:
    writer.writeData(unsafeAddr s[0], s.len)

proc swrite*(writer: var BufferedWriter; b: bool) =
  if b:
    writer.swrite(1u8)
  else:
    writer.swrite(0u8)

proc swrite*(writer: var BufferedWriter; url: URL) =
  if url != nil:
    writer.swrite(url.serialize())
  else:
    writer.swrite("")

proc swrite*(writer: var BufferedWriter; tup: tuple) =
  for f in tup.fields:
    writer.swrite(f)

proc swrite*[I, T](writer: var BufferedWriter; a: array[I, T]) =
  for x in a:
    writer.swrite(x)

proc swrite*[T](writer: var BufferedWriter; s: openArray[T]) =
  writer.swrite(s.len)
  for x in s:
    writer.swrite(x)

proc swrite*[U, V](writer: var BufferedWriter; t: Table[U, V]) =
  writer.swrite(t.len)
  for k, v in t:
    writer.swrite(k)
    writer.swrite(v)

proc swrite*(writer: var BufferedWriter; obj: object) =
  for f in obj.fields:
    writer.swrite(f)

proc swrite*(writer: var BufferedWriter; obj: ref object) =
  writer.swrite(obj != nil)
  if obj != nil:
    writer.swrite(obj[])

proc swrite*(writer: var BufferedWriter; part: FormDataEntry) =
  writer.swrite(part.isstr)
  writer.swrite(part.name)
  writer.swrite(part.filename)
  if part.isstr:
    writer.swrite(part.svalue)
  else:
    writer.swrite(part.value)

#TODO clean up this mess
proc swrite*(writer: var BufferedWriter; blob: Blob) =
  if blob.fd.isSome:
    writer.sendAux.add(blob.fd.get)
  writer.swrite(blob of WebFile)
  if blob of WebFile:
    writer.swrite(WebFile(blob).name)
  writer.swrite(blob.fd.isSome)
  writer.swrite(blob.ctype)
  writer.swrite(blob.size)
  if blob.size > 0:
    writer.writeData(blob.buffer, int(blob.size))

proc swrite*[T](writer: var BufferedWriter; o: Option[T]) =
  writer.swrite(o.isSome)
  if o.isSome:
    writer.swrite(o.get)

proc swrite*[T, E](writer: var BufferedWriter; o: Result[T, E]) =
  writer.swrite(o.isSome)
  if o.isSome:
    when not (T is void):
      writer.swrite(o.get)
  else:
    when not (E is void):
      writer.swrite(o.error)

proc swrite*(writer: var BufferedWriter; c: ARGBColor) =
  writer.swrite(uint32(c))

proc swrite*(writer: var BufferedWriter; o: RequestBody) =
  writer.swrite(o.t)
  case o.t
  of rbtNone: discard
  of rbtString: writer.swrite(o.s)
  of rbtMultipart: writer.swrite(o.multipart)
  of rbtOutput: writer.swrite(o.outputId)

proc swrite*(writer: var BufferedWriter; bmp: NetworkBitmap) =
  writer.swrite(bmp.width)
  writer.swrite(bmp.height)
  writer.swrite(bmp.cacheId)
  writer.swrite(bmp.imageId)
  writer.swrite(bmp.contentType)
