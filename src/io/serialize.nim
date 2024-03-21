# Write data to streams.

import std/options
import std/sets
import std/streams
import std/tables

import types/blob
import types/formdata
import types/url
import types/opt

proc sread*(stream: Stream, n: var SomeNumber)
func slen*(n: SomeNumber): int

proc sread*[T](stream: Stream, s: var set[T])
func slen*[T](s: set[T]): int

proc sread*[T: enum](stream: Stream, x: var T)
func slen*[T: enum](x: T): int

proc sread*(stream: Stream, s: var string)
func slen*(s: string): int

proc sread*(stream: Stream, b: var bool)
func slen*(b: bool): int

func slen*(url: URL): int

func slen*(tup: tuple): int

proc sread*[I, T](stream: Stream, a: var array[I, T])
func slen*[I, T](a: array[I, T]): int

proc sread*(stream: Stream, s: var seq)
func slen*(s: seq): int

proc sread*[U, V](stream: Stream, t: var Table[U, V])
func slen*[U, V](t: Table[U, V]): int

proc sread*(stream: Stream, obj: var object)
func slen*(obj: object): int

proc sread*(stream: Stream, obj: var ref object)
func slen*(obj: ref object): int

func slen*(part: FormDataEntry): int

func slen*(blob: Blob): int

proc sread*[T](stream: Stream, o: var Option[T])
func slen*[T](o: Option[T]): int

proc sread*[T, E](stream: Stream, o: var Result[T, E])
func slen*[T, E](o: Result[T, E]): int

proc sread*(stream: Stream, n: var SomeNumber) =
  if stream.readData(addr n, sizeof(n)) < sizeof(n):
    raise newException(EOFError, "eof")

func slen*(n: SomeNumber): int =
  return sizeof(n)

proc sread*[T: enum](stream: Stream, x: var T) =
  var i: int
  stream.sread(i)
  x = cast[T](i)

func slen*[T: enum](x: T): int =
  return sizeof(int)

proc sread*[T](stream: Stream, s: var set[T]) =
  var len: int
  stream.sread(len)
  for i in 0 ..< len:
    var x: T
    stream.sread(x)
    s.incl(x)

func slen*[T](s: set[T]): int =
  result = slen(s.card)
  for x in s:
    result += slen(x)

proc sread*(stream: Stream, s: var string) =
  var len: int
  stream.sread(len)
  if len > 0:
    s = newString(len)
    prepareMutation(s)
    if stream.readData(addr s[0], len) < len:
      raise newException(EOFError, "eof")
  else:
    s = ""

func slen*(s: string): int =
  slen(s.len) + s.len

proc sread*(stream: Stream, b: var bool) =
  var n: uint8
  stream.sread(n)
  if n == 1u8:
    b = true
  else:
    assert n == 0u8
    b = false

func slen*(b: bool): int =
  return sizeof(uint8)

func slen*(url: URL): int =
  if url == nil:
    return slen("")
  return slen(url.serialize())

func slen*(tup: tuple): int =
  for f in tup.fields:
    result += slen(f)

proc sread*[I, T](stream: Stream; a: var array[I, T]) =
  for x in a.mitems:
    stream.sread(x)

func slen*[I, T](a: array[I, T]): int =
  for x in a:
    result += slen(x)

proc sread*(stream: Stream, s: var seq) =
  var len: int
  stream.sread(len)
  s.setLen(len)
  for x in s.mitems:
    stream.sread(x)

func slen*(s: seq): int =
  result = slen(s.len)
  for x in s:
    result += slen(x)

proc sread*[U, V](stream: Stream, t: var Table[U, V]) =
  var len: int
  stream.sread(len)
  for i in 0..<len:
    var k: U
    stream.sread(k)
    var v: V
    stream.sread(v)
    t[k] = v

func slen*[U, V](t: Table[U, V]): int =
  result = slen(t.len)
  for k, v in t:
    result += slen(k)
    result += slen(v)

proc sread*(stream: Stream, obj: var object) =
  for f in obj.fields:
    stream.sread(f)

func slen*(obj: object): int =
  for f in obj.fields:
    result += slen(f)

proc sread*(stream: Stream, obj: var ref object) =
  var n: bool
  stream.sread(n)
  if n:
    new(obj)
    stream.sread(obj[])

func slen*(obj: ref object): int =
  result = slen(obj != nil)
  if obj != nil:
    result += slen(obj[])

func slen*(part: FormDataEntry): int =
  result += slen(part.isstr)
  result += slen(part.name)
  result += slen(part.filename)
  if part.isstr:
    result += slen(part.svalue)
  else:
    result += slen(part.value)

func slen*(blob: Blob): int =
  result += slen(blob.isfile)
  if blob.isfile:
    result = slen(WebFile(blob).path)
  else:
    result += slen(blob.ctype)
    result += slen(blob.size)
    result += int(blob.size) #TODO ??

proc sread*[T](stream: Stream, o: var Option[T]) =
  var x: bool
  stream.sread(x)
  if x:
    var m: T
    stream.sread(m)
    o = some(m)
  else:
    o = none(T)

func slen*[T](o: Option[T]): int =
  result = slen(o.isSome)
  if o.isSome:
    result += slen(o.get)

proc sread*[T, E](stream: Stream, o: var Result[T, E]) =
  var x: bool
  stream.sread(x)
  if x:
    when not (T is void):
      var m: T
      stream.sread(m)
      o.ok(m)
    else:
      o.ok()
  else:
    when not (E is void):
      var e: E
      stream.sread(e)
      o.err(e)
    else:
      o.err()

func slen*[T, E](o: Result[T, E]): int =
  result = slen(o.isSome)
  if o.isSome:
    when not (T is void):
      result += slen(o.get)
  else:
    when not (E is void):
      result += slen(o.error)
