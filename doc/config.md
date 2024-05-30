<!-- MANON
% cha-config(5) | Configuration of Chawan
MANOFF -->

# Configuration of Chawan

Chawan supports configuration of various options like keybindings, user
stylesheets, site preferences, etc. The configuration format is very similar
to toml, with the following exceptions:

* Inline tables may span across multiple lines.
* Table arrays can be cleared by setting a variable by the same to the
  empty array. This allows users to disable default table array rules.

Example:
```
omnirule = [] # note: this must be placed at the beginning of the file.

[[omnirule]] # this is legal. all default omni-rules are now disabled.
```

Chawan will look for a config file in the $XDG_CONFIG_HOME/chawan/ directory
called `config.toml`. (Chawan defaults to ~/.config if the XDG_CONFIG_HOME
environment variable is not set.) See the default configuration file in the
res/ folder, and bonus configuration files in the bonus/ folder for further
examples.

<!-- MANOFF -->
**Table of contents**

* [Start](#start)
* [Search](#search)
* [Encoding](#encoding)
* [External](#external)
* [Network](#network)
* [Display](#display)
* [Omnirule](#omnirule)
* [Siteconf](#siteconf)
* [Stylesheets](#stylesheets)
* [Keybindings](#keybindings)
   * [Pager actions](#pager-actions)
   * [Line-editing actions](#line-editing-actions)
* [Appendix](#appendix)
   * [Regex handling](#regex-handling)
     * [Match mode](#match-mode)
     * [Search mode](#search-mode)
   * [Path handling](#path-handling)
   * [Word types](#word-types)
     * [w3m word](#w3m-word)
     * [vi word](#vi-word)
     * [Big word](#big-word)

<!-- MANON -->

## Start

Start-up options are to be placed in the `[start]` section.

Following is a list of start-up options:

<table>

<tr>
<th>Name</th>
<th>Value</th>
<th>Function</th>
</tr>

<tr>
<td>visual-home</td>
<td>url</td>
<td>Page opened when Chawan is called with the -V option (and no other
pages are passed as arguments.)</td>
</tr>

<tr>
<td>startup-script</td>
<td>JavaScript code</td>
<td>Script Chawan runs on start-up. Pages will not be loaded until this
function exits. (Note however that asynchronous functions like setTimeout
do not block loading.)</td>
</tr>

<tr>
<td>headless</td>
<td>boolean</td>
<td>Whether Chawan should always start in headless mode. Automatically
enabled when Chawan is called with -r.</td>
</tr>

<tr>
<td>console-buffer</td>
<td>boolean</td>
<td>Whether Chawan should open a console buffer in non-headless mode. Defaults
to true.<br>
Warning: this is only useful for debugging. Disabling this option without
manually redirecting standard error will result in error messages randomly
appearing on your screen.</td>
</tr>

</table>

## Search

Search options are to be placed in the `[search]` section.

Following is a list of search options:

<table>

<tr>
<th>Name</th>
<th>Value</th>
<th>Function</th>
</tr>

<tr>
<td>wrap</td>
<td>boolean</td>
<td>When set to true, searchNext/searchPrev wraps around the document.</td>
</tr>

<tr>
<td>ignore-case</td>
<td>boolean</td>
<td>When set to true, document-wide searches are case-insensitive by
default.<br>
Note: this can also be overridden inline in the search bar (vim-style),
with the escape sequences `\c` (ignore case) and `\C` (strict case). See
[search mode](#search-mode) for details.)</td>
</tr>

</table>

## Encoding

Encoding options are to be placed in the `[encoding]` section.

Following is a list of encoding options:

<table>

<tr>
<th>Name</th>
<th>Value</th>
<th>Function</th>
</tr>

<tr>
<td>document-charset</td>
<td>array of charset label strings</td>
<td>List of character sets for loading documents.<br>
All listed character sets are enumerated until the document has been decoded
without errors. In HTML, meta tags and the BOM may override this with a
different charset, so long as the specified charset can decode the document
correctly.
</td>
</tr>

<tr>
<td>display-charset</td>
<td>string</td>
<td>Character set for keyboard input and displaying documents.<br>
Used in dump mode as well.<br>
(This means that e.g. `cha -I EUC-JP -O UTF-8 a > b` is equivalent to `iconv
-f EUC-JP -t UTF-8`.)</td>
</tr>

</table>

## External

External options are to be placed in the `[external]` section.

Following is a list of external options:

<table>

<tr>
<th>Name</th>
<th>Value</th>
<th>Function</th>
</tr>

<tr>
<td>tmpdir</td>
<td>path</td>
<td>Directory used to save temporary files.</td>
</tr>

<tr>
<td>sockdir</td>
<td>path</td>
<td>Directory used to store UNIX domain sockets used for inter-process
communication.</td>
</tr>

<tr>
<td>editor</td>
<td>shell command</td>
<td>External editor command. %s is substituted for the file name, %d for
the line number.</td>
</tr>

<tr>
<td>mailcap</td>
<td>array of paths</td>
<td>Search path for <!-- MANOFF -->[mailcap](mailcap.md) files.<!-- MANON -->
<!-- MANON mailcap files. (See **cha-mailcap**(5) for details.) MANOFF -->
</td>
</tr>

<tr>
<td>mime-types</td>
<td>array of paths</td>
<td>Search path for <!-- MANOFF -->[mime.types](mime.types.md) files.<!-- MANON -->
<!-- MANON mime.types files. (See **cha-mime.types**(5) for details.) MANOFF -->
</td>
</tr>

<tr>
<td>cgi-dir</td>
<td>array of paths</td>
<td>Search path for <!-- MANOFF -->[local CGI](localcgi.md) scripts.<!-- MANON -->
<!-- MANON local CGI scripts. (See **cha-localcgi**(5) for details.) MANOFF -->
</td>
</tr>

<tr>
<td>urimethodmap</td>
<td>array of paths</td>
<td>Search path for <!-- MANOFF -->[urimethodmap](urimethodmap.md) files.<!-- MANON -->
<!-- MANON urimethodmap files. (See **cha-urimethodmap**(5) for details.) MANOFF -->
</td>
</tr>

<tr>
<td>w3m-cgi-compat</td>
<td>boolean</td>
<td>Enable local CGI compatibility with w3m. In short, it redirects
`file:///cgi-bin/*` and `file:///$LIB/cgi-bin/*` to `cgi-bin:*`. For further
details, see <!-- MANOFF -->[localcgi.md](localcgi.md).<!-- MANON -->
<!-- MANON **cha-localcgi**(5). MANOFF -->
</td>
</tr>

<tr>
<td>download-dir</td>
<td>string</td>
<td>Path to pre-fill for "Save to:" prompts. This is not validated, you can set
it to whatever you find useful.</td>
</tr>

</table>

## Input

Input options are to be placed in the `[input]` section.

<table>

<tr>
<th>Name</th>
<th>Value</th>
<th>Function</th>
</tr>

<tr>
<td>vi-numeric-prefix</td>
<td>boolean</td>
<td>Whether vi-style numeric prefixes to commands should be accepted.<br>
When set to true, commands that return a function will be called with the
numeric prefix as their first argument.<br>
Note: this only applies for keybindings defined in [page].</td>
</tr>

<tr>
<td>use-mouse</td>
<td>boolean</td>
<td>Whether Chawan is allowed to use the mouse.<br>
Currently, the default behavior imitates that of w3m.</td>
</tr>

</table>

Examples:
```
[input]
vi-numeric-prefix = true

[page]
# Here, the arrow function will be called with the vi numbered prefix if
# one was input, and with no argument otherwise.
# The numeric prefix can never be zero, so it is safe to test for undefined
# using the ternary operator.
G = 'n => n ? pager.gotoLine(n) : pager.cursorLastLine()'
```

## Network

Network options are to be placed in the `[network]` section.

<table>

<tr>
<th>Name</th>
<th>Value</th>
<th>Function</th>
</tr>

<tr>
<td>max-redirect</td>
<td>number</td>
<td>Maximum number of redirections to follow.</td>
</tr>

<tr>
<td>prepend-scheme</td>
<td>string</td>
<td>Prepend this to URLs passed to Chawan without a scheme.<br>
Note that local files (`file:` scheme) will always be checked first; only
if this fails, Chawan will retry the request with `prepend-scheme` set as
the scheme.<br>
By default, this is set to "https://". Note that the "://" part is
mandatory.</td>
</tr>

<tr>
<td>prepend-https</td>
<td>boolean</td>
<td>Deprecated: use prepend-scheme instead.<br>
When set to false, Chawan will act as if prepend-scheme were set to "".</td>
</tr>

<tr>
<td>proxy</td>
<td>URL</td>
<td>Specify a proxy for all network requests Chawan makes. All proxies
supported by cURL may be used. Can be overridden by siteconf.</td>
</tr>

<tr>
<td>default-headers</td>
<td>table</td>
<td>Specify a list of default headers for all HTTP(S) network requests. Can be
overridden by siteconf.</td>
</tr>

</table>

## Display

Display options are to be placed in the `[display]` section.

Following is a list of display options:

<table>

<tr>
<th>Name</th>
<th>Value</th>
<th>Function</th>
</tr>

<tr>
<td>color-mode</td>
<td>"monochrome" / "ansi" / "eight-bit" / "true-color" / "auto"</td>
<td>Set the color mode. "auto" for automatic detection, "monochrome"
for black on white, "ansi" for ansi colors, "eight-bit" for 256-color mode, and
"true-color" for true colors.<br>
"8bit" is accepted as a legacy alias of "eight-bit". "24bit" is accepted as
a legacy alias of "true-color".</td>
</tr>

<tr>
<td>format-mode</td>
<td>"auto" / ["bold", "italic", "underline", "reverse", "strike", "overline",
"blink"]</td>
<td>Specifies output formatting modes. Accepts the string "auto" or an array
of specific attributes. An empty array (`[]`) disables formatting
completely.</td>
</tr>

<tr>
<td>no-format-mode</td>
<td>["bold", "italic", "underline", "reverse", "strike", "overline", "blink"]</td>
<td>Disable specified formatting modes.</td>
</tr>

<tr>
<td>alt-screen</td>
<td>"auto" / boolean</td>
<td>Enable/disable the alternative screen.</td>
</tr>

<tr>
<td>highlight-color</td>
<td>color</td>
<td>Set the highlight color. Both hex values and CSS color names are
accepted.</td>
</tr>

<tr>
<td>highlight-marks</td>
<td>boolean</td>
<td>Enable/disable highlighting of marks.</td>
</tr>

<tr>
<td>double-width-ambiguous</td>
<td>boolean</td>
<td>Assume the terminal displays characters in the East Asian Ambiguous
category as double-width characters. Useful when e.g. ○ occupies two
cells.</td>
</tr>

<tr>
<td>minimum-contrast</td>
<td>number</td>
<td>Specify the minimum difference between the luminance (Y) of the background
and the foreground. -1 disables this function (i.e. allows black letters on
black background, etc).</td>
</tr>

<tr>
<td>force-clear</td>
<td>boolean</td>
<td>Force the screen to be completely cleared every time it is redrawn.</td>
</tr>

<tr>
<td>set-title</td>
<td>boolean</td>
<td>Set the terminal emulator's window title to that of the current page.</td>
</tr>

<tr>
<td>default-background-color</td>
<td>"auto" / color</td>
<td>Overrides the assumed background color of the terminal. "auto" leaves
background color detection to Chawan.</td>
</tr>

<tr>
<td>default-foreground-color</td>
<td>"auto" / color</td>
<td>Sets the assumed foreground color of the terminal. "auto" leaves foreground
color detection to Chawan.</td>
</tr>

<tr>
<td>query-da1</td>
<td>bool</td>
<td>Enable/disable querying Primary Device Attributes, and with it, all
"dynamic" terminal querying.<br>
It is highly recommended not to alter the default value (which is true), or the
output will most likely look horrible. (Except, obviously, if your terminal does
not support Primary Device Attributes.)</td>
</tr>

<tr>
<td>columns, lines, pixels-per-column, pixels-per-line</td>
<td>number</td>
<td>Fallback values for the number of columns, lines, pixels per
column, and pixels per line for the cases where it cannot be determined
automatically. (For example, these values are used in dump mode.)</td>
</tr>

<tr>
<td>force-columns, force-lines, force-pixels-per-column,
force-pixels-per-line</td>
<td>boolean</td>
<td>Force-set columns, lines, pixels per column, or pixels per line to the
fallback values provided above.</td>
</tr>

</table>

## Omnirule

The omni-bar (by default opened with C-l) can be used to perform searches using
omni-rules. These are to be placed in the table array `[[omnirule]]`.

Examples:
```
# Search using DuckDuckGo Lite. (Bound to C-k by default.)
[[omnirule]]
match = '^ddg:'
substitute-url = '(x) => "https://lite.duckduckgo.com/lite/?kp=-1&kd=-1&q=" + encodeURIComponent(x.split(":").slice(1).join(":"))'

# Search using Wikipedia, Firefox-style.
[[omnirule]]
match = '^@wikipedia'
substitute-url = '(x) => "https://en.wikipedia.org/wiki/Special:Search?search=" + encodeURIComponent(x.replace(/@wikipedia/, ""))'
```

Omnirule options:

<table>

<tr>
<th>Name</th>
<th>Value</th>
<th>Function</th>
</tr>

<tr>
<td>match</td>
<td>regex</td>
<td>Regular expression used to match the input string. Note that websites
passed as arguments are matched as well.<br>
Note: regexes are handled according to the [match mode](#match-mode) regex
handling rules.</td>
</tr>

<tr>
<td>substitute-url</td>
<td>JavaScript function</td>
<td>A JavaScript function Chawan will pass the input string to. If a new string is
returned, it will be parsed instead of the old one.</td>
</tr>

</table>

## Siteconf

Configuration options can be specified for individual sites. Entries are to be
placed in the table array `[[siteconf]]`.

Examples:
```
# Enable cookies on the orange website for log-in.
[[siteconf]]
url = 'https://news\.ycombinator\.com/.*'
cookie = true

# Redirect npr.org to text.npr.org.
[[siteconf]]
host = '(www\.)?npr\.org'
rewrite-url = '''
(x) => {
	x.host = "text.npr.org";
	const s = x.pathname.split('/');
	x.pathname = s.at(s.length > 2 ? -2 : 1);
	/* No need to return; URL objects are passed by reference. */
}
'''

# Allow cookie sharing on *sr.ht domains.
[[siteconf]]
host = '(.*\.)?sr\.ht' # either 'something.sr.ht' or 'sr.ht'
cookie = true # enable cookies
share-cookie-jar = 'sr.ht' # use the cookie jar of 'sr.ht' for all matched hosts
third-party-cookie = '.*\.sr\.ht' # allow cookies from subdomains
```

Siteconf options:

<table>

<tr>
<th>Name</th>
<th>Value</th>
<th>Function</th>
</tr>

<tr>
<td>url</td>
<td>regex</td>
<td>Regular expression used to match the URL. Either this or the `host` option
must be specified.<br>
Note: regexes are handled according to the [match mode](#match-mode) regex
handling rules.</td>
</tr>

<tr>
<td>host</td>
<td>regex</td>
<td>Regular expression used to match the host part of the URL (i.e. domain
name/ip address.) Either this or the `url` option must be specified.<br>
Note: regexes are handled according to the [match mode](#match-mode) regex
handling rules.</td>
</tr>

<tr>
<td>rewrite-url</td>
<td>JavaScript function</td>
<td>A JavaScript function Chawan will pass the URL to. If a new URL is
returned, it will replace the old one.</td>
</tr>

<tr>
<td>cookie</td>
<td>boolean</td>
<td>Whether loading cookies should be allowed for this URL. By default, this is
false for all websites.</td>
</tr>

<tr>
<td>third-party-cookie</td>
<td>array of regexes</td>
<td>Domains for which third-party cookies are allowed on this domain. Note:
this only works for buffers which share the same cookie jar.<br>
Note: regexes are handled according to the [match mode](#match-mode) regex
handling rules.</td>
</tr>

<tr>
<td>share-cookie-jar</td>
<td>host</td>
<td>Cookie jar to use for this domain. Useful for e.g. sharing cookies with
subdomains.</td>
</tr>

<tr>
<td>referer-from</td>
<td>boolean</td>
<td>Whether or not we should send a Referer header when opening requests
originating from this domain. Simplified example: if you click a link on a.com
that refers to b.com, and referer-from is true, b.com is sent "a.com" as the
Referer header.  
Defaults to false.
</td>
</tr>

<tr>
<td>scripting</td>
<td>boolean</td>
<td>Enable/disable JavaScript execution on this site.</td>
</tr>

<tr>
<td>document-charset</td>
<td>charset label string</td>
<td>Specify the default encoding for this site. Overrides `document-charset`
in `[encoding]`.</td>
</tr>

<tr>
<td>stylesheet</td>
<td>CSS stylesheet</td>
<td>Specify an additional user-stylesheet for this site.  
Note: other user-stylesheets (specified under [css] or additional matching
siteconfs) are not overridden. (In other words, they will be concatenated
with this stylesheet to get the final user stylesheet.)</td>
</tr>

<tr>
<td>proxy</td>
<td>URL</td>
<td>Specify a proxy for network requests fetching contents of this buffer.
Overrides `proxy` in `[network]`.</td>
</tr>

<tr>
<td>default-headers</td>
<td>table</td>
<td>Specify a list of default headers for HTTP(S) network requests to this
buffer. Overrides `default-headers` in `[network]`.</td>
</tr>

<tr>
<td>insecure-ssl-no-verify</td>
<td>boolean</td>
<td>Defaults to false. When set to true, this disables peer and hostname
verification for SSL keys on this site, like `curl --insecure` would.<br>
WARNING: this is insecure, and opens up your connections to man-in-the-middle
attacks. Please do not use this unless you are absolutely sure you know what you
are doing.</td>
</tr>

</table>

## Stylesheets

User stylesheets are to be placed in the `[css]` section.

There are two ways to import user stylesheets:

1. Include a user stylesheet using the format `include = 'path-to-user.css'`.
   To include multiple stylesheets, use `include = ['first-stylesheet.css,
   second-stylesheet.css']`.  
   Relative paths are interpreted relative to the config directory.

2. Place your stylesheet directly in your configuration file using `inline =
   """your-style"""`.  

## Keybindings

Keybindings are to be placed in these sections:

* for pager interaction: `[page]`
* for line editing: `[line]`

Keybindings are configured using the syntax

	'<keybinding>' = '<action>'

Where `<keybinding>` is a combination of unicode characters with or without
modifiers. Modifiers are the prefixes `C-` and `M-`, which add control or
escape to the keybinding respectively (essentially making `M-` the same as
`C-[`). Modifiers can be escaped with the `\` sign.

`<action>` is either a command defined in the `[cmd]` section, or a JavaScript
expression. Here we only describe the pre-defined actions in the default config;
for a description of the API, please see:

<!-- MANOFF -->
[the API documentation](api.md).
<!-- MANON -->
<!-- MANON
The API documentation at **cha-api**(5).
MANOFF -->

Examples:

```toml
# show change URL when Control, Escape and j are pressed
'C-M-j' = 'cmd.pager.load'
# go to the first line of the page when g is pressed twice without a preceding
# number, or to the line when a preceding number is given.
'gg' = 'cmd.pager.gotoLineOrStart'
```

### Browser actions

<table>

<tr>
<th>Name</th>
<th>Function</th>
</tr>

<tr>
<td>`cmd.pager.quit`</td>
<td>Exit the browser.</td>
</tr>

<tr>
<td>`cmd.pager.suspend`</td>
<td>Temporarily suspend the browser<br>
Note: this also suspends e.g. buffer processes or CGI scripts. So if you are
downloading something, that will be delayed until you restart the process.</td>
</tr>

</table>

### Pager actions

Note: `n` in the following text refers to a number preceding the action.  e.g.
in `10gg`, n = 10.  If no preceding number is input, then it is left
unspecified.

<table>

<tr>
<th>Name</th>
<th>Function</th>
</tr>

<tr>
<td>`cmd.pager.cursorUp`, `cmd.pager.cursorDown`</td>
<td>Move the cursor upwards/downwards by n lines, or if n is unspecified, by
1.</td>
</tr>

<tr>
<td>`cmd.pager.cursorLeft`, `cmd.pager.cursorRight`</td>
<td>Move the cursor to the left/right by n cells, or if n is unspecified, by
1.</td>
</tr>

<tr>
<td>`cmd.pager.cursorLineBegin`</td>
<td>Move the cursor to the first cell of the line.</td>
</tr>

<tr>
<td>`cmd.pager.cursorLineTextStart`</td>
<td>Move the cursor to the first non-blank character of the line.</td>
</tr>

<tr>
<td>`cmd.pager.cursorLineEnd`</td>
<td>Move the cursor to the last cell of the line.</td>
</tr>

<tr>
<td>`cmd.pager.cursorNextWord`, `cmd.pager.cursorNextViWord`,
`cmd.pager.cursorNextBigWord`</td>
<td>Move the cursor to the beginning of the next [word](#word-types).</td>
</tr>

<tr>
<td>`cmd.pager.cursorPrevWord`, `cmd.pager.cursorPrevViWord`,
`cmd.pager.cursorPrevBigWord`</td>
<td>Move the cursor to the end of the previous [word](#word-types).</td>
</tr>

<tr>
<td>`cmd.pager.cursorWordEnd`, `cmd.pager.cursorViWordEnd`,
`cmd.pager.cursorBigWordEnd`</td>
<td>Move the cursor to the end of the current [word](#word-types), or if already
there, to the end of the next word.</td>
</tr>

<tr>
<td>`cmd.pager.cursorWordBegin`, `cmd.pager.cursorViWordBegin`,
`cmd.pager.cursorBigWordBegin`</td>
<td>Move the cursor to the beginning of the current [word](#word-types), or if
already there, to the end of the previous word.</td>
</tr>

<tr>
<td>`cmd.pager.cursorPrevLink`, `cmd.pager.cursorNextLink`</td>
<td>Move the cursor to the end/beginning of the previous/next clickable
element (e.g. link, input field, etc).</td>
</tr>

<tr>
<td>`cmd.pager.cursorPrevParagraph`, `cmd.pager.cursorNextParagraph`</td>
<td>Move the cursor to the end/beginning of the nth previous/next
paragraph.</td>
</tr>

<tr>
<td>`cmd.pager.cursorRevNthLink`</td>
<td>Move the cursor to the nth link of the document, counting backwards
from the document's last line.</td>
</tr>

<tr>
<td>`cmd.pager.cursorNthLink`</td>
<td>Move the cursor to the nth link of the document.</td>
</tr>

<tr>
<td>`cmd.pager.pageUp`, `cmd.pager.pageDown`, `cmd.pager.pageLeft`,
`cmd.pager.pageRight`</td>
<td>Scroll up/down/left/right by n pages, or if n is unspecified, by one
page.</td>
</tr>

<tr>
<td>`cmd.pager.halfPageUp`, `cmd.pager.halfPageDown`, `cmd.pager.halfPageLeft`,
`pager.halfPageUp`</td>
<td>Scroll up/down/left/right by n half pages, or if n is unspecified, by one
page.</td>
</tr>

<tr>
<td>`cmd.pager.scrollUp`, `cmd.pager.scrollDown`, `cmd.pager.scrollLeft`,
`cmd.pager.scrollRight`</td>
<td>Scroll up/down/left/right by n lines, or if n is unspecified, by one
line.</td>
</tr>

<tr>
<td>`cmd.pager.click`</td>
<td>Click the HTML element currently under the cursor.</td>
</tr>

<tr>
<td>`cmd.pager.load`</td>
<td>Open the current address in the URL bar.</td>
</tr>

<tr>
<td>`cmd.pager.webSearch`</td>
<td>Open the URL bar with an arbitrary search engine. At the moment, this is
DuckDuckGo Lite. (Note: Chawan developers aren't affiliated with DuckDuckGo the
company or their product in any way.)</td>
</tr>

<tr>
<td>`cmd.pager.dupeBuffer`</td>
<td>Duplicate the current buffer by loading its source to a new buffer.</td>
</tr>

<tr>
<td>`cmd.pager.discardBuffer`</td>
<td>Discard the current buffer, and move back to the previous/next buffer
depending on what the previously viewed buffer was.</td>
</tr>

<tr>
<td>`cmd.pager.discardBufferPrev`, `cmd.pager.discardBufferNext`</td>
<td>Discard the current buffer, and move back to the previous/next buffer, or
open the link under the cursor.</td>
</tr>

<tr>
<td>`cmd.pager.discardTree`</td>
<td>Discard all child buffers of the current buffer.</td>
</tr>

<tr>
<td>`cmd.pager.reload`</td>
<td>Open a new buffer with the current buffer's URL, replacing the current
buffer.</td>
</tr>

<tr>
<td>`cmd.pager.reshape`</td>
<td>Reshape the current buffer (=render the current page anew.)</td>
</tr>

<tr>
<td>`cmd.pager.redraw`</td>
<td>Redraw screen contents. Useful if something messed up the display.</td>
</tr>

<tr>
<td>`cmd.pager.toggleSource`</td>
<td>If viewing an HTML buffer, open a new buffer with its source. Otherwise,
open the current buffer's contents as HTML.</td>
</tr>

<tr>
<td>`cmd.pager.cursorFirstLine`, `cmd.pager.cursorLastLine`</td>
<td>Move to the beginning/end in the buffer.</td>
</tr>

<tr>
<td>`cmd.pager.cursorTop`</td>
<td>Move to the first line on the screen. (Equivalent to H in vi.)</td>
</tr>

<tr>
<td>`cmd.pager.cursorMiddle`</td>
<td>Move to the line in the middle of the screen. (Equivalent to M in vi.)</td>
</tr>

<tr>
<td>`cmd.pager.cursorBottom`</td>
<td>Move to the last line on the screen. (Equivalent to L in vi.)</td>
</tr>

<tr>
<td>`cmd.pager.raisePage`, `cmd.pager.raisePageBegin`,
`cmd.pager.centerLine`, `cmd.pager.centerLineBegin`,
`cmd.pager.lowerPage`, `cmd.pager.lowerPageBegin`</td>
<td>If n is specified, move cursor to line n. Then,

* `raisePage` scrolls down so that the cursor is on the top line of the screen.
  (vi `z<CR>`, vim `zt`.)
* `centerLine` shifts the screen so that the cursor is in the middle of the
  screen. (vi `z.`, vim `zz`.)
* `lowerPage` scrolls up so that the cursor is on the bottom line of the screen.
  (vi `z-`, vim `zb`.)

The -`Begin` variants also move the cursor to the line's first non-blank
character, as the variants originating from vi do.
</td>
</tr>

<tr>
<td>`cmd.pager.nextPageBegin`</td>
<td>If n is specified, move to the screen before the nth line and raise the page.
Otherwise, go to the previous screen's last line and raise the page. (`z+`
in vi.)</td>
</tr>

<tr>
<td>`cmd.pager.previousPageBegin`</td>
<td>If n is specified, move to the screen before the nth line and raise the
page.  Otherwise, go to the previous screen's last line and raise the page.
(`z+` in vi.)</td>
</tr>

<tr>
<td>`cmd.pager.cursorLeftEdge`, `cmd.pager.cursorMiddleColumn`,
`cmd.pager.cursorRightEdge`</td>
<td>Move to the first/middle/last column on the screen.</td>
</tr>

<tr>
<td>`cmd.pager.centerColumn`</td>
<td>Center screen around the current column. (w3m `Z`.)</td>
</tr>

<tr>
<td>`cmd.pager.lineInfo`</td>
<td>Display information about the current line on the status line.</td>
</tr>

<tr>
<td>`cmd.pager.searchForward`, `cmd.pager.searchBackward`</td>
<td>Search for a string in the current buffer, forwards or backwards.</td>
</tr>

<tr>
<td>`cmd.pager.isearchForward`, `cmd.pager.searchBackward`</td>
<td>Incremental-search for a string, highlighting the first result, forwards or
backwards.</td>
</tr>

<tr>
<td>`cmd.pager.gotoLineOrStart`, `cmd.pager.gotoLineOrEnd`</td>
<td>If n is specified, jump to line n. Otherwise, jump to the start/end of the
page.</td>
</tr>

<tr>
<td>`cmd.pager.searchNext`, `cmd.pager.searchPrev`</td>
<td>Jump to the nth (or if unspecified, first) next/previous search result.</td>
</tr>

<tr>
<td>`cmd.pager.peek`</td>
<td>Display a message of the current buffer's URL on the status line.</td>
</tr>

<tr>
<td>`cmd.pager.peekCursor`</td>
<td>Display a message of the URL or title under the cursor on the status line.
Multiple calls allow cycling through the two. (i.e. by default, press u once ->
title, press again -> URL)</td>
</tr>

<tr>
<td>`cmd.pager.setMark`</td>
<td>Wait for a character `x` and then set a mark with the ID `x`.</td>
</tr>

<tr>
<td>`cmd.pager.gotoMark`, `cmd.pager.gotoMarkY`</td>
<td>Wait for a character `x` and then jump to the mark with the ID `x` (if it
exists on the page).<br>
`gotoMark` sets both the X and Y positions; gotoMarkY only sets the Y
position.</td>
</tr>

<tr>
<td>`cmd.pager.markURL`</td>
<td>Convert URL-like strings to anchors on the current page.</td>
</tr>

<tr>
<td>`cmd.pager.saveLink`</td>
<td>Save resource from the URL pointed to by the cursor to the disk.</td>
</tr>

<tr>
<td>`cmd.pager.saveSource`</td>
<td>Save the source of the current buffer to the disk.</td>
</tr>

<tr>
<td>`cmd.pager.copyURL`</td>
<td>Copy the current buffer's URL to the system clipboard.</td>
</tr>

<tr>
<td>`cmd.pager.copyCursorLink`</td>
<td>Copy the link under the cursor to the system clipboard.</td>
</tr>

<tr>
<td>`cmd.pager.copyCursorImage`</td>
<td>Copy the URL of the image under the cursor to the system clipboard.</td>
</tr>

</table>


### Line-editing actions

<table>

<tr>
<th>Name</th>
<th>Function</th>
</tr>

<tr>
<td>`cmd.line.submit`</td>
<td>Submit the line.</td>
</tr>

<tr>
<td>`cmd.line.cancel`</td>
<td>Cancel the current operation.</td>
</tr>

<tr>
<td>`cmd.line.backspace`, `cmd.line.delete`</td>
<td>Delete character before (backspace)/after (delete) the cursor.</td>
</tr>

<tr>
<td>`cmd.line.clear`, `cmd.line.kill`</td>
<td>Delete text before (clear)/after (kill) the cursor.</td>
</tr>

<tr>
<td>`cmd.line.clearWord`, `cmd.line.killWord`</td>
<td>Delete word before (clear)/after (kill) the cursor.</td>
</tr>

<tr>
<td>`cmd.line.backward`, `cmd.line.forward`</td>
<td>Move cursor backward/forward by one character.</td>
</tr>

<tr>
<td>`cmd.line.prevWord`, `cmd.line.nextWord`</td>
<td>Move cursor to the previous/next word by one character</td>
</tr>

<tr>
<td>`cmd.line.begin`, `cmd.line.end`</td>
<td>Move cursor to the beginning/end of the line.</td>
</tr>

<tr>
<td>`cmd.line.escape`</td>
<td>Ignore keybindings for next character.</td>
</tr>

<tr>
<td>`cmd.line.prevHist`, `cmd.line.nextHist`</td>
<td>Jump to the previous/next history entry</td>
</tr>

</table>

Note: to facilitate URL editing, the line editor has a different definition
of what a word is than the pager. For the line editor, a word is either a
sequence of alphanumeric characters, or any single non-alphanumeric
character. (This means that e.g. `https://` consists of four words: `https`,
`:`, `/` and `/`.)

```Examples:
# Control+A moves the cursor to the beginning of the line.
'C-a' = 'cmd.line.begin'

# Escape+D deletes everything after the cursor until it reaches a word-breaking
# character.
'M-d' = 'cmd.line.killWord'
```

## Appendix

### Regex handling

Regular expressions are currently handled using libregexp which is included in
QuickJS. This means that all regular expressions work as in JavaScript.

There are two different modes of regex preprocessing in Chawan: "search" mode,
and "match" mode. "match" mode is used for configurations (meaning in all values
in this document described as "regex"). "search" mode is used for the on-page
search function (using searchForward/isearchForward etc.)

#### Match mode

Regular expressions are assumed to be exact matches, except when they start
with a caret (^) sign or end with an unescaped dollar ($) sign.

In other words, the following transformations occur:

```
^abcd -> ^abcd (no change, only beginning is matched)
efgh$ -> efgh$ (no change, only end is matched)
^ijkl$ -> ^ijkl$ (no change, the entire line is matched)
mnop -> ^mnop$ (changed to exact match, the entire line is matched)
```

Match mode has no way to toggle JavaScript regex flags like `i`.

#### Search mode

For on-page search, the above transformations do not apply; the search `/abcd`
searches for the string `abcd` inside all lines.

"Search" mode also has some other convenience transformations:

* The string `\c` (backslash + lower-case c) inside a search-mode regex enables
  case-insensitive matching.
* Conversely, `\C` (backslash + capital C) disables case-insensitive matching.
  (Useful if you have `ignore-case` set to true, which is the default.)
* `\<` and `\>` is converted to `\b` (as in vi, grep, etc.)

Note that none of these work in "match" mode.

### Path handling

Rules for path handling are similar to how strings in the shell are handled.

* Tilde-expansion is used to determine the user's home directory. So
  e.g. `~/whatever` works.
* Environment variables can be used like `$ENV_VAR`.
* Relative paths are relative to the Chawan configuration directory.

Some internal variables are also defined by Chawan. These can be accessed using
the non-standard syntax `${%VARIABLE}`:

* `${%CHA_BIN_DIR}`: the directory which the `cha` binary resides in. Note
  that symbolic links are automatically resolved to determine this path.
* `${%CHA_LIBEXEC_DIR}`: the directory for all executables Chawan uses
  for operation. By default, this is `${%CHA_BIN_DIR}/../libexec/chawan`.

### Word types

Word-based pager commands can operate with different definitions of
words. Currently, these are:

* w3m words
* vi words
* Big words

#### w3m word

A w3m word is a sequence of alphanumeric characters. Symbols are treated
in the same way as whitespace.

#### vi word

A vi word is a sequence of alphanumeric characters, OR a sequence of symbols.

vi words may be separated by whitespace; however, symbolic and alphanumeric
vi words do not have to be whitespace-separated. e.g. following character
sequence contains two words:

```
hello[]+{}@`!
```

#### Big word

A big word is a sequence of non-whitespace characters.

It is essentially the same as a w3m word, but with symbols being defined as
non-whitespace.

<!-- MANON

## See also

**cha**(1)
MANOFF -->
