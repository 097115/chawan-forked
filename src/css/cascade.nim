import std/algorithm
import std/options
import std/tables

import chame/tags
import css/cssparser
import css/cssvalues
import css/lunit
import css/match
import css/mediaquery
import css/selectorparser
import css/sheet
import css/stylednode
import html/catom
import html/dom
import html/enums
import types/color
import types/jscolor
import types/opt

type
  RuleList* = array[PseudoElem, seq[CSSRuleDef]]

  RuleListMap* = ref object
    ua: RuleList # user agent
    user: RuleList
    author: seq[RuleList]

func appliesLR(feature: MediaFeature; window: Window; n: LayoutUnit): bool =
  let a = feature.lengthrange.s.a.px(window.attrs, 0)
  let b = feature.lengthrange.s.b.px(window.attrs, 0)
  if not feature.lengthrange.aeq and a == n or a > n:
    return false
  if not feature.lengthrange.beq and b == n or b < n:
    return false
  return true

func applies(feature: MediaFeature; window: Window): bool =
  case feature.t
  of mftColor:
    return 8 in feature.range
  of mftGrid:
    return feature.b
  of mftHover:
    return feature.b
  of mftPrefersColorScheme:
    return feature.b == window.attrs.prefersDark
  of mftWidth:
    return feature.appliesLR(window, window.attrs.widthPx.toLayoutUnit)
  of mftHeight:
    return feature.appliesLR(window, window.attrs.heightPx.toLayoutUnit)
  of mftScripting:
    return feature.b == window.settings.scripting

func applies(mq: MediaQuery; window: Window): bool =
  case mq.t
  of mctMedia:
    case mq.media
    of mtAll: return true
    of mtPrint: return false
    of mtScreen: return true
    of mtSpeech: return false
    of mtTty: return true
  of mctNot:
    return not mq.n.applies(window)
  of mctAnd:
    return mq.anda.applies(window) and mq.andb.applies(window)
  of mctOr:
    return mq.ora.applies(window) or mq.orb.applies(window)
  of mctFeature:
    return mq.feature.applies(window)

func applies*(mqlist: MediaQueryList; window: Window): bool =
  for mq in mqlist:
    if mq.applies(window):
      return true
  return false

type
  ToSorts = array[PseudoElem, seq[(int, CSSRuleDef)]]

proc calcRule(tosorts: var ToSorts; element: Element;
    depends: var DependencyInfo; rule: CSSRuleDef) =
  for sel in rule.sels:
    if element.selectorsMatch(sel, depends):
      let spec = getSpecificity(sel)
      tosorts[sel.pseudo].add((spec, rule))

func calcRules(styledNode: StyledNode; sheet: CSSStylesheet): RuleList =
  var tosorts: ToSorts
  let element = Element(styledNode.node)
  var rules: seq[CSSRuleDef] = @[]
  sheet.tagTable.withValue(element.localName, v):
    for rule in v[]:
      rules.add(rule)
  if element.id != CAtomNull:
    sheet.idTable.withValue(element.id, v):
      for rule in v[]:
        rules.add(rule)
  for class in element.classList.toks:
    sheet.classTable.withValue(class, v):
      for rule in v[]:
        rules.add(rule)
  for attr in element.attrs:
    sheet.attrTable.withValue(attr.qualifiedName, v):
      for rule in v[]:
        rules.add(rule)
  for rule in sheet.generalList:
    rules.add(rule)
  rules.sort(ruleDefCmp, order = Ascending)
  for rule in rules:
    tosorts.calcRule(element, styledNode.depends, rule)
  for i in PseudoElem:
    tosorts[i].sort((proc(x, y: (int, CSSRuleDef)): int =
      cmp(x[0], y[0])
    ), order = Ascending)
    result[i] = newSeqOfCap[CSSRuleDef](tosorts[i].len)
    for item in tosorts[i]:
      result[i].add(item[1])

func calcPresentationalHints(element: Element): CSSComputedValues =
  template set_cv(a, b: untyped) =
    if result == nil:
      new(result)
    result{a} = b
  template map_width =
    let s = parseDimensionValues(element.attr(satWidth))
    if s.isSome:
      set_cv "width", s.get
  template map_height =
    let s = parseDimensionValues(element.attr(satHeight))
    if s.isSome:
      set_cv "height", s.get
  template map_width_nozero =
    let s = parseDimensionValues(element.attr(satWidth))
    if s.isSome and s.get.num != 0:
      set_cv "width", s.get
  template map_height_nozero =
    let s = parseDimensionValues(element.attr(satHeight))
    if s.isSome and s.get.num != 0:
      set_cv "height", s.get
  template map_bgcolor =
    let s = element.attr(satBgcolor)
    if s != "":
      let c = parseLegacyColor(s)
      if c.isSome:
        set_cv "background-color", c.get.cssColor()
  template map_size =
    let s = element.attrul(satSize)
    if s.isSome:
      set_cv "width", CSSLength(num: float64(s.get), u: cuCh)
  template map_text =
    let s = element.attr(satText)
    if s != "":
      let c = parseLegacyColor(s)
      if c.isSome:
        set_cv "color", c.get.cssColor()
  template map_color =
    let s = element.attr(satColor)
    if s != "":
      let c = parseLegacyColor(s)
      if c.isSome:
        set_cv "color", c.get.cssColor()
  template map_colspan =
    let colspan = element.attrulgz(satColspan)
    if colspan.isSome:
      let i = colspan.get
      if i <= 1000:
        set_cv "-cha-colspan", int(i)
  template map_rowspan =
    let rowspan = element.attrul(satRowspan)
    if rowspan.isSome:
      let i = rowspan.get
      if i <= 65534:
        set_cv "-cha-rowspan", int(i)
  template set_bgcolor_is_canvas =
    set_cv "-cha-bgcolor-is-canvas", true

  case element.tagType
  of TAG_TABLE:
    map_height_nozero
    map_width_nozero
    map_bgcolor
  of TAG_TD, TAG_TH:
    map_height_nozero
    map_width_nozero
    map_bgcolor
    map_colspan
    map_rowspan
  of TAG_THEAD, TAG_TBODY, TAG_TFOOT, TAG_TR:
    map_height
    map_bgcolor
  of TAG_COL:
    map_width
  of TAG_IMG:
    map_width
    map_height
  of TAG_CANVAS:
    map_width
    map_height
  of TAG_HTML:
    set_bgcolor_is_canvas
  of TAG_BODY:
    set_bgcolor_is_canvas
    map_bgcolor
    map_text
  of TAG_TEXTAREA:
    let textarea = HTMLTextAreaElement(element)
    let cols = textarea.attrul(satCols).get(20)
    let rows = textarea.attrul(satRows).get(1)
    set_cv "width", CSSLength(u: cuCh, num: float64(cols))
    set_cv "height", CSSLength(u: cuEm, num: float64(rows))
  of TAG_FONT:
    map_color
  of TAG_INPUT:
    let input = HTMLInputElement(element)
    if input.inputType in InputTypeWithSize:
      map_size
  else: discard

type
  CSSValueEntryObj = object
    normal: seq[CSSComputedEntry]
    important: seq[CSSComputedEntry]

  CSSValueEntryMap = array[CSSOrigin, CSSValueEntryObj]

func buildComputedValues(rules: CSSValueEntryMap; presHints, parent:
    CSSComputedValues): CSSComputedValues =
  new(result)
  var previousOrigins: array[CSSOrigin, CSSComputedValues]
  for entry in rules[coUserAgent].normal: # user agent
    result.applyValue(entry, parent, nil)
  previousOrigins[coUserAgent] = result.copyProperties()
  # Presentational hints override user agent style, but respect user/author
  # style.
  if presHints != nil:
    for prop in CSSPropertyType:
      if presHints[prop] != nil:
        result[prop] = presHints[prop]
  for entry in rules[coUser].normal: # user
    result.applyValue(entry, parent, previousOrigins[coUserAgent])
  # save user origins so author can use them
  previousOrigins[coUser] = result.copyProperties()
  for entry in rules[coAuthor].normal: # author
    result.applyValue(entry, parent, previousOrigins[coUser])
  # no need to save user origins
  for entry in rules[coAuthor].important: # author important
    result.applyValue(entry, parent, previousOrigins[coUser])
  # important, so no need to save origins
  for entry in rules[coUser].important: # user important
    result.applyValue(entry, parent, previousOrigins[coUserAgent])
  # important, so no need to save origins
  for entry in rules[coUserAgent].important: # user agent important
    result.applyValue(entry, parent, nil)
  # important, so no need to save origins
  # set defaults
  for prop in CSSPropertyType:
    if result[prop] == nil:
      if prop.inherited and parent != nil and parent[prop] != nil:
        result[prop] = parent[prop]
      else:
        result[prop] = getDefault(prop)
  if result{"float"} != FloatNone:
    #TODO it may be better to handle this in layout
    let display = result{"display"}.blockify()
    if display != result{"display"}:
      result{"display"} = display

proc add(map: var CSSValueEntryObj; rules: seq[CSSRuleDef]) =
  for rule in rules:
    map.normal.add(rule.normalVals)
    map.important.add(rule.importantVals)

proc applyDeclarations(styledNode: StyledNode; parent: CSSComputedValues;
    map: RuleListMap) =
  var rules: CSSValueEntryMap
  var presHints: CSSComputedValues = nil
  rules[coUserAgent].add(map.ua[peNone])
  rules[coUser].add(map.user[peNone])
  for rule in map.author:
    rules[coAuthor].add(rule[peNone])
  if styledNode.node != nil:
    let element = Element(styledNode.node)
    let style = element.cachedStyle
    if style != nil:
      for decl in style.decls:
        let vals = parseComputedValues(decl.name, decl.value)
        if decl.important:
          rules[coAuthor].important.add(vals)
        else:
          rules[coAuthor].normal.add(vals)
    presHints = element.calcPresentationalHints()
  styledNode.computed = rules.buildComputedValues(presHints, parent)

func hasValues(rules: CSSValueEntryMap): bool =
  for origin in CSSOrigin:
    if rules[origin].normal.len > 0 or rules[origin].important.len > 0:
      return true
  return false

# Either returns a new styled node or nil.
proc applyDeclarations(pseudo: PseudoElem; styledParent: StyledNode;
    map: RuleListMap): StyledNode =
  var rules: CSSValueEntryMap
  rules[coUserAgent].add(map.ua[pseudo])
  rules[coUser].add(map.user[pseudo])
  for rule in map.author:
    rules[coAuthor].add(rule[pseudo])
  if rules.hasValues():
    let cvals = rules.buildComputedValues(nil, styledParent.computed)
    return styledParent.newStyledElement(pseudo, cvals)
  return nil

func applyMediaQuery(ss: CSSStylesheet; window: Window): CSSStylesheet =
  if ss == nil:
    return nil
  var res = CSSStylesheet()
  res[] = ss[]
  for mq in ss.mqList:
    if mq.query.applies(window):
      res.add(mq.children.applyMediaQuery(window))
  return res

func calcRules(styledNode: StyledNode; ua, user: CSSStylesheet;
    author: seq[CSSStylesheet]): RuleListMap =
  let uadecls = calcRules(styledNode, ua)
  var userdecls: RuleList
  if user != nil:
    userdecls = calcRules(styledNode, user)
  var authordecls: seq[RuleList]
  for rule in author:
    authordecls.add(calcRules(styledNode, rule))
  return RuleListMap(
    ua: uadecls,
    user: userdecls,
    author: authordecls
  )

proc applyStyle(parent, styledNode: StyledNode; map: RuleListMap) =
  let parentComputed = if parent != nil:
    parent.computed
  else:
    rootProperties()
  styledNode.applyDeclarations(parentComputed, map)

type CascadeFrame = object
  styledParent: StyledNode
  child: Node
  pseudo: PseudoElem
  cachedChild: StyledNode
  cachedChildren: seq[StyledNode]
  parentDeclMap: RuleListMap

proc getAuthorSheets(document: Document): seq[CSSStylesheet] =
  var author: seq[CSSStylesheet]
  for sheet in document.sheets():
    author.add(sheet.applyMediaQuery(document.window))
  return author

proc applyRulesFrameValid(frame: var CascadeFrame): StyledNode =
  let styledParent = frame.styledParent
  let cachedChild = frame.cachedChild
  # Pseudo elements can't have invalid children.
  if cachedChild.t == stElement and cachedChild.pseudo == peNone:
    # Refresh child nodes:
    # * move old seq to a temporary location in frame
    # * create new seq, assuming capacity == len of the previous pass
    frame.cachedChildren = move(cachedChild.children)
    cachedChild.children = newSeqOfCap[StyledNode](frame.cachedChildren.len)
  cachedChild.parent = styledParent
  if styledParent != nil:
    styledParent.children.add(cachedChild)
  return cachedChild

proc applyRulesFrameInvalid(frame: CascadeFrame; ua, user: CSSStylesheet;
    author: seq[CSSStylesheet]; declmap: var RuleListMap): StyledNode =
  var styledChild: StyledNode = nil
  let pseudo = frame.pseudo
  let styledParent = frame.styledParent
  let child = frame.child
  if frame.pseudo != peNone:
    case pseudo
    of peBefore, peAfter:
      let declmap = frame.parentDeclMap
      let styledPseudo = pseudo.applyDeclarations(styledParent, declmap)
      if styledPseudo != nil and styledPseudo.computed{"content"}.len > 0:
        for content in styledPseudo.computed{"content"}:
          let child = styledPseudo.newStyledReplacement(content, peNone)
          styledPseudo.children.add(child)
        styledParent.children.add(styledPseudo)
    of peInputText:
      let s = HTMLInputElement(styledParent.node).inputString()
      if s.len > 0:
        let content = styledParent.node.document.newText(s)
        let styledText = styledParent.newStyledText(content)
        # Note: some pseudo-elements (like input text) generate text nodes
        # directly, so we have to cache them like this.
        styledText.pseudo = pseudo
        styledParent.children.add(styledText)
    of peTextareaText:
      let s = HTMLTextAreaElement(styledParent.node).textAreaString()
      if s.len > 0:
        let content = styledParent.node.document.newText(s)
        let styledText = styledParent.newStyledText(content)
        styledText.pseudo = pseudo
        styledParent.children.add(styledText)
    of peImage:
      let content = CSSContent(
        t: ContentImage,
        bmp: HTMLImageElement(styledParent.node).bitmap
      )
      let styledText = styledParent.newStyledReplacement(content, pseudo)
      styledParent.children.add(styledText)
    of peCanvas:
      let bmp = HTMLCanvasElement(styledParent.node).bitmap
      if bmp != nil and bmp.cacheId != 0:
        let content = CSSContent(
          t: ContentImage,
          bmp: bmp
        )
        let styledText = styledParent.newStyledReplacement(content, pseudo)
        styledParent.children.add(styledText)
    of peVideo:
      let content = CSSContent(t: ContentVideo)
      let styledText = styledParent.newStyledReplacement(content, pseudo)
      styledParent.children.add(styledText)
    of peAudio:
      let content = CSSContent(t: ContentAudio)
      let styledText = styledParent.newStyledReplacement(content, pseudo)
      styledParent.children.add(styledText)
    of peNewline:
      let content = CSSContent(t: ContentNewline)
      let styledText = styledParent.newStyledReplacement(content, pseudo)
      styledParent.children.add(styledText)
    of peNone: assert false
  else:
    assert child != nil
    if styledParent != nil:
      if child of Element:
        let element = Element(child)
        styledChild = styledParent.newStyledElement(element)
        styledParent.children.add(styledChild)
        declmap = styledChild.calcRules(ua, user, author)
        applyStyle(styledParent, styledChild, declmap)
      elif child of Text:
        let text = Text(child)
        styledChild = styledParent.newStyledText(text)
        styledParent.children.add(styledChild)
    else:
      # Root element
      let element = Element(child)
      styledChild = newStyledElement(element)
      declmap = styledChild.calcRules(ua, user, author)
      applyStyle(styledParent, styledChild, declmap)
  return styledChild

proc stackAppend(styledStack: var seq[CascadeFrame]; frame: CascadeFrame;
    styledParent: StyledNode; child: Node; i: var int) =
  var cached: StyledNode = nil
  if frame.cachedChildren.len > 0:
    for j in countdown(i, 0):
      let it = frame.cachedChildren[j]
      if it.node == child:
        i = j - 1
        cached = it
        break
  styledStack.add(CascadeFrame(
    styledParent: styledParent,
    child: child,
    pseudo: peNone,
    cachedChild: cached
  ))

proc stackAppend(styledStack: var seq[CascadeFrame]; frame: CascadeFrame;
    styledParent: StyledNode; pseudo: PseudoElem; i: var int;
    parentDeclMap: RuleListMap = nil) =
  # Can't check for cachedChildren.len here, because we assume that we only have
  # cached pseudo elems when the parent is also cached.
  if frame.cachedChild != nil:
    var cached: StyledNode = nil
    for j in countdown(i, 0):
      let it = frame.cachedChildren[j]
      if it.pseudo == pseudo:
        cached = it
        i = j - 1
        break
    # When calculating pseudo-element rules, their dependencies are added
    # to their parent's dependency list; so invalidating a pseudo-element
    # invalidates its parent too, which in turn automatically rebuilds
    # the pseudo-element.
    # In other words, we can just do this:
    if cached != nil:
      styledStack.add(CascadeFrame(
        styledParent: styledParent,
        pseudo: pseudo,
        cachedChild: cached,
        parentDeclMap: parentDeclMap
      ))
  else:
    styledStack.add(CascadeFrame(
      styledParent: styledParent,
      pseudo: pseudo,
      cachedChild: nil,
      parentDeclMap: parentDeclMap
    ))

# Append children to styledChild.
proc appendChildren(styledStack: var seq[CascadeFrame]; frame: CascadeFrame;
    styledChild: StyledNode; parentDeclMap: RuleListMap) =
  # i points to the child currently being inspected.
  var idx = frame.cachedChildren.len - 1
  let element = Element(styledChild.node)
  # reset invalid flag here to avoid a type conversion above
  element.invalid = false
  styledStack.stackAppend(frame, styledChild, peAfter, idx, parentDeclMap)
  case element.tagType
  of TAG_TEXTAREA:
    styledStack.stackAppend(frame, styledChild, peTextareaText, idx)
  of TAG_IMG: styledStack.stackAppend(frame, styledChild, peImage, idx)
  of TAG_VIDEO: styledStack.stackAppend(frame, styledChild, peVideo, idx)
  of TAG_AUDIO: styledStack.stackAppend(frame, styledChild, peAudio, idx)
  of TAG_BR: styledStack.stackAppend(frame, styledChild, peNewline, idx)
  of TAG_CANVAS: styledStack.stackAppend(frame, styledChild, peCanvas, idx)
  else:
    for i in countdown(element.childList.high, 0):
      let child = element.childList[i]
      if child of Element or child of Text:
        styledStack.stackAppend(frame, styledChild, child, idx)
    if element.tagType == TAG_INPUT:
      styledStack.stackAppend(frame, styledChild, peInputText, idx)
  styledStack.stackAppend(frame, styledChild, peBefore, idx, parentDeclMap)

# Builds a StyledNode tree, optionally based on a previously cached version.
proc applyRules(document: Document; ua, user: CSSStylesheet;
    cachedTree: StyledNode): StyledNode =
  let html = document.documentElement
  if html == nil:
    return
  let author = document.getAuthorSheets()
  var styledStack = @[CascadeFrame(
    child: html,
    pseudo: peNone,
    cachedChild: cachedTree
  )]
  var root: StyledNode = nil
  var toReset: seq[Element] = @[]
  while styledStack.len > 0:
    var frame = styledStack.pop()
    var declmap: RuleListMap
    let styledParent = frame.styledParent
    let valid = frame.cachedChild != nil and frame.cachedChild.isValid(toReset)
    let styledChild = if valid:
      frame.applyRulesFrameValid()
    else:
      # From here on, computed values of this node's children are invalid
      # because of property inheritance.
      frame.cachedChild = nil
      frame.applyRulesFrameInvalid(ua, user, author, declmap)
    if styledChild != nil:
      if styledParent == nil:
        # Root element
        root = styledChild
      if styledChild.t == stElement and styledChild.node != nil:
        # note: following resets styledChild.node's invalid flag
        styledStack.appendChildren(frame, styledChild, declmap)
  for element in toReset:
    element.invalidDeps = {}
  return root

proc applyStylesheets*(document: Document; uass, userss: CSSStylesheet;
    previousStyled: StyledNode): StyledNode =
  let uass = uass.applyMediaQuery(document.window)
  let userss = userss.applyMediaQuery(document.window)
  return document.applyRules(uass, userss, previousStyled)

# Forward declaration hack
appliesImpl = applies
