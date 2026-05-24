.PHONY: build install uninstall clean

PREFIX  ?= $(HOME)/.local
BINDIR  ?= $(PREFIX)/bin
BIN     := $(BINDIR)/mpd-virt

build:
	swift build

install:
	swift build -c release
	@mkdir -p "$(BINDIR)"
	@install "$(CURDIR)/.build/release/mpd-virt" "$(BIN)"
	@BINDIR="$(BINDIR)" BIN="$(BIN)" sh "$(CURDIR)/scripts/install-message.sh"

uninstall:
	@rm -f "$(BIN)"
	@echo "Removed: $(BIN)"

clean:
	swift package clean
