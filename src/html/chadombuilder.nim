import deques
import options
import streams

import html/dom
import html/enums
import js/error
import js/fromjs
import js/javascript
import types/url

import chakasu/charset

import chame/htmlparser
import chame/htmltokenizer
import chame/tags

# DOMBuilder implementation for Chawan.

type
  ChaDOMBuilder = ref object of DOMBuilder[Node]
    isFragment: bool

type DOMParser = ref object # JS interface

jsDestructor(DOMParser)

template getDocument(dombuilder: ChaDOMBuilder): Document =
  cast[Document](dombuilder.document)

proc finish(builder: DOMBuilder[Node]) =
  let builder = cast[ChaDOMBuilder](builder)
  let document = builder.getDocument()
  while document.scriptsToExecOnLoad.len > 0:
    #TODO spin event loop
    let script = document.scriptsToExecOnLoad.popFirst()
    script.execute()
  #TODO events

proc restart(builder: DOMBuilder[Node]) =
  let document = newDocument()
  document.contentType = "text/html"
  let oldDocument = cast[Document](builder.document)
  document.url = oldDocument.url
  let window = oldDocument.window
  if window != nil:
    document.window = window
    window.document = document
  builder.document = document

proc parseError(builder: DOMBuilder[Node], message: string) =
  discard

proc setQuirksMode(builder: DOMBuilder[Node], quirksMode: QuirksMode) =
  let builder = cast[ChaDOMBuilder](builder)
  let document = builder.getDocument()
  if not document.parser_cannot_change_the_mode_flag:
    document.mode = quirksMode

proc setCharacterSet(builder: DOMBuilder[Node], charset: Charset) =
  let builder = cast[ChaDOMBuilder](builder)
  let document = builder.getDocument()
  document.charset = charset

proc getTemplateContent(builder: DOMBuilder[Node], handle: Node): Node =
  return HTMLTemplateElement(handle).content

proc getTagType(builder: DOMBuilder[Node], handle: Node): TagType =
  return Element(handle).tagType

proc getParentNode(builder: DOMBuilder[Node], handle: Node): Option[Node] =
  return option(handle.parentNode)

proc getLocalName(builder: DOMBuilder[Node], handle: Node): string =
  return Element(handle).localName

proc getNamespace(builder: DOMBuilder[Node], handle: Node): Namespace =
  return Element(handle).namespace

proc createElement(builder: DOMBuilder[Node], localName: string,
    namespace: Namespace, tagType: TagType,
    attrs: Table[string, string]): Node =
  let builder = cast[ChaDOMBuilder](builder)
  let document = builder.getDocument()
  let element = document.newHTMLElement(localName, namespace,
    tagType = tagType, attrs = attrs)
  if element.isResettable():
    element.resetElement()
  if tagType == TAG_SCRIPT:
    let script = HTMLScriptElement(element)
    script.parserDocument = document
    script.forceAsync = false
    if builder.isFragment:
      script.alreadyStarted = true
      #TODO document.write (?)
  return element

proc createComment(builder: DOMBuilder[Node], text: string): Node =
  let builder = cast[ChaDOMBuilder](builder)
  return builder.getDocument().createComment(text)

proc createDocumentType(builder: DOMBuilder[Node], name, publicId,
    systemId: string): Node =
  let builder = cast[ChaDOMBuilder](builder)
  return builder.getDocument().newDocumentType(name, publicId, systemId)

proc insertBefore(builder: DOMBuilder[Node], parent, child,
    before: Node) =
  discard parent.insertBefore(child, before)

proc insertText(builder: DOMBuilder[Node], parent: Node, text: string,
    before: Node) =
  let builder = cast[ChaDOMBuilder](builder)
  let prevSibling = if before != nil:
    before.previousSibling
  else:
    parent.lastChild
  if prevSibling != nil and prevSibling.nodeType == TEXT_NODE:
    Text(prevSibling).data &= text
  else:
    let text = builder.getDocument().createTextNode(text)
    discard parent.insertBefore(text, before)

proc remove(builder: DOMBuilder[Node], child: Node) =
  child.remove(suppressObservers = true)

proc moveChildren(builder: DOMBuilder[Node], fromNode, toNode: Node) =
  var tomove = fromNode.childList
  for node in tomove:
    node.remove(suppressObservers = true)
  for child in tomove:
    toNode.insert(child, nil)

proc addAttrsIfMissing(builder: DOMBuilder[Node], element: Node,
    attrs: Table[string, string]) =
  let element = Element(element)
  for k, v in attrs:
    if not element.attrb(k):
      element.attr(k, v)

proc setScriptAlreadyStarted(builder: DOMBuilder[Node], script: Node) =
  HTMLScriptElement(script).alreadyStarted = true

proc associateWithForm(builder: DOMBuilder[Node], element, form,
    intendedParent: Node) =
  if form.inSameTree(intendedParent):
    #TODO remove following test eventually
    if Element(element).tagType in SupportedFormAssociatedElements:
      let element = FormAssociatedElement(element)
      element.setForm(HTMLFormElement(form))
      element.parserInserted = true

proc elementPopped(builder: DOMBuilder[Node], element: Node) =
  let builder = cast[ChaDOMBuilder](builder)
  let document = builder.getDocument()
  let element = Element(element)
  if element.tagType == TAG_TEXTAREA:
    element.resetElement()
  elif element.tagType == TAG_SCRIPT:
    #TODO microtask (maybe it works here too?)
    let script = HTMLScriptElement(element)
    #TODO document.write() (?)
    script.prepare()
    while document.parserBlockingScript != nil:
      let script = document.parserBlockingScript
      document.parserBlockingScript = nil
      #TODO style sheet
      script.execute()

proc newChaDOMBuilder(url: URL, window: Window, isFragment = false):
    ChaDOMBuilder =
  let document = newDocument()
  document.contentType = "text/html"
  document.url = url
  if window != nil:
    document.window = window
    window.document = document
  return ChaDOMBuilder(
    document: document,
    finish: finish,
    restart: restart,
    setQuirksMode: setQuirksMode,
    setCharacterSet: setCharacterset,
    elementPopped: elementPopped,
    getTemplateContent: getTemplateContent,
    getTagType: getTagType,
    getParentNode: getParentNode,
    getLocalName: getLocalName,
    getNamespace: getNamespace,
    createElement: createElement,
    createComment: createComment,
    createDocumentType: createDocumentType,
    insertBefore: insertBefore,
    insertText: insertText,
    remove: remove,
    moveChildren: moveChildren,
    addAttrsIfMissing: addAttrsIfMissing,
    setScriptAlreadyStarted: setScriptAlreadyStarted,
    associateWithForm: associateWithForm,
    #TODO isSVGIntegrationPoint (SVG support)
    isFragment: isFragment
  )

# https://html.spec.whatwg.org/multipage/parsing.html#parsing-html-fragments
proc parseHTMLFragment*(element: Element, s: string): seq[Node] =
  let url = parseURL("about:blank").get
  let builder = newChaDOMBuilder(url, nil)
  builder.isFragment = true
  let document = Document(builder.document)
  document.mode = element.document.mode
  let state = case element.tagType
  of TAG_TITLE, TAG_TEXTAREA: RCDATA
  of TAG_STYLE, TAG_XMP, TAG_IFRAME, TAG_NOEMBED, TAG_NOFRAMES: RAWTEXT
  of TAG_SCRIPT: SCRIPT_DATA
  of TAG_NOSCRIPT:
    if element.document != nil and element.document.scriptingEnabled:
      RAWTEXT
    else:
      DATA
  of TAG_PLAINTEXT:
    PLAINTEXT
  else: DATA
  let root = document.newHTMLElement(TAG_HTML)
  document.append(root)
  let opts = HTML5ParserOpts[Node](
    isIframeSrcdoc: false, #TODO?
    scripting: false,
    canReinterpret: false,
    charsets: @[CHARSET_UTF_8],
    ctx: some(Node(element)),
    initialTokenizerState: state,
    openElementsInit: @[Node(root)],
    pushInTemplate: element.tagType == TAG_TEMPLATE
  )
  let inputStream = newStringStream(s)
  parseHTML(inputStream, builder, opts)
  return root.childList

proc parseHTML*(inputStream: Stream, window: Window, url: URL,
    charsets: seq[Charset] = @[], canReinterpret = true): Document =
  let builder = newChaDOMBuilder(url, window)
  let opts = HTML5ParserOpts[Node](
    isIframeSrcdoc: false, #TODO?
    scripting: window != nil and window.settings.scripting,
    canReinterpret: canReinterpret,
    charsets: charsets
  )
  parseHTML(inputStream, builder, opts)
  return Document(builder.document)

proc newDOMParser(): DOMParser {.jsctor.} =
  new(result)

proc parseFromString(ctx: JSContext, parser: DOMParser, str, t: string):
    JSResult[Document] {.jsfunc.} =
  case t
  of "text/html":
    let global = JS_GetGlobalObject(ctx)
    let window = if ctx.hasClass(Window):
      fromJS[Window](ctx, global).get(nil)
    else:
      Window(nil)
    JS_FreeValue(ctx, global)
    let url = if window != nil and window.document != nil:
      window.document.url
    else:
      newURL("about:blank").get
    let res = parseHTML(newStringStream(str), Window(nil), url)
    return ok(res)
  of "text/xml", "application/xml", "application/xhtml+xml", "image/svg+xml":
    return err(newInternalError("XML parsing is not supported yet"))
  else:
    return err(newTypeError("Invalid mime type"))

proc addHTMLModule*(ctx: JSContext) =
  ctx.registerType(DOMParser)
