import streams
import unicode

import css/mediaquery
import css/parser
import css/selparser

type
  CSSRuleBase* = ref object of RootObj

  CSSRuleDef* = ref object of CSSRuleBase
    sels*: seq[SelectorList]
    oblock*: CSSSimpleBlock

  CSSConditionalDef* = ref object of CSSRuleBase
    children*: seq[CSSRuleBase]

  CSSMediaQueryDef* = ref object of CSSConditionalDef
    query*: MediaQueryList

  CSSStylesheet* = seq[CSSRuleBase]

proc addRule(stylesheet: var CSSStylesheet, rule: CSSQualifiedRule) =
  let sels = parseSelectors(rule.prelude)
  if sels.len > 1 or sels[^1].len > 0:
    let r = CSSRuleDef(sels: sels, oblock: rule.oblock)
    stylesheet.add(r)

proc addAtRule(stylesheet: var CSSStylesheet, atrule: CSSAtRule) =
  case $atrule.name
  of "media":
    let query = parseMediaQueryList(atrule.prelude)
    let rules = atrule.oblock.value.parseListOfRules()
    if rules.len > 0:
      var media = CSSMediaQueryDef()
      media.query = query
      for rule in rules:
        if rule of CSSAtRule:
          media.children.addAtRule(CSSAtRule(rule))
        else:
          media.children.addRule(CSSQualifiedRule(rule)) #qualified rule
      stylesheet.add(media)
  else: discard #TODO

proc parseStylesheet*(s: Stream): CSSStylesheet =
  for v in parseCSS(s).value:
    if v of CSSAtRule: result.addAtRule(CSSAtRule(v))
    else: result.addRule(CSSQualifiedRule(v))

proc parseStylesheet*(s: string): CSSStylesheet =
  return newStringStream(s).parseStylesheet()
