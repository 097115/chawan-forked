import std/options
import std/os
import std/posix
import std/strutils

import utils/sandbox
import utils/twtstr

{.compile: "jebp.c".}

when sizeof(cint) < 4:
  type jebp_int = clong
else:
  type jebp_int = cint

{.passc: "-I" & currentSourcePath().parentDir().}

const STDIN_FILENO = 0
const STDOUT_FILENO = 1

{.push header: "jebp.h".}
type
  jebp_io_callbacks {.importc.} = object
    read: proc(data: pointer; size: csize_t; user: pointer): csize_t {.cdecl.}
    check_error: proc(user: pointer): cint {.cdecl.}

  jebp_error_t = cint

  jebp_color_t = object
    r: uint8
    g: uint8
    b: uint8
    a: uint8

  jebp_image_t {.importc.} = object
    width: jebp_int
    height: jebp_int
    pixels: ptr jebp_color_t

proc jebp_read_from_callbacks(image: ptr jebp_image_t;
  cb: ptr jebp_io_callbacks; user: pointer): jebp_error_t {.importc.}

proc jebp_read_size_from_callbacks(image: ptr jebp_image_t;
  cb: ptr jebp_io_callbacks; user: pointer): jebp_error_t {.importc.}

proc jebp_error_string(err: jebp_error_t): cstring {.importc.}

proc jebp_free_image(image: ptr jebp_image_t) {.importc.}
{.pop.}

proc myRead(data: pointer; size: csize_t; user: pointer): csize_t {.cdecl.} =
  var n = csize_t(0)
  while n < size:
    let i = read(STDIN_FILENO, addr cast[ptr UncheckedArray[char]](data)[n],
      int(size - n))
    if i == 0:
      break
    n += csize_t(i)
  return n

proc writeAll(data: pointer; size: int) =
  var n = 0
  while n < size:
    let i = write(STDOUT_FILENO, addr cast[ptr UncheckedArray[uint8]](data)[n],
      int(size) - n)
    assert i >= 0
    n += i

proc puts(s: string) =
  if s.len > 0:
    writeAll(unsafeAddr s[0], s.len)

proc die(s: string) {.noreturn.} =
  puts(s)
  quit(1)

proc main() =
  enterNetworkSandbox()
  let scheme = getEnv("MAPPED_URI_SCHEME")
  let f = scheme.after('+')
  case getEnv("MAPPED_URI_PATH")
  of "decode":
    if f != "webp":
      die("Cha-Control: ConnectionError 1 unknown format " & f)
    let headers = getEnv("REQUEST_HEADERS")
    var targetWidth = cint(-1)
    var targetHeight = cint(-1)
    var infoOnly = false
    for hdr in headers.split('\n'):
      let v = hdr.after(':').strip()
      case hdr.until(':')
      of "Cha-Image-Info-Only":
        infoOnly = v == "1"
      of "Cha-Image-Target-Dimensions":
        let s = v.split('x')
        if s.len != 2:
          die("Cha-Control: ConnectionError 1 wrong dimensions\n")
        let w = parseUInt32(s[0], allowSign = false)
        let h = parseUInt32(s[1], allowSign = false)
        if w.isNone or w.isNone:
          die("Cha-Control: ConnectionError 1 wrong dimensions\n")
        targetWidth = cint(w.get)
        targetHeight = cint(h.get)
    var image = jebp_image_t()
    var cb = jebp_io_callbacks(read: myRead)
    if infoOnly:
      let res = jebp_read_size_from_callbacks(addr image, addr cb, nil)
      if res == 0:
        puts("Cha-Image-Dimensions: " & $image.width & "x" &
          $image.height & "\n\n")
        quit(0)
      else:
        die("Cha-Control: ConnectionError 1 jepb error " &
          $jebp_error_string(res))
    let res = jebp_read_from_callbacks(addr image, addr cb, nil)
    if res != 0:
      die("Cha-Control: ConnectionError 1 jebp error " &
        $jebp_error_string(res))
    else:
      puts("Cha-Image-Dimensions: " & $image.width & "x" & $image.height &
        "\n\n")
      writeAll(image.pixels, image.width * image.height * 4)
      jebp_free_image(addr image)
  of "encode":
    die("Cha-Control: ConnectionError 1 not supported")

main()
