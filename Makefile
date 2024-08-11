NIMC ?= nim c
OBJDIR ?= .obj
OUTDIR ?= target
# These paths are quoted in recipes.
PREFIX ?= /usr/local
MANPREFIX ?= $(PREFIX)/share/man
MANPREFIX1 ?= $(MANPREFIX)/man1
MANPREFIX5 ?= $(MANPREFIX)/man5
TARGET ?= release
# This must be single-quoted, because it is not a real shell substitution.
# The default setting is at {the binary's path}/../libexec/chawan.
# You may override it with any path if your system does not have a libexec
# directory, but make sure to surround it with quotes if it contains spaces.
# (This way, the cha binary can be directly executed without installation.)
LIBEXECDIR ?= '$${%CHA_BIN_DIR}/../libexec/chawan'
# If overridden, take libexecdir that was specified.
# Otherwise, just install to libexec/chawan.
ifeq ($(LIBEXECDIR),'$${%CHA_BIN_DIR}/../libexec/chawan')
LIBEXECDIR_CHAWAN = "$(DESTDIR)$(PREFIX)/libexec/chawan"
else
LIBEXECDIR_CHAWAN = $(LIBEXECDIR)
endif

# These paths are quoted in recipes.
OUTDIR_TARGET = $(OUTDIR)/$(TARGET)
OUTDIR_BIN = $(OUTDIR_TARGET)/bin
OUTDIR_LIBEXEC = $(OUTDIR_TARGET)/libexec/chawan
OUTDIR_CGI_BIN = $(OUTDIR_LIBEXEC)/cgi-bin
OUTDIR_MAN = $(OUTDIR_TARGET)/share/man

# I won't take this from the environment for obvious reasons. Please override it
# in the make command if you must, or (preferably) fix your environment so it's
# not needed.
DANGER_DISABLE_SANDBOX = 0

# Nim compiler flags
ifeq ($(TARGET),debug)
FLAGS += -d:debug --debugger:native
else ifeq ($(TARGET),release)
FLAGS += -d:release -d:strip -d:lto
else ifeq ($(TARGET),release0)
FLAGS += -d:release --stacktrace:on
else ifeq ($(TARGET),release1)
FLAGS += -d:release --debugger:native
endif

.PHONY: all
all: $(OUTDIR_BIN)/cha $(OUTDIR_BIN)/mancha $(OUTDIR_CGI_BIN)/http \
	$(OUTDIR_CGI_BIN)/gmifetch $(OUTDIR_LIBEXEC)/gmi2html \
	$(OUTDIR_CGI_BIN)/gopher $(OUTDIR_LIBEXEC)/gopher2html \
	$(OUTDIR_CGI_BIN)/cha-finger $(OUTDIR_CGI_BIN)/about \
	$(OUTDIR_CGI_BIN)/file $(OUTDIR_CGI_BIN)/ftp \
	$(OUTDIR_CGI_BIN)/man $(OUTDIR_CGI_BIN)/spartan \
	$(OUTDIR_CGI_BIN)/stbi $(OUTDIR_CGI_BIN)/jebp \
	$(OUTDIR_LIBEXEC)/urldec $(OUTDIR_LIBEXEC)/urlenc \
	$(OUTDIR_LIBEXEC)/md2html $(OUTDIR_LIBEXEC)/ansi2html
	ln -sf "$(OUTDIR)/$(TARGET)/bin/cha" cha

$(OUTDIR_BIN)/cha: src/*.nim src/**/*.nim src/**/*.c res/* res/**/* \
		res/map/idna_gen.nim nim.cfg
	@mkdir -p "$(OUTDIR_BIN)"
	$(NIMC) --nimcache:"$(OBJDIR)/$(TARGET)/cha" -d:libexecPath=$(LIBEXECDIR) \
                -d:disableSandbox=$(DANGER_DISABLE_SANDBOX) $(FLAGS) \
		-o:"$(OUTDIR_BIN)/cha" src/main.nim

$(OUTDIR_BIN)/mancha: adapter/tools/mancha.nim
	@mkdir -p "$(OUTDIR_BIN)"
	$(NIMC) --nimcache:"$(OBJDIR)/$(TARGET)/mancha" $(FLAGS) \
		-o:"$(OUTDIR_BIN)/mancha" $(FLAGS) adapter/tools/mancha.nim

$(OBJDIR)/genidna: res/genidna.nim
	$(NIMC) --nimcache:"$(OBJDIR)/idna_gen_cache" -d:danger \
		-o:"$(OBJDIR)/genidna" res/genidna.nim

res/map/idna_gen.nim: $(OBJDIR)/genidna
	$(OBJDIR)/genidna > res/map/idna_gen.nim

$(OBJDIR)/gencharwidth: res/gencharwidth.nim
	$(NIMC) --nimcache:"$(OBJDIR)/charwidth_gen_cache" -d:danger \
		-o:"$(OBJDIR)/gencharwidth" res/gencharwidth.nim

res/map/charwidth_gen.nim: $(OBJDIR)/gencharwidth res/map/EastAsianWidth.txt
	$(OBJDIR)/gencharwidth > res/map/charwidth_gen.nim

src/utils/strwidth.nim: res/map/charwidth_gen.nim src/utils/proptable.nim

GMIFETCH_CFLAGS = -Wall -Wextra -std=c89 -pedantic -g -O2 $$(pkg-config --cflags libssl) $$(pkg-config --cflags libcrypto)
GMIFETCH_LDFLAGS = $$(pkg-config --libs libssl) $$(pkg-config --libs libcrypto)
$(OUTDIR_CGI_BIN)/gmifetch: adapter/protocol/gmifetch.c
	@mkdir -p "$(OUTDIR_CGI_BIN)"
	$(CC) $(GMIFETCH_CFLAGS) adapter/protocol/gmifetch.c -o "$(OUTDIR_CGI_BIN)/gmifetch" $(GMIFETCH_LDFLAGS)

twtstr = src/utils/twtstr.nim src/utils/charcategory.nim src/utils/map.nim
$(OUTDIR_CGI_BIN)/man: lib/monoucha/monoucha/jsregex.nim \
		lib/monoucha/monoucha/libregexp.nim src/types/opt.nim $(twtstr)
$(OUTDIR_CGI_BIN)/http: adapter/protocol/curlwrap.nim \
		adapter/protocol/curlerrors.nim adapter/protocol/curl.nim \
		src/utils/sandbox.nim $(twtstr)
$(OUTDIR_CGI_BIN)/about: res/chawan.html res/license.md
$(OUTDIR_CGI_BIN)/file: adapter/protocol/dirlist.nim $(twtstr) \
		src/utils/strwidth.nim src/loader/connecterror.nim
$(OUTDIR_CGI_BIN)/ftp: adapter/protocol/dirlist.nim $(twtstr) \
		src/utils/strwidth.nim src/loader/connecterror.nim src/types/opt.nim \
		adapter/protocol/curl.nim
$(OUTDIR_CGI_BIN)/gopher: adapter/protocol/curlwrap.nim adapter/protocol/curlerrors.nim \
		adapter/gophertypes.nim adapter/protocol/curl.nim \
		src/loader/connecterror.nim $(twtstr)
$(OUTDIR_CGI_BIN)/stbi: adapter/img/stbi.nim adapter/img/stb_image.c \
		adapter/img/stb_image.h src/utils/sandbox.nim
$(OUTDIR_CGI_BIN)/jebp: adapter/img/jebp.c adapter/img/jebp.h \
		src/utils/sandbox.nim
$(OUTDIR_LIBEXEC)/urlenc: $(twtstr)
$(OUTDIR_LIBEXEC)/gopher2html: adapter/gophertypes.nim $(twtstr)
$(OUTDIR_LIBEXEC)/ansi2html: src/types/color.nim $(twtstr)

$(OUTDIR_CGI_BIN)/%: adapter/protocol/%.nim
	@mkdir -p "$(OUTDIR_CGI_BIN)"
	$(NIMC) $(FLAGS) --nimcache:"$(OBJDIR)/$(TARGET)/$(subst $(OUTDIR_CGI_BIN)/,,$@)" \
		-d:disableSandbox=$(DANGER_DISABLE_SANDBOX) -o:"$@" $<

$(OUTDIR_CGI_BIN)/%: adapter/protocol/%
	@mkdir -p "$(OUTDIR_CGI_BIN)"
	cp $< "$(OUTDIR_CGI_BIN)"

$(OUTDIR_CGI_BIN)/%: adapter/img/%.nim
	@mkdir -p "$(OUTDIR_CGI_BIN)"
	$(NIMC) $(FLAGS) --nimcache:"$(OBJDIR)/$(TARGET)/$(subst $(OUTDIR_CGI_BIN)/,,$@)" \
                -d:disableSandbox=$(DANGER_DISABLE_SANDBOX) -o:"$@" $<

$(OUTDIR_LIBEXEC)/%: adapter/format/%.nim
	@mkdir -p "$(OUTDIR_LIBEXEC)"
	$(NIMC) $(FLAGS) --nimcache:"$(OBJDIR)/$(TARGET)/$(subst $(OUTDIR_LIBEXEC)/,,$@)" \
		-o:"$@" $<

$(OUTDIR_LIBEXEC)/%: adapter/tools/%.nim
	@mkdir -p "$(OUTDIR_LIBEXEC)"
	$(NIMC) $(FLAGS) --nimcache:"$(OBJDIR)/$(TARGET)/$(subst $(OUTDIR_LIBEXEC)/,,$@)" \
		-o:"$@" $<

$(OUTDIR_LIBEXEC)/urldec: $(OUTDIR_LIBEXEC)/urlenc
	(cd "$(OUTDIR_LIBEXEC)"; ln -sf urlenc urldec)

$(OBJDIR)/man/cha-%.md: doc/%.md md2manpreproc
	@mkdir -p "$(OBJDIR)/man"
	./md2manpreproc $< > $@

doc/cha-%.5: $(OBJDIR)/man/cha-%.md
	pandoc --standalone --to man $< -o $@

.PHONY: clean
clean:
	rm -rf "$(OBJDIR)/$(TARGET)"

.PHONY: distclean
distclean: clean
	rm -rf "$(OUTDIR)"

manpages1 = cha.1 mancha.1
manpages5 = cha-config.5 cha-mailcap.5 cha-mime.types.5 cha-localcgi.5 \
	cha-urimethodmap.5 cha-protocols.5 cha-api.5

manpages = $(manpages1) $(manpages5)

.PHONY: manpage
manpage: $(manpages:%=doc/%)

protocols = http about file ftp gopher gmifetch cha-finger man spartan stbi jebp
converters = gopher2html md2html ansi2html gmi2html
tools = urlenc

.PHONY: install
install:
	mkdir -p "$(DESTDIR)$(PREFIX)/bin"
	install -m755 "$(OUTDIR_BIN)/cha" "$(DESTDIR)$(PREFIX)/bin"
	install -m755 "$(OUTDIR_BIN)/mancha" "$(DESTDIR)$(PREFIX)/bin"
# intentionally not quoted
	mkdir -p $(LIBEXECDIR_CHAWAN)/cgi-bin
	for f in $(protocols); do \
	install -m755 "$(OUTDIR_CGI_BIN)/$$f" $(LIBEXECDIR_CHAWAN)/cgi-bin; \
	done
	for f in $(converters) $(tools); \
	do install -m755 "$(OUTDIR_LIBEXEC)/$$f" $(LIBEXECDIR_CHAWAN); \
	done
# urldec is just a symlink to urlenc
	(cd $(LIBEXECDIR_CHAWAN); ln -sf urlenc urldec)
	mkdir -p "$(DESTDIR)$(MANPREFIX1)"
	for f in $(manpages1); do install -m644 "doc/$$f" "$(DESTDIR)$(MANPREFIX1)"; done
	mkdir -p "$(DESTDIR)$(MANPREFIX5)"
	for f in $(manpages5); do install -m644 "doc/$$f" "$(DESTDIR)$(MANPREFIX5)"; done

.PHONY: uninstall
uninstall:
	rm -f "$(DESTDIR)$(PREFIX)/bin/cha"
	rm -f "$(DESTDIR)$(PREFIX)/bin/mancha"
# intentionally not quoted
	for f in $(protocols); do rm -f $(LIBEXECDIR_CHAWAN)/cgi-bin/$$f; done
# note: png has been removed in favor of stbi.
	rm -f $(LIBEXECDIR_CHAWAN)/cgi-bin/png
# note: data has been moved back into the main binary.
	rm -f $(LIBEXECDIR_CHAWAN)/cgi-bin/data
	rmdir $(LIBEXECDIR_CHAWAN)/cgi-bin || true
	for f in $(converters) $(tools); do rm -f $(LIBEXECDIR_CHAWAN)/$$f; done
	rmdir $(LIBEXECDIR_CHAWAN) || true
	for f in $(manpages5); do rm -f "$(DESTDIR)$(MANPREFIX5)/$$f"; done
	for f in $(manpages1); do rm -f "$(DESTDIR)$(MANPREFIX1)/$$f"; done

.PHONY: submodule
submodule:
	git submodule update --init

.PHONY: test
test:
	(cd test/js; ./run_js_tests.sh)
	(cd test/layout; ./run_layout_tests.sh)
