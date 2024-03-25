# Architecture of Chawan

This document describes some aspects of how Chawan works.

**Table of contents**

* [Module organization](#module-organization)
* [Process model](#process-model)
	* [Main process](#main-process)
	* [Forkserver](#forkserver)
	* [Loader](#loader)
	* [Buffer](#buffer)
* [Opening buffers](#opening-buffers)
* [Parsing HTML](#parsing-html)
* [JavaScript](#javascript)
	* [General](#general)
	* [JS in the pager](#js-in-the-pager)
	* [JS in the buffer](#js-in-the-buffer)
* [Styling](#styling)
* [Layout](#layout)
* [Rendering](#rendering)

## Module organization

Explanation for the separate directories found in src/:

* bindings: bindings for various C libraries. (Not wrappers, just the plain
  C API as Nim procedure prototypes.)
* config: configuration-related code. Mainly parsers for config files.
* css: styling-related code; CSS parsing and cascading.
* html: DOM building, DOM functions, the DOM itself, forms, etc. Note that it
  does not include the [HTML parser](https://git.sr.ht/~bptato/chame) itself.
* img: image-related code. Mostly useless because we can't draw images to the
  screen yet. (One day...)
* io: code for IPC, interaction with the file system, etc.
* js: wrappers for QuickJS.
* layout: the layout engine and its renderer.
* loader: code for the file loader server (?).
* local: code for the main process (i.e. the pager).
* server: code for processes other than the main process, e.g. buffer and
  forkserver. (Why is loader not here? idk)
* types: mainly definitions of data types and things I didn't know where to put.
* utils: things I didn't know where to put part 2

## Process model

Described as a tree:

* cha (main process)
	- forkserver (forked immediately at startup)
		* loader
			- local CGI scripts
		* buffer(s)
	- mailcap processes (e.g. md2html, feh, ...)
	- editor (e.g. vi)

### Main process

The main process runs code related to the pager. This includes processing
user input, printing buffer contents to the screen, and managing buffers in
general. The complete list of buffers is only known to the main process.

Mailcap commands are executed by the main process. This depends on knowing the
content type of the resource, so the main process also reads in all network
headers of navigation responses before launching a buffer process. More on this
in [Opening buffers](#opening-buffers).

### Forkserver

For forking buffer and loader processes, a forkserver process is launched at the
very beginning of every 'cha' invocation. The fork server is responsible for
forking the loader process, and also buffer processes.

We use a fork server for two reasons:

1. It helps clean up child processes when the main process crashes. (We open
   pipes between the main process and the fork server, and kill all child
   processes from the fork server on EOF.)
2. It allows us to start new processes without cloning the pager's entire address
   space. This reduces the impact of memory bugs somewhat, and also our memory
   usage.

The fork server is not used for mailcap or CGI processes, because their address
space is replaced by exec anyway. (Also, it would be slow.)

### Loader

The loader process takes requests from the main process and the buffer
processes. Then, depending on the scheme, it responds by performing one of the
following steps:

* `cgi-bin:` Start a CGI script, and read out its stdout into the response body.
  For the main contents of text-based buffers, it also saves the response
  into the cache.  
  This is also used for schemes like http/s, ftp, etc. by internally rewriting
  them into the appropriate `cgi-bin:` URL.
* `stream:` Do the same thing as above, but read from a file descriptor passed
  to the loader beforehand. This is used when stdin is a file, e.g.
  `echo test | cha`. It is also used for mailcap entries with an x-htmloutput
  field.
* `cache:` Read the file from the cache. This is used by the pager for the
  "view source" operation, and by buffers in the rare situation where their
  initial character encoding guess proves to be incorrect and they need to
  rewind the source.

The loader process distinguishes between clients (i.e the main process or
buffers) through client keys. Note that this does not defend against rogue
clients; the key comparison is susceptible to timing attacks. (TODO: it should
not be.) It does however help us block further requests from buffers that have
been discarded by the pager.

### Buffer

Buffer processes parse HTML, optionally query external resources from loader,
run styling, JS, and finally render the page to an internal canvas.

Buffers are managed by the pager through Container objects. A UNIX domain socket
is established between each buffer and the pager to enable communication between
them.

## Opening buffers

Scenario: the user attempts to navigate to <https://example.org>.

1. pager creates a new container for the target URL.
2. pager sends a request for "https://example.org" to the loader. Then, it
   registers the file descriptor in its selector, and does something else until
   select() reports activity on the file descriptor.
3. loader rewrites "https://example.org" into "cgi-bin:http". It then runs the
   http CGI script with the appropriate environment variables set.
4. The http CGI script opens a connection to example.org. When connected, it
   starts printing out headers it receives to stdout.
5. loader parses these headers, and sends them to pager.
6. pager reads in the headers, and decides what to do based on the Content-Type.
	* If Content-Type is found in mailcap, then the command in that
	  mailcap entry is executed, with the response body dup2'd onto its
	  stdin. If the entry has x-htmloutput, then the command's stdout is
	  taken instead of the response body, and Content-Type is set to
	  text/html. Otherwise, the container is discarded.
	* If Content-Type is text/html, then a new buffer process is created,
	  which then parses the response body as HTML. If it is any `text/*`
	  subtype, then the response is simply inserted into a `<plaintext>` tag.
	* If Content-Type is not a `text/*` type, and no mailcap entry for it
	  is found, then the user is prompted about where they wish to save the
	  file.

## Parsing HTML

The character decoder and the HTML parser are implementations of the WHATWG
standard, and are available as [separate](https://git.sr.ht/~bptato/chagashi)
[libraries](https://git.sr.ht/~bptato/chame).

The decoding and parsing of HTML documents happens in buffer processes. This
operation is asynchronous; when bytes from the network are exhausted, the buffer
will 1) partially render the current document as-is, 2) return it to the pager
so that the user can interact with the document.

Character encoding detection is rather primitive; the list specified in
`encoding.document-charset` is enumerated until either no errors are produced by
the decoder, or no more charsets exist. In some edge cases, the document must be
(and is) re-downloaded from the cache, but this pretty much never happens in
real-world scenarios. (The most common case is that the UTF-8 validator just
runs through the entire document without reporting errors.)

The HTML parser then consumes the input buffer, which on the happy path (valid
UTF-8) is just whatever we pulled from the network as-is. In some cases, a
script calls document.write and then the parser is called re-entrantly.
(Debugging this is not very fun.)

## JavaScript

QuickJS is used by both the pager as a scripting language, and by buffers for
running on-page scripts when JavaScript is enabled.

The core JS related functionality can be found in the js/ module. (One day I
hope to split it out into a standalone library.)

### General

To avoid having to type out all the type conversion & error handling code
manually, we have JS pragmas to automagically turn Nim procedures into
JavaScript functions. An explanation of what these pragmas are & what they do
can be found in the header of js/javascript.nim.

The type conversion itself is handled by the overloaded toJS function and the
generic fromJS function. toJS returns a JSValue, the native data type of
QuickJS. fromJS returns a Result[T, JSError], which is interpreted as follows:

* ok(T) is successful conversion.
* err(JSError) is an error in the conversion.
* ok(nil) for reference types is null. For non-nullable types, null is
  ok(none(T)).
* err(nil) is JS_EXCEPTION, i.e. an exception has been thrown and is being
  propagated.

An additional point of interest is reference types: ref types registered
with the registerType macro can be freely passed to JS, and the function-
defining macros set functions on their JS prototypes. When a ref type is passed
to JS, a shim JS object is associated with the Nim object, and will remain in
memory until neither Nim nor JS has references to it.

Effectively, this means that you can expose Nim objects to JS and take Nim
objects as arguments through the automagical .jsfunc pragma (& friends) without
having to bother with error-prone manual reference counting. How this is
achieved is detailed below. (You generally don't need the following info
unless you're debugging the JS type conversion logic, in which case I offer my
condolences.)

In fact, there is a complication in this system: QuickJS has a reference-
counting GC, but Nim also has a reference-counting GC. Associating two objects
that are managed by two separate GCs is problematic, because even if you can
freely manage the references on both objects, you now have a cycle that only a
cycle collector can break up. A cross-GC cycle collector is obviously out of
question; then it would be easier to just replace the entire GC in one of the
runtimes.

But we don't replace anything. Instead, we hook into the QuickJS cycle
collector (through a custom patch). Every time a JS companion object of a Nim
object would be freed, we first check if the Nim object still has references
from Nim, and if yes, prevent the JS object from being freed by "moving" a
reference to the JS object (i.e. unref Nim, ref JS).

Then, if we want to pass the object to JS again, we add no references to the JS
object, only to the Nim object. By this, we "moved" the reference back to JS.

This way, the Nim cycle collector can destroy the object without problems if no
more references to it exist. But also, if you set some properties on the JS
companion object, it will remain even if no more references exist to it in JS
for some time, only in Nim. i.e. this works:

```js
document.querySelector("html").canary = "chirp";
console.log(document.querySelector("html").canary); /* chirp */
```

### JS in the pager

Currently this is very limited: keybindings can be assigned JavaScript functions
in the config, and then the pager executes those when the keybindings are
pressed.

(This turns out to be a rather poor configuration system, so we have a plan to
improve it [here](https://todo.sr.ht/~bptato/chawan/6). Just need to implement
it some time...)

Also, contents of the start.startup-script option are executed at startup. This
is used when `cha` is called with the `-r` flag.

There *is* an API, but it's severely underdocumented. Web APIs are exposed to
pager too, but you cannot operate on the DOMs themselves from the pager, unless
you create one yourself with DOMParser.parseFromString.

[config.md](config.md) describes all functions that are used in the default
config. However, it does not describe the true nature of the API:
when pager.someFunction is called and someFunction is not present in pager,
it dispatches the call to pager.buffer.someFunction (where pager.buffer is a
reference to the current buffer).

For example, all cursor movement commands described in config.md are in fact
dispatched to the current buffer's container.

### JS in the buffer

The DOM is implemented through the same wrappers as those in pager. (Obviously,
the pager modules are not exposed to buffer JS.)

Aside from document.write, it is mostly straightforward, and usually works OK,
though too many things are missing to really make it useful.

As for document.write: don't ask. It works as far as I can tell, but I wouldn't
know why.

## Styling

css/ contains everything related to styling: CSS parsing and cascading.

The parser is not very interesting, it's just an implementation of the CSS 3
parsing module. The latest iteration of the selector parser is pretty good. The
media query parser is horrible and should be rewritten. And the CSS value parser
works OK, but is missing features like variables.

Cascading is slow, though it could be slower. Chawan has style caching, so
re-styles are normally very fast. Also, a hash map is used for reducing initial
style calculation times. However, we don't have a bloom filter yet.

## Layout

Layout can be found in the layout/ module.

It has some problems:

* CSS was designed for pixel-based displays, not for character-based ones. So we
  have to round a lot, and sometimes this goes wrong.
* In the past years, websites have finally started using flexbox and grid, and
  we have neither, so things look very ugly.
* Even what we do have has plenty of bugs. (Sad.)
* It's slow on large documents, because we don't have partial layouting
  capabilities.

A good layout engine would be able to skip layouting of contents before/after
the currently visible part of the screen, especially in plain text files. Sadly
we don't have this functionality; everything is laid out again from scratch
every time we may have to re-layout.

Our layout engine is a rather simple procedural layout implementation. It runs
in two passes.

In the first pass, it generates the layout tree; this is important because rules
for generating anonymous boxes are surprisingly involved. (Specifically,
anonymous inline box handling is kind of a mess.)

The second pass then does the actual arrangement of the boxes on the screen. The
output tree uses relative coordinates; that is, every box is positioned relative
to its parent.

Layout is fully recursive. This means that after a certain nesting depth, the
buffer will run out of stack space and promptly crash.

### Rendering

After layout is finished, the document is rendered onto a text-based canvas,
which is represented as a sequence of strings associated with their formatting.

Again, the entire document is rendered, which is the main reason why Chawan
performs poorly on large documents.

The positive side of this is that search is very simple (and fast), since we are
just running regexes over a linear sequence of strings.
