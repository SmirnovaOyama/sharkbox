# OrbShark — build & install (CLI + GUI)
# Uses swiftc directly (no SwiftPM needed); `swift build -c release` also builds the CLI when SwiftPM is healthy.
PREFIX ?= /opt/homebrew
APPDIR ?= /Applications
BIN     = build/shark
APP     = build/OrbShark.app
ENTITLEMENTS = shark.entitlements
CLI_SOURCES  = $(wildcard Sources/shark/*.swift)
SHARED       = Sources/shark/Util.swift Sources/shark/Paths.swift Sources/shark/Machine.swift \
               Sources/shark/Distro.swift Sources/shark/Images.swift Sources/shark/SSH.swift
GUI_SOURCES  = $(wildcard Sources/OrbSharkApp/*.swift)
TARGET       = arm64-apple-macos14.0
# SwiftUI's property wrappers are compiler macros on macOS 26+ SDKs; swiftc needs the SDK's plugin dir.
SDKROOT     := $(shell xcrun --show-sdk-path)
PLUGIN_DIRS := $(SDKROOT)/usr/lib/swift/host/plugins $(shell dirname $(shell xcrun -f swiftc))/../lib/swift/host/plugins
PLUGIN_FLAGS = $(foreach d,$(PLUGIN_DIRS),-plugin-path $(d))

.PHONY: all build app install uninstall clean run

all: build app

# ---- CLI ----
build: $(BIN)

$(BIN): $(CLI_SOURCES) $(ENTITLEMENTS)
	mkdir -p build
	swiftc -O -target $(TARGET) -framework Virtualization -module-name shark $(CLI_SOURCES) -o $(BIN)
	codesign --force --sign - --entitlements $(ENTITLEMENTS) $(BIN)

# ---- GUI app ----
app: $(APP)

build/OrbShark.icns: scripts/MakeIcon.swift
	mkdir -p build
	swiftc -O scripts/MakeIcon.swift -o build/makeicon
	rm -rf build/OrbShark.iconset && build/makeicon build/OrbShark.iconset
	iconutil -c icns build/OrbShark.iconset -o build/OrbShark.icns

$(APP): $(BIN) $(GUI_SOURCES) $(SHARED) Resources/Info.plist build/OrbShark.icns
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	swiftc -O -swift-version 5 -parse-as-library -target $(TARGET) $(PLUGIN_FLAGS) \
	    -framework SwiftUI -framework AppKit -framework ServiceManagement \
	    -module-name OrbShark $(GUI_SOURCES) $(SHARED) -o $(APP)/Contents/MacOS/OrbShark
	cp $(BIN) $(APP)/Contents/MacOS/shark
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	cp build/OrbShark.icns $(APP)/Contents/Resources/OrbShark.icns
	codesign --force --sign - --entitlements $(ENTITLEMENTS) $(APP)/Contents/MacOS/shark
	codesign --force --sign - $(APP)

run: app
	open $(APP)

# ---- install ----
install: build app
	install -d $(PREFIX)/bin
	install -m 755 $(BIN) $(PREFIX)/bin/shark
	codesign --force --sign - --entitlements $(ENTITLEMENTS) $(PREFIX)/bin/shark
	rm -rf $(APPDIR)/OrbShark.app
	cp -R $(APP) $(APPDIR)/OrbShark.app
	@echo "installed: $(PREFIX)/bin/shark and $(APPDIR)/OrbShark.app"

uninstall:
	rm -f $(PREFIX)/bin/shark
	rm -rf $(APPDIR)/OrbShark.app

clean:
	rm -rf build .build
