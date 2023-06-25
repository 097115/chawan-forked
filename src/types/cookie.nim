import strutils
import times

import io/urlfilter
import js/javascript
import js/regex
import types/url
import utils/opt
import utils/twtstr

type
  Cookie* = ref object
    created: int64 # unix time
    name {.jsget.}: string
    value {.jsget.}: string
    expires {.jsget.}: int64 # unix time
    secure {.jsget.}: bool
    httponly {.jsget.}: bool
    samesite {.jsget.}: bool
    domain {.jsget.}: string
    path {.jsget.}: string

  CookieJar* = ref object
    filter*: URLFilter
    cookies*: seq[Cookie]

proc parseCookieDate(val: string): Option[DateTime] =
  # cookie-date
  const Delimiters = {'\t', ' '..'/', ';'..'@', '['..'`', '{'..'~'}
  const NonDigit = AllChars - AsciiDigit
  var foundTime = false
  var foundDayOfMonth = false
  var foundMonth = false
  var foundYear = false
  # date-token-list
  var time: array[3, int]
  var dayOfMonth: int
  var month: int
  var year: int
  for dateToken in val.split(Delimiters):
    if dateToken == "": continue # *delimiter
    if not foundTime:
      block timeBlock: # test for time
        let hmsTime = dateToken.until(NonDigit - {':'})
        var i = 0
        for timeField in hmsTime.split(':'):
          if i > 2: break timeBlock # too many time fields
          # 1*2DIGIT
          if timeField.len != 1 and timeField.len != 2: break timeBlock
          var timeFields: array[3, int]
          for c in timeField:
            if c notin AsciiDigit: break timeBlock
            timeFields[i] *= 10
            timeFields[i] += c.decValue
          time = timeFields
          inc i
        if i != 3: break timeBlock
        foundTime = true
        continue
    if not foundDayOfMonth:
      block dayOfMonthBlock: # test for day-of-month
        let digits = dateToken.until(NonDigit)
        if digits.len != 1 and digits.len != 2: break dayOfMonthBlock
        var n = 0
        for c in digits:
          if c notin AsciiDigit: break dayOfMonthBlock
          n *= 10
          n += c.decValue
        dayOfMonth = n
        foundDayOfMonth = true
        continue
    if not foundMonth:
      block monthBlock: # test for month
        if dateToken.len < 3: break monthBlock
        case dateToken.substr(0, 2).toLower()
        of "jan": month = 1
        of "feb": month = 2
        of "mar": month = 3
        of "apr": month = 4
        of "may": month = 5
        of "jun": month = 6
        of "jul": month = 7
        of "aug": month = 8
        of "sep": month = 9
        of "oct": month = 10
        of "nov": month = 11
        of "dec": month = 12
        else: break monthBlock
        foundMonth = true
        continue
    if not foundYear:
      block yearBlock: # test for year
        let digits = dateToken.until(NonDigit)
        if digits.len != 2 and digits.len != 4: break yearBlock
        var n = 0
        for c in digits:
          if c notin AsciiDigit: break yearBlock
          n *= 10
          n += c.decValue
        year = n
        foundYear = true
        continue
  if not (foundDayOfMonth and foundMonth and foundYear and foundTime): return none(DateTime)
  if dayOfMonth notin 0..31: return none(DateTime)
  if year < 1601: return none(DateTime)
  if time[0] > 23: return none(DateTime)
  if time[1] > 59: return none(DateTime)
  if time[2] > 59: return none(DateTime)
  var dateTime = dateTime(year, Month(month), MonthdayRange(dayOfMonth), HourRange(time[0]), MinuteRange(time[1]), SecondRange(time[2]))
  return some(dateTime)

# For debugging
proc `$`*(cookiejar: CookieJar): string =
  result &= $cookiejar.filter
  result &= "\n"
  for cookie in cookiejar.cookies:
    result &= "Cookie "
    result &= $cookie[]
    result &= "\n"

# https://www.rfc-editor.org/rfc/rfc6265#section-5.1.4
func defaultCookiePath(url: URL): string =
  let path = ($url.path).beforeLast('/')
  if path == "" or path[0] != '/':
    return "/"
  return path

func cookiePathMatches(cookiePath, requestPath: string): bool =
  if requestPath.startsWith(cookiePath):
    if requestPath.len == cookiePath.len:
      return true
    if cookiePath[^1] == '/':
      return true
    if requestPath.len > cookiePath.len and requestPath[cookiePath.len] == '/':
      return true
  return false

# I have no clue if this is actually compliant, because the spec is worded
# so badly.
# Either way, this implementation is needed for compatibility.
# (Here is this part of the spec in its full glory:
#   A string domain-matches a given domain string if at least one of the
#   following conditions hold:
#   o  The domain string and the string are identical.  (Note that both
#      the domain string and the string will have been canonicalized to
#      lower case at this point.)
#   o  All of the following conditions hold:
#      *  The domain string is a suffix of the string.
#      *  The last character of the string that is not included in the
#         domain string is a %x2E (".") character. (???)
#      *  The string is a host name (i.e., not an IP address).)
func cookieDomainMatches(cookieDomain: string, url: URL): bool =
  let host = url.host
  if host == cookieDomain:
    return true
  if url.isIP():
    return false
  let cookieDomain = if cookieDomain.len > 0 and cookieDomain[0] == '.':
    cookieDomain.substr(1)
  else:
    cookieDomain
  return host.endsWith(cookieDomain)

proc add*(cookiejar: CookieJar, cookie: Cookie) =
  var i = -1
  for j in 0 ..< cookieJar.cookies.len:
    let old = cookieJar.cookies[j]
    if old.name == cookie.name and old.domain == cookie.domain and
        old.path == cookie.path:
      i = j
      break
  if i != -1:
    let old = cookieJar.cookies[i]
    cookie.created = old.created
    cookieJar.cookies.del(i)
  cookieJar.cookies.add(cookie)

proc add*(cookiejar: CookieJar, cookies: seq[Cookie]) =
  for cookie in cookies:
    cookiejar.add(cookie)

# https://www.rfc-editor.org/rfc/rfc6265#section-5.4
proc serialize*(cookiejar: CookieJar, url: URL): string =
  if not cookiejar.filter.match(url):
    return "" # fail
  let t = now().toTime().toUnix()
  #TODO sort
  for i in countdown(cookiejar.cookies.high, 0):
    let cookie = cookiejar.cookies[i]
    if cookie.expires != -1 and cookie.expires <= t:
      cookiejar.cookies.delete(i)
      continue
    if cookie.secure and url.scheme != "https":
      continue
    if not cookiePathMatches(cookie.path, $url.path):
      continue
    if not cookieDomainMatches(cookie.domain, url):
      continue
    if result != "":
      result &= "; "
    result &= cookie.name
    result &= "="
    result &= cookie.value

proc newCookie*(str: string, url: URL = nil): Cookie {.jsctor.} =
  let cookie = new(Cookie)
  cookie.expires = -1
  cookie.created = now().toTime().toUnix()
  var first = true
  var haspath = false
  var hasdomain = false
  for part in str.split(';'):
    if first:
      cookie.name = part.until('=')
      cookie.value = part.after('=')
      first = false
      continue
    let part = part.strip(leading = true, trailing = false, AsciiWhitespace)
    var n = 0
    for i in 0..part.high:
      if part[i] == '=':
        n = i
        break
    if n == 0:
      continue
    let key = part.substr(0, n - 1)
    let val = part.substr(n + 1)
    case key.toLower()
    of "expires":
      let date = parseCookieDate(val)
      if date.issome:
        cookie.expires = date.get.toTime().toUnix()
    of "max-age":
      let x = parseInt64(val)
      if x.isSome:
        cookie.expires = cookie.created + x.get
    of "secure": cookie.secure = true
    of "httponly": cookie.httponly = true
    of "samesite": cookie.samesite = true
    of "path":
      if val != "" and val[0] == '/':
        haspath = true
        cookie.path = val
    of "domain":
      if url == nil or cookieDomainMatches(val, url):
        cookie.domain = val
        hasdomain = true
      else:
        #TODO error, abort
        hasdomain = false
  if not hasdomain:
    if url != nil:
      cookie.domain = url.host
  if not haspath:
    if url == nil:
      cookie.path = "/"
    else:
      cookie.path = defaultCookiePath(url)
  return cookie

proc newCookieJar*(location: URL, allowhosts: seq[Regex]): CookieJar =
  return CookieJar(
    filter: newURLFilter(
      scheme = some(location.scheme),
      allowhost = some(location.host),
      allowhosts = allowhosts
    )
  )

proc addCookieModule*(ctx: JSContext) =
  ctx.registerType(Cookie)
