# Chawan - a web browser for your terminal

[Project page](https://sr.ht/~bptato/chawan)

![Screenshot of Chawan displaying its SourceHut page](doc/showcase.png)

## What is this?

A text-mode web browser. It displays websites in your terminal and allows
you to navigate on them.

It can also be used as a terminal pager.

## Compiling

Note: a POSIX-compliant operating system is required.

1. Clone the Chawan repository:  
   `git clone https://git.sr.ht/~bptato/chawan && cd chawan`
2. Install the Nim compiler: <https://nim-lang.org/install.html>
	* Please use 1.6.14 or newer, ideally 2.0.8. Versions older than 1.6.14
	  will not work. (You can check your Nim compiler's version using
	  `nim -v`.)
3. Install the following dependencies:
	* libcurl: <https://curl.se/libcurl/>
	* pkg-config, pkgconf, or similar (must be found as "pkg-config" in your
	  `$PATH`)
	* (Linux only) libseccomp: <https://github.com/seccomp/libseccomp>
	* GNU make. On systems where it is not the default make, use `gmake`
	  in the following steps.
	* Recommended: a termcap library. e.g. ncurses comes with one.
	* TL;DR for Debian:
	  `apt install libcurl4-openssl-dev pkg-config make ncurses-base libseccomp-dev`
4. Download parts of Chawan found in other repositories: `make submodule`
5. Run `make` (without arguments).
6. Install using `make install` (e.g. `sudo make install`).

Then, try:

```bash
$ cha -V # open in visual mode for a list of default keybindings
$ cha example.org # open your favorite website directly from the shell
$ mancha cha # read the cha(1) man page using `mancha'
```

## Features

Currently implemented features are:

* multi-processing, incremental loading of documents
* multi-charset, double-width aware text display (but no bi-di yet)
* HTML5 support, forms, cookies
* CSS-based layout engine: supports flow layout, table layout, flexbox layout
* user-programmable keybindings (defaults are vi(m)-like)
* basic JavaScript support in documents (disabled by default for security
  reasons)
* supports several protocols: HTTP(S), FTP, Gopher, Gemini, Finger, etc.
* can [load](doc/localcgi.md) [user-defined](doc/urimethodmap.md)
  [protocols](doc/protocols.md)/[file formats](doc/mailcap.md)
* built-in markdown viewer, man page viewer
* WIP sixel/kitty image support (still somewhat limited; progress tracked at
  <https://todo.sr.ht/~bptato/chawan/13>)
* mouse support
* OS-level sandboxing on FreeBSD, OpenBSD and Linux (through Capsicum, pledge
  and libseccomp)

...with a lot more [planned](todo).

## Documentation

* build/compilation options: [doc/build.md](doc/build.md)
* manpage: [doc/cha.1](doc/cha.1)
* configuration options: [doc/config.md](doc/config.md)
* API description (for keybindings): [doc/api.md](doc/api.md)
* mailcap: [doc/mailcap.md](doc/mailcap.md)
* mime.types: [doc/mime.types.md](doc/mime.types.md)
* urimethodmap: [doc/urimethodmap.md](doc/urimethodmap.md)
* local CGI: [doc/localcgi.md](doc/localcgi.md)
* protocols: [doc/protocols.md](doc/protocols.md)
* troubleshooting: [doc/troubleshooting.md](doc/troubleshooting.md)

## Neighbors

Many other text-based web browsers exist. Here's some recommendations if you
want to try more established ones:

* [w3m](https://github.com/tats/w3m) - A text-mode browser, extensible using
  local-cgi. Also has inline image display and very good table support.
  Inspired many features of Chawan.
* [elinks](https://github.com/rkd77/elinks) - Has CSS and JavaScript support,
  and incremental rendering (it's pretty fast.)
* [lynx](https://lynx.invisible-island.net/) - "THE text-based web browser."
* [edbrowse](http://edbrowse.org/) - This one looks more like `ed` than
  `less` or `vi`. Mainly designed for blind users.
* [browsh](https://www.brow.sh/) - Firefox in your terminal.

## FAQ

### I have encountered a bug/technical issue while using Chawan.

Please check our [troubleshooting](doc/troubleshooting.md) document. If this
does not help, please [open a ticket](https://todo.sr.ht/~bptato/chawan)
or post to the [mailing list](mailto:~bptato/chawan-devel@lists.sr.ht).

### I'm interested in the technical details of Chawan.

Here's some:

* The browser engine (HTML parsing, rendering, etc.) has been developed
  from scratch in the memory-safe Nim programming language. Some of these
  modules are now also available as separate libraries.
* Uses QuickJS for JavaScript execution and regex matching.
* Each buffer (page) is isolated in a separate process. File loading is done
  through dedicated loader processes.
* termcap for basic terminal capability querying, and terminal queries where
  possible.
* The default image decoder currently uses the `stb_image` library. Image codecs
  are handled as protocols, so users will be able to add their own codecs (once
  I document how it works...)

For further details, please refer to the [architecture](doc/architecture.md)
document.

### Why write another web browser?

w3m is close to my ideal browser, but its architecture leaves a lot to be
desired. So initially I just wanted a simple w3m clone with a more maintainable
code base.

The project has evolved a lot since then, even including things I had not
initially intended to (like CSS). Now it is mainly focused on:

* Simplicity, as much as "modern standards" permit. Chawan has very few external
  dependencies, and favors reduced code size over speed. This lowers the risk
  of supply chain attacks, and helps me understand what my browser is doing.
* Privacy & security. The default configuration sacrifices usability in favor of
  privacy on purpose, and unsafe features like JS, cookies, etc. must be enabled
  separately. The multi-processed design enables effective sandboxing of
  critical processes.
* Adding the rest of missing w3m features, and improving upon those.
* Most importantly: having fun in the process :)

## License

Chawan is dedicated to the public domain. See the UNLICENSE file for details.

Chawan also includes and depends on several other libraries. For further
details, check the <about:license> page in Chawan, or read the same document
[here](res/license.md).
