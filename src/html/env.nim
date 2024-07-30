import std/selectors
import std/tables

import html/catom
import html/chadombuilder
import html/dom
import html/event
import html/formdata
import html/script
import html/xmlhttprequest
import io/dynstream
import io/promise
import js/base64
import js/console
import js/domexception
import js/encoding
import js/intl
import js/timeout
import loader/headers
import loader/loader
import loader/request
import loader/response
import monoucha/javascript
import monoucha/jserror
import monoucha/jspropenumlist
import monoucha/jstypes
import monoucha/quickjs
import monoucha/tojs
import types/blob
import types/opt
import types/url
import types/winattrs

# NavigatorID
proc appCodeName(navigator: var Navigator): string {.jsfget.} = "Mozilla"
proc appName(navigator: var Navigator): string {.jsfget.} = "Netscape"
proc appVersion(navigator: var Navigator): string {.jsfget.} = "5.0 (Windows)"
proc platform(navigator: var Navigator): string {.jsfget.} = "Win32"
proc product(navigator: var Navigator): string {.jsfget.} = "Gecko"
proc productSub(navigator: var Navigator): string {.jsfget.} = "20100101"
proc userAgent(navigator: var Navigator): string {.jsfget.} =
  #TODO TODO TODO this should be configurable
  "chawan"
proc vendor(navigator: var Navigator): string {.jsfget.} = ""
proc vendorSub(navigator: var Navigator): string {.jsfget.} = ""
proc taintEnabled(navigator: var Navigator): bool {.jsfget.} = false
proc oscpu(navigator: var Navigator): string {.jsfget.} = "Windows NT 10.0"

# NavigatorLanguage
proc language(navigator: var Navigator): string {.jsfget.} = "en-US"
proc languages(navigator: var Navigator): seq[string] {.jsfget.} =
  @["en-US"] #TODO frozen array?

# NavigatorOnline
proc onLine(navigator: var Navigator): bool {.jsfget.} =
  true # at the very least, the terminal is on-line :)

#TODO NavigatorContentUtils

# NavigatorCookies
# "this website needs cookies to be enabled to function correctly"
# It's probably better to lie here.
proc cookieEnabled(navigator: var Navigator): bool {.jsfget.} = true

# NavigatorPlugins
proc pdfViewerEnabled(navigator: var Navigator): bool {.jsfget.} = false
proc javaEnabled(navigator: var Navigator): bool {.jsfunc.} = false
proc namedItem(pluginArray: var PluginArray): string {.jsfunc.} = ""
proc namedItem(mimeTypeArray: var MimeTypeArray): string {.jsfunc.} = ""
proc item(pluginArray: var PluginArray): JSValue {.jsfunc.} = JS_NULL
proc length(pluginArray: var PluginArray): uint32 {.jsfget.} = 0
proc item(mimeTypeArray: var MimeTypeArray): JSValue {.jsfunc.} = JS_NULL
proc length(mimeTypeArray: var MimeTypeArray): uint32 {.jsfget.} = 0
proc getter(pluginArray: var PluginArray; i: uint32): Option[JSValue]
    {.jsgetprop.} =
  discard
proc getter(mimeTypeArray: var MimeTypeArray; i: uint32): Option[JSValue]
    {.jsgetprop.} =
  discard

# Screen
proc availWidth(screen: var Screen): int64 {.jsfget.} =
  #TODO this is a fingerprinting vector, but users should be able to allow it
  # selectively
  # for now just return something standard-ish
  80 * 9
proc availHeight(screen: var Screen): int64 {.jsfget.} =
  #TODO see above
  24 * 18
proc width(screen: var Screen): int64 {.jsfget.} =
  screen.availWidth
proc height(screen: var Screen): int64 {.jsfget.} =
  screen.availHeight
proc colorDepth(screen: var Screen): int64 {.jsfget.} = 24
proc pixelDepth(screen: var Screen): int64 {.jsfget.} = screen.colorDepth

# History
func length(history: var History): uint32 {.jsfget.} = 1
func state(history: var History): JSValue {.jsfget.} = JS_NULL
func go(history: var History) {.jsfunc.} = discard
func back(history: var History) {.jsfunc.} = discard
func forward(history: var History) {.jsfunc.} = discard

# Storage
func find(this: Storage; key: string): int =
  for i in 0 ..< this.map.len:
    if this.map[i].key == key:
      return i
  return -1

func length(this: var Storage): uint32 {.jsfget.} =
  return uint32(this.map.len)

func key(this: var Storage; i: uint32): Option[string] {.jsfunc.} =
  if int(i) < this.map.len:
    return some(this.map[int(i)].value)
  return none(string)

func getItem(this: var Storage; s: string): Option[string]
    {.jsfunc.} =
  let i = this.find(s)
  if i != -1:
    return some(this.map[i].value)
  return none(string)

func setItem(this: var Storage; key, value: string):
    Err[DOMException] {.jsfunc.} =
  let i = this.find(key)
  if i != -1:
    this.map[i].value = value
  else:
    if this.map.len >= 64:
      return errDOMException("Quota exceeded", "QuotaExceededError")
    this.map.add((key, value))
  ok()

func removeItem(this: var Storage; key: string) {.jsfunc.} =
  let i = this.find(key)
  if i != -1:
    this.map.del(i)

func names(ctx: JSContext; this: var Storage): JSPropertyEnumList
    {.jspropnames.} =
  var list = newJSPropertyEnumList(ctx, uint32(this.map.len))
  for it in this.map:
    list.add(it.key)
  return list

func getter(this: var Storage; s: string): Option[string]
    {.jsgetprop.} =
  return this.getItem(s)

func setter(this: var Storage; k, v: string): Err[DOMException]
    {.jssetprop.} =
  return this.setItem(k, v)

func delete(this: var Storage; k: string): bool {.jsdelprop.} =
  this.removeItem(k)
  return true

proc addNavigatorModule*(ctx: JSContext) =
  ctx.registerType(Navigator)
  ctx.registerType(PluginArray)
  ctx.registerType(MimeTypeArray)
  ctx.registerType(Screen)
  ctx.registerType(History)
  ctx.registerType(Storage)

proc fetch(window: Window; input: JSValue; init = none(RequestInit)):
    JSResult[FetchPromise] {.jsfunc.} =
  let input = ?newRequest(window.jsctx, input, init)
  #TODO cors requests?
  if not window.settings.origin.isSameOrigin(input.request.url.origin):
    let promise = newPromise[JSResult[Response]]()
    let err = newTypeError("NetworkError when attempting to fetch resource")
    promise.resolve(JSResult[Response].err(err))
    return ok(promise)
  return ok(window.loader.fetch(input.request))

# Forward declaration hack
windowFetch = fetch

proc setTimeout(window: Window; handler: JSValue; timeout = 0i32;
    args: varargs[JSValue]): int32 {.jsfunc.} =
  return window.timeouts.setTimeout(ttTimeout, handler, timeout, args)

proc setInterval(window: Window; handler: JSValue; interval = 0i32;
    args: varargs[JSValue]): int32 {.jsfunc.} =
  return window.timeouts.setTimeout(ttInterval, handler, interval, args)

proc clearTimeout(window: Window; id: int32) {.jsfunc.} =
  window.timeouts.clearTimeout(id)

proc clearInterval(window: Window; id: int32) {.jsfunc.} =
  window.clearTimeout(id)

func console(window: Window): Console {.jsfget.} =
  return window.internalConsole

proc screenX(window: Window): int64 {.jsfget.} = 0
proc screenY(window: Window): int64 {.jsfget.} = 0
proc screenLeft(window: Window): int64 {.jsfget.} = 0
proc screenTop(window: Window): int64 {.jsfget.} = 0
proc outerWidth(window: Window): int64 {.jsfget.} =
  window.screen.availWidth
proc outerHeight(window: Window): int64 {.jsfget.} =
  window.screen.availHeight
proc devicePixelRatio(window: Window): float64 {.jsfget.} = 1

proc setLocation(window: Window; s: string): Err[JSError]
    {.jsfset: "location".} =
  if window.document == nil:
    return errTypeError("document is null")
  return window.document.setLocation(s)

func getWindow(window: Window): Window {.jsuffget: "window".} =
  return window

#TODO [Replaceable]
func getSelf(window: Window): Window {.jsfget: "self".} =
  return window

#TODO [Replaceable]
func getFrames(window: Window): Window {.jsfget: "frames".} =
  return window

func getTop(window: Window): Window {.jsuffget: "top".} =
  return window #TODO frames?

#TODO [Replaceable]
func getParent(window: Window): Window {.jsfget: "parent".} =
  return window #TODO frames?

proc atob(window: Window; data: string): DOMResult[NarrowString] {.jsfunc.} =
  return atob(data)

proc btoa(ctx: JSContext; window: Window; data: JSValue): DOMResult[string]
    {.jsfunc.} =
  return btoa(ctx, data)

proc alert(window: Window; s: string) {.jsfunc.} =
  window.console.error(s)

proc getComputedStyle(window: Window; element: Element;
    pseudoElt = none(Element)): JSResult[CSSStyleDeclaration] {.jsfunc.} =
  #TODO implement this properly
  return ok(element.style)

proc setOnLoad(ctx: JSContext; window: Window; val: JSValue)
    {.jsfset: "onload".} =
  if JS_IsFunction(ctx, val):
    let this = ctx.toJS(window)
    ctx.definePropertyC(this, "onload", JS_DupValue(ctx, val))
    #TODO I haven't checked but this might also be wrong
    doAssert ctx.addEventListener(window, window.toAtom(satLoad), val).isSome
    JS_FreeValue(ctx, this)

proc addWindowModule*(ctx: JSContext) =
  ctx.addEventModule()
  let eventTargetCID = ctx.getClass("EventTarget")
  ctx.registerType(Window, parent = eventTargetCID, asglobal = true)

proc addWindowModule2*(ctx: JSContext) =
  ctx.addEventModule()
  let eventTargetCID = ctx.getClass("EventTarget")
  ctx.registerType(Window, parent = eventTargetCID, asglobal = true,
    globalparent = true)

proc addScripting*(window: Window; selector: Selector[int]) =
  let rt = newJSRuntime()
  let ctx = rt.newJSContext()
  window.jsrt = rt
  window.jsctx = ctx
  window.importMapsAllowed = true
  window.timeouts = newTimeoutState(
    selector = selector,
    jsctx = ctx,
    err = window.console.err,
    evalJSFree = (proc(src, file: string) =
      let ret = window.jsctx.eval(src, file, JS_EVAL_TYPE_GLOBAL)
      if JS_IsException(ret):
        window.console.log("Exception in document", $window.document.url,
          window.jsctx.getExceptionMsg())
      else:
        JS_FreeValue(ctx, ret)
    )
  )
  ctx.addWindowModule()
  ctx.setGlobal(window)
  ctx.addDOMExceptionModule()
  ctx.addConsoleModule()
  ctx.addNavigatorModule()
  ctx.addDOMModule()
  ctx.addURLModule()
  ctx.addHTMLModule()
  ctx.addIntlModule()
  ctx.addBlobModule()
  ctx.addFormDataModule()
  ctx.addXMLHttpRequestModule()
  ctx.addHeadersModule()
  ctx.addRequestModule()
  ctx.addResponseModule()
  ctx.addEncodingModule()

proc runJSJobs*(window: Window) =
  while true:
    let r = window.jsrt.runJSJobs()
    if r.isSome:
      break
    let ctx = r.error
    ctx.writeException(window.console.err)

proc newWindow*(scripting, images, styling: bool; selector: Selector[int];
    attrs: WindowAttributes; factory: CAtomFactory; loader: FileLoader;
    url: URL): Window =
  let err = newDynFileStream(stderr)
  let window = Window(
    attrs: attrs,
    internalConsole: newConsole(err),
    navigator: Navigator(),
    loader: loader,
    images: images,
    styling: styling,
    settings: EnvironmentSettings(
      scripting: scripting,
      origin: url.origin
    ),
    factory: factory
  )
  window.location = window.newLocation()
  if scripting:
    window.addScripting(selector)
  return window
