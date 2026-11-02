# VPN Widget — SwiftPM build, .app bundle, release and cask.
#
# Building needs Xcode, not only the Command Line Tools: the SwiftUI macros
# and the Swift Testing plugin ship with Xcode. When xcode-select points at the
# Command Line Tools, every swift command here runs with DEVELOPER_DIR set to
# Xcode (override XCODE_DEV if it lives elsewhere).

NAME        := VPN Widget
BUNDLE_ID   := com.ya-makariy.vpn-widget
EXECUTABLE  := VPNWidget
VERSION     ?= $(shell v=$$(git describe --tags --always --dirty 2>/dev/null); echo "$${v:-0.0.0}" | sed 's/^v//')
BUILD       ?= $(shell git rev-list --count HEAD 2>/dev/null || echo 1)
CONFIG      ?= release
DIST        := dist
APP         := $(DIST)/$(NAME).app
ZIP         := $(DIST)/VPN-Widget-$(VERSION).zip
TAP_DIR     ?= ../homebrew-tap
XCODE_DEV   ?= /Applications/Xcode.app/Contents/Developer
DEV_DIR     := $(shell xcode-select -p 2>/dev/null)
ifeq ($(findstring Xcode.app,$(DEV_DIR)),)
  ifneq ($(wildcard $(XCODE_DEV)),)
    export DEVELOPER_DIR := $(XCODE_DEV)
  endif
endif
SWIFT       := swift

.PHONY: build test app run once install uninstall release cask clean

build:
	$(SWIFT) build -c $(CONFIG) --product $(EXECUTABLE)
	$(SWIFT) build -c $(CONFIG) --product vpn-tunnel
	$(SWIFT) build -c $(CONFIG) --product vpnw

test:
	$(SWIFT) test

$(DIST)/AppIcon.icns: scripts/make-icon.swift
	mkdir -p $(DIST)/AppIcon.iconset
	$(SWIFT) scripts/make-icon.swift $(DIST)/AppIcon.iconset
	iconutil -c icns $(DIST)/AppIcon.iconset -o $@

icon: $(DIST)/AppIcon.icns

app: build $(DIST)/AppIcon.icns
	scripts/make-app.sh "$(APP)" "$$($(SWIFT) build -c $(CONFIG) --show-bin-path)/$(EXECUTABLE)" "$(DIST)/AppIcon.icns" "$(BUNDLE_ID)" "$(VERSION)" "$(BUILD)" "$$($(SWIFT) build -c $(CONFIG) --show-bin-path)/vpn-tunnel"

run: app
	open "$(APP)"

once:
	$(SWIFT) run vpnw once

install: app
	rm -rf "/Applications/$(NAME).app"
	ditto "$(APP)" "/Applications/$(NAME).app"
	@echo "Installed /Applications/$(NAME).app"

uninstall:
	rm -rf "/Applications/$(NAME).app"

release: app
	rm -f "$(ZIP)"
	ditto -c -k --keepParent "$(APP)" "$(ZIP)"
	shasum -a 256 "$(ZIP)" | tee "$(ZIP).sha256"
	gh release create "v$(VERSION)" "$(ZIP)" "$(ZIP).sha256" --generate-notes

cask:
	@test -f "$(ZIP).sha256" || { echo "run make release first"; exit 1; }
	scripts/cask.sh "$(VERSION)" "$$(cut -d' ' -f1 '$(ZIP).sha256')" "$(TAP_DIR)/Casks/vpn-widget.rb"

clean:
	rm -rf .build $(DIST)
