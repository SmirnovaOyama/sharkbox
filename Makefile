# Sharkbox — build & install (CLI + GUI)
# Uses swiftc directly (no SwiftPM needed); `swift build -c release` also builds the CLI when SwiftPM is healthy.
PREFIX ?= /opt/homebrew
APPDIR ?= /Applications
BIN     = build/shark
APP     = build/Sharkbox.app
APP_STAMP = build/.app.stamp
ENTITLEMENTS = shark.entitlements
CLI_SOURCES  = $(wildcard Sources/shark/*.swift)
SHARED       = Sources/shark/Util.swift Sources/shark/Paths.swift Sources/shark/Machine.swift \
               Sources/shark/Distro.swift Sources/shark/Images.swift Sources/shark/SSH.swift
GUI_SOURCES  = $(wildcard Sources/SharkboxApp/*.swift)
TARGET       = arm64-apple-macos14.0
# SwiftUI's property wrappers are compiler macros on macOS 26+ SDKs; swiftc needs the SDK's plugin dir.
SDKROOT     := $(shell xcrun --show-sdk-path)
PLUGIN_DIRS := $(SDKROOT)/usr/lib/swift/host/plugins $(shell dirname $(shell xcrun -f swiftc))/../lib/swift/host/plugins
PLUGIN_FLAGS = $(foreach d,$(PLUGIN_DIRS),-plugin-path $(d))

.PHONY: all build app install uninstall clean run
.DELETE_ON_ERROR:

all: build app

# ---- CLI ----
build: $(BIN)

$(BIN): $(CLI_SOURCES) $(ENTITLEMENTS)
	mkdir -p build
	swiftc -O -target $(TARGET) -framework Virtualization -module-name shark $(CLI_SOURCES) -o $(BIN)
	codesign --force --sign - --entitlements $(ENTITLEMENTS) $(BIN)

# ---- GUI app ----
# The target is a stamp file, not the .app directory: make compares directory mtimes, so a bundle left
# half-built by a failed compile looks "up to date" and the next build silently does nothing.
app: $(APP_STAMP)

build/Sharkbox.icns: scripts/MakeIcon.swift
	mkdir -p build
	swiftc -O scripts/MakeIcon.swift -o build/makeicon
	rm -rf build/Sharkbox.iconset && build/makeicon build/Sharkbox.iconset
	iconutil -c icns build/Sharkbox.iconset -o build/Sharkbox.icns

$(APP_STAMP): $(BIN) $(GUI_SOURCES) $(SHARED) Resources/Info.plist build/Sharkbox.icns
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	swiftc -O -swift-version 5 -parse-as-library -target $(TARGET) $(PLUGIN_FLAGS) \
	    -framework SwiftUI -framework AppKit -framework ServiceManagement \
	    -module-name Sharkbox $(GUI_SOURCES) $(SHARED) -o $(APP)/Contents/MacOS/Sharkbox
	cp $(BIN) $(APP)/Contents/MacOS/shark
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	cp build/Sharkbox.icns $(APP)/Contents/Resources/Sharkbox.icns
	codesign --force --sign - --entitlements $(ENTITLEMENTS) $(APP)/Contents/MacOS/shark
	xattr -cr $(APP)          # codesign refuses a bundle carrying extended attributes
	codesign --force --sign - $(APP)
	touch $(APP_STAMP)

run: app
	open $(APP)

# ---- install ----
# Installing over a binary that is currently executing fails with ETXTBSY, which is easy to miss in a
# long build log — machines keep a `shark __runner` alive for their whole lifetime. Stage next to the
# target and rename over it instead: running processes keep the old inode, new ones get the new build.
install: build app
	install -d $(PREFIX)/bin
	install -m 755 $(BIN) $(PREFIX)/bin/.shark.new
	codesign --force --sign - --entitlements $(ENTITLEMENTS) $(PREFIX)/bin/.shark.new
	mv -f $(PREFIX)/bin/.shark.new $(PREFIX)/bin/shark
	rm -rf $(APPDIR)/.Sharkbox.new.app
	cp -R $(APP) $(APPDIR)/.Sharkbox.new.app
	rm -rf $(APPDIR)/Sharkbox.app
	mv -f $(APPDIR)/.Sharkbox.new.app $(APPDIR)/Sharkbox.app
	@echo "installed: $(PREFIX)/bin/shark and $(APPDIR)/Sharkbox.app"

uninstall:
	rm -f $(PREFIX)/bin/shark
	rm -rf $(APPDIR)/Sharkbox.app

clean:
	rm -rf build .build
