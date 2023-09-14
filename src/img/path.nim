import algorithm
import deques
import math

import types/line
import types/vector
import js/domexception
import types/opt

type
  Path* = ref object
    subpaths: seq[Subpath]
    needsNewSubpath: bool
    tempClosed: bool

  PathLines* = object
    lines*: seq[LineSegment]
    miny*: float64
    maxy*: float64

  PathSegmentType = enum
    SEGMENT_STRAIGHT, SEGMENT_QUADRATIC, SEGMENT_BEZIER, SEGMENT_ARC,
    SEGMENT_ELLIPSE

  PathSegment = object
    case t: PathSegmentType
    of SEGMENT_QUADRATIC:
      cp: Vector2D
    of SEGMENT_BEZIER:
      cp0: Vector2D
      cp1: Vector2D
    of SEGMENT_ARC:
      oa: Vector2D
      r: float64
      ia: bool
    of SEGMENT_ELLIPSE:
      oe: Vector2D
      rx: float64
      ry: float64
    else: discard

  Subpath* = object
    points: seq[Vector2D]
    segments: seq[PathSegment]
    closed: bool

proc newPath*(): Path =
  return Path(
    needsNewSubpath: true
  )

proc addSubpathAt(path: Path, p: Vector2D) =
  path.subpaths.add(Subpath(points: @[p]))

proc addSegment(path: Path, segment: PathSegment, p: Vector2D) =
  path.subpaths[^1].segments.add(segment)
  path.subpaths[^1].points.add(p)

proc addStraightSegment(path: Path, p: Vector2D) =
  let segment = PathSegment(t: SEGMENT_STRAIGHT)
  path.addSegment(segment, p)

proc addQuadraticSegment(path: Path, cp, p: Vector2D) =
  let segment = PathSegment(
    t: SEGMENT_QUADRATIC,
    cp: cp
  )
  path.addSegment(segment, p)

proc addBezierSegment(path: Path, cp0, cp1, p: Vector2D) =
  let segment = PathSegment(
    t: SEGMENT_BEZIER,
    cp0: cp0,
    cp1: cp1
  )
  path.addSegment(segment, p)

# Goes from start tangent point to end tangent point
proc addArcSegment(path: Path, o, etan: Vector2D, r: float64, ia: bool) =
  let segment = PathSegment(
    t: SEGMENT_ARC,
    oa: o,
    r: r,
    ia: ia
  )
  path.addSegment(segment, etan)

proc addEllipseSegment(path: Path, o, etan: Vector2D, rx, ry: float64) =
  #TODO simplify to bezier?
  let segment = PathSegment(
    t: SEGMENT_ELLIPSE,
    oe: o,
    rx: rx,
    ry: ry
  )
  path.addSegment(segment, etan)

# https://hcklbrrfnn.files.wordpress.com/2012/08/bez.pdf
func flatEnough(a, b, c: Vector2D): bool =
  let ux = 3 * c.x - 2 * a.x - b.x
  let uy = 3 * c.y - 2 * a.y - b.y
  let vx = 3 * c.x - 2 * b.x - b.x
  let vy = 3 * c.y - 2 * b.y - b.y
  return max(ux * ux, vx * vx) + max(uy * uy, vy * vy) <= 0.02

func flatEnough(a, b, c0, c1: Vector2D): bool =
  let ux = 3 * c0.x - 2 * a.x - b.x
  let uy = 3 * c0.y - 2 * a.y - b.y
  let vx = 3 * c1.x - a.x - 2 * b.x
  let vy = 3 * c1.y - a.y - 2 * b.y
  return max(ux * ux, vx * vx) + max(uy * uy, vy * vy) <= 0.02

iterator items*(pl: PathLines): LineSegment {.inline.} =
  for line in pl.lines:
    yield line

func `[]`*(pl: PathLines, i: int): LineSegment = pl.lines[i]
func `[]`*(pl: PathLines, i: BackwardsIndex): LineSegment = pl.lines[i]
func `[]`*(pl: PathLines, s: Slice[int]): seq[LineSegment] = pl.lines[s]
func len*(pl: PathLines): int = pl.lines.len

iterator quadraticLines(a, b, c: Vector2D): Line {.inline.} =
  var points: Deque[tuple[a, b, c: Vector2D]]
  let tup = (a, b, c)
  points.addFirst(tup)
  while points.len > 2:
    let (a, b, c) = points.popFirst()
    if flatEnough(a, b, c):
      yield Line(p0: a, p1: b)
    else:
      let mid1 = (c + a) / 2
      let mid2 = (c + b) / 2
      let s = (mid1 + mid2) / 2
      points.addFirst((a, s, mid1))
      points.addFirst((s, b, mid2))

iterator bezierLines(p0, p1, c0, c1: Vector2D): Line {.inline.} =
  var points: Deque[tuple[p0, p1, c0, c1: Vector2D]]
  let tup = (p0, p1, c0, c1)
  points.addLast(tup)
  while points.len > 0:
    let (p0, p1, c0, c1) = points.popFirst()
    if flatEnough(p0, p1, c0, c1):
      yield Line(p0: p0, p1: p1)
    else:
      let mida1 = (p0 + c0) / 2
      let mida2 = (c0 + c1) / 2
      let mida3 = (c1 + p1) / 2
      let midb1 = (mida1 + mida2) / 2
      let midb2 = (mida2 + mida3) / 2
      let midc = (midb1 + midb2) / 2
      points.addLast((p0, midc, mida1, midb1))
      points.addLast((midc, p1, midb2, mida3))

# https://stackoverflow.com/a/44829356
func arcControlPoints(p1, p4, o: Vector2D): tuple[c0, c1: Vector2D] =
  let a = p1 - o
  let b = p4 - o
  let q1 = a.x * a.x + a.y * a.y
  let q2 = q1 + a.x * b.x + a.y * b.y
  let k2 = (4 / 3) * (sqrt(2 * q1 * q2) - q2) / a.cross(b)
  let c0 = o + a + Vector2D(x: -k2 * a.y, y:  k2 * a.x)
  let c1 = o + b + Vector2D(x:  k2 * b.y, y: -k2 * b.x)
  return (c0, c1)

iterator arcLines(p0, p1, o: Vector2D, r: float64, i: bool): Line {.inline.} =
  var p0 = p0
  let pp0 = p0 - o
  let pp1 = p1 - o
  var theta = pp0.innerAngle(pp1)
  if not i:
    theta = PI * 2 - theta
  while theta > 0:
    let step = if theta > PI / 2: PI / 2 else: theta
    var p1 = p0 - o
    p1 = p1.rotate(step)
    p1 += o
    let (c0, c1) = arcControlPoints(p0, p1, o)
    for line in bezierLines(p0, p1, c0, c1):
      yield line
    p0 = p1
    theta -= step

iterator lines(subpath: Subpath, i: int): Line {.inline.} =
  let p0 = subpath.points[i]
  let p1 = subpath.points[i + 1]
  case subpath.segments[i].t
  of SEGMENT_STRAIGHT:
    yield Line(p0: p0, p1: p1)
  of SEGMENT_QUADRATIC:
    let c = subpath.segments[i].cp
    for line in quadraticLines(p0, p1, c):
      yield line
  of SEGMENT_BEZIER:
    let c0 = subpath.segments[i].cp0
    let c1 = subpath.segments[i].cp1
    for line in bezierLines(p0, p1, c0, c1):
      yield line
  of SEGMENT_ARC:
    let o = subpath.segments[i].oa
    let r = subpath.segments[i].r
    let i = subpath.segments[i].ia
    for line in arcLines(p0, p1, o, r, i):
      yield line
  of SEGMENT_ELLIPSE:
    discard #TODO

iterator lines*(path: Path): Line {.inline.} =
  for subpath in path.subpaths:
    assert subpath.points.len == subpath.segments.len + 1
    for i in 0 ..< subpath.segments.len:
      for line in subpath.lines(i):
        if line.p0 == line.p1:
          continue
        yield line

proc getLineSegments*(path: Path): PathLines =
  if path.subpaths.len == 0:
    return
  var miny = Inf
  var maxy = -Inf
  var segments: seq[LineSegment]
  for line in path.lines:
    let ls = LineSegment(line)
    miny = min(miny, ls.miny)
    maxy = max(maxy, ls.maxy)
    segments.add(ls)
  segments.sort(cmpLineSegmentY)
  return PathLines(
    miny: miny,
    maxy: maxy,
    lines: segments
  )

proc moveTo(path: Path, v: Vector2D) =
  path.addSubpathAt(v)
  path.needsNewSubpath = false #TODO TODO TODO ???? why here

proc beginPath*(path: Path) =
  path.subpaths.setLen(0)

proc moveTo*(path: Path, x, y: float64) =
  for v in [x, y]:
    if classify(v) in {fcInf, fcNegInf, fcNan}:
      return
  path.moveTo(Vector2D(x: x, y: y))

proc ensureSubpath(path: Path, x, y: float64) =
  if path.needsNewSubpath:
    path.moveTo(x, y)
    path.needsNewSubpath = false

proc closePath*(path: Path) =
  let lsp = path.subpaths[^1]
  if path.subpaths.len > 0 and (lsp.points.len > 0 or lsp.closed):
    path.subpaths[^1].closed = true
    path.addSubpathAt(path.subpaths[^1].points[0])

#TODO this is a hack, and breaks as soon as any draw command is issued
# between tempClosePath and tempOpenPath
proc tempClosePath*(path: Path) =
  if path.subpaths.len > 0 and not path.subpaths[^1].closed:
    path.subpaths[^1].closed = true
    let lsp = path.subpaths[^1]
    path.addSubpathAt(lsp.points[^1])
    path.addStraightSegment(lsp.points[0])
    path.tempClosed = true

proc tempOpenPath*(path: Path) =
  if path.tempClosed:
    path.subpaths.setLen(path.subpaths.len - 1)
    path.subpaths[^1].closed = false
    path.tempClosed = false

proc lineTo*(path: Path, x, y: float64) =
  for v in [x, y]:
    if classify(v) in {fcInf, fcNegInf, fcNan}:
      return
  if path.subpaths.len == 0:
    path.ensureSubpath(x, y)
  else:
    path.addStraightSegment(Vector2D(x: x, y: y))

proc quadraticCurveTo*(path: Path, cpx, cpy, x, y: float64) =
  for v in [cpx, cpy, x, y]:
    if classify(v) in {fcInf, fcNegInf, fcNan}:
      return
  path.ensureSubpath(cpx, cpy)
  let cp = Vector2D(x: cpx, y: cpy)
  let p = Vector2D(x: x, y: y)
  path.addQuadraticSegment(cp, p)

proc bezierCurveTo*(path: Path, cp0x, cp0y, cp1x, cp1y, x, y: float64) =
  for v in [cp0x, cp0y, cp1x, cp1y, x, y]:
    if classify(v) in {fcInf, fcNegInf, fcNan}:
      return
  path.ensureSubpath(cp0x, cp0y)
  let cp0 = Vector2D(x: cp0x, y: cp0y)
  let cp1 = Vector2D(x: cp1x, y: cp1y)
  let p = Vector2D(x: x, y: y)
  path.addBezierSegment(cp0, cp1, p)

proc arcTo*(path: Path, x1, y1, x2, y2, radius: float64): Err[DOMException] =
  for v in [x1, y1, x2, y2, radius]:
    if classify(v) in {fcInf, fcNegInf, fcNan}:
      return ok()
  if radius < 0:
    return err(newDOMException("Expected positive radius, but got negative",
      "IndexSizeError"))
  path.ensureSubpath(x1, y1)
  #TODO this should be transformed by the inverse of the transformation matrix
  let v0 = path.subpaths[^1].points[^1]
  let v1 = Vector2D(x: x1, y: y1)
  let v2 = Vector2D(x: x2, y: y2)
  if v0.x == x1 and v0.y == y1 or x1 == x2 and y1 == y2 or radius == 0:
    path.addStraightSegment(v1)
  elif collinear(v0, v1, v2):
    path.addStraightSegment(v1)
  else:
    let pv0 = v0 - v1
    let pv2 = v2 - v1
    let tv0 = v1 + pv0 * radius * 2 / pv0.norm()
    let tv2 = v1 + pv2 * radius * 2 / pv2.norm()
    let q = -(pv0.x * tv0.x + pv0.y * tv0.y)
    let p = -(pv2.x * tv2.x + pv2.y * tv2.y)
    let cr = pv0.cross(pv2)
    let origin = Vector2D(
      x: (pv0.y * p - pv2.y * q) / cr,
      y: (pv2.x * q - pv0.x * p) / cr
    )
    path.addStraightSegment(tv0)
    path.addArcSegment(origin, tv2, radius, true) #TODO always inner?
  return ok()

func resolveEllipsePoint(o: Vector2D, angle, radiusX, radiusY,
    rotation: float64): Vector2D =
  # Stolen from SerenityOS
  let tanrel = tan(angle)
  let tan2 = tanrel * tanrel
  let ab = radiusX * radiusY
  let a2 = radiusX * radiusX
  let b2 = radiusY * radiusY
  let sq = sqrt(b2 + a2 * tan2)
  let sn = if cos(angle) >= 0: 1f64 else: -1f64
  let relx = ab / sq * sn
  let rely = ab * tanrel / sq * sn
  return Vector2D(x: relx, y: rely).rotate(rotation) + o

proc arc*(path: Path, x, y, radius, startAngle, endAngle: float64,
    counterclockwise: bool): Err[DOMException] =
  for v in [x, y, radius, startAngle, endAngle]:
    if classify(v) in {fcInf, fcNegInf, fcNan}:
      return ok()
  if radius < 0:
    return err(newDOMException("Expected positive radius, but got negative",
      "IndexSizeError"))
  let o = Vector2D(x: x, y: y)
  var s = resolveEllipsePoint(o, startAngle, radius, radius, 0)
  var e = resolveEllipsePoint(o, endAngle, radius, radius, 0)
  if counterclockwise:
    let tmp = s
    e = s
    s = tmp
  if path.subpaths.len > 0:
    path.addStraightSegment(s)
  else:
    path.moveTo(s)
  path.addArcSegment(o, e, radius, abs(startAngle - endAngle) < PI)
  return ok()

proc ellipse*(path: Path, x, y, radiusX, radiusY, rotation, startAngle,
    endAngle: float64, counterclockwise: bool): Err[DOMException] =
  for v in [x, y, radiusX, radiusY, rotation, startAngle, endAngle]:
    if classify(v) in {fcInf, fcNegInf, fcNan}:
      return ok()
  if radiusX < 0 or radiusY < 0:
    return err(newDOMException("Expected positive radius, but got negative",
      "IndexSizeError"))
  let o = Vector2D(x: x, y: y)
  var s = resolveEllipsePoint(o, startAngle, radiusX, radiusY, rotation)
  var e = resolveEllipsePoint(o, endAngle, radiusX, radiusY, rotation)
  if counterclockwise:
    let tmp = s
    e = s
    s = tmp
  if path.subpaths.len > 0:
    path.addStraightSegment(s)
  else:
    path.moveTo(s)
  path.addEllipseSegment(o, e, radiusX, radiusY)
  return ok()

proc rect*(path: Path, x, y, w, h: float64) =
  for v in [x, y, w, h]:
    if classify(v) in {fcInf, fcNegInf, fcNan}:
      return
  path.addSubpathAt(Vector2D(x: x, y: y))
  path.addStraightSegment(Vector2D(x: x + w, y: y))
  path.addStraightSegment(Vector2D(x: x + w, y: y + h))
  path.addStraightSegment(Vector2D(x: x, y: y + h))
  path.addStraightSegment(Vector2D(x: x, y: y))
  path.addSubpathAt(Vector2D(x: x, y: y))

proc roundRect*(path: Path, x, y, w, h, radii: float64) =
  for v in [x, y, w, h]:
    if classify(v) in {fcInf, fcNegInf, fcNan}:
      return
  #TODO implement
  path.rect(x, y, w, h) # :P
