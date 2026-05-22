.PHONY: build install clean

build:
	swift build

install:
	swift build -c release
	@mkdir -p bin
	@install "$(CURDIR)/.build/release/mpd-virt" "bin/mpd-virt"
	@echo "Native binary: bin/mpd-virt"

clean:
	swift package clean
