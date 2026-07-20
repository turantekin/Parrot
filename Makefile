# Parrot — build and run from source without Xcode's UI.
#
# Uses `swift build` plus manual .app assembly, the same path scripts/release.sh
# takes: Xcode's explicit-modules build races on WhisperKit's transitive deps
# (see docs/IMPROVEMENT-ROADMAP.md, "Build notes"), while swift build is reliable.
#
# Run `make` (or `make help`) for the target list.

CONFIG      ?= release
DIST        ?= dist
APP         := $(DIST)/Parrot.app
PLIST       := $(APP)/Contents/Info.plist
BINDIR      := .build/$(CONFIG)
VERSION     ?= 0.0.0-dev
BUILD_NUM   := $(shell date +%Y%m%d%H%M)

# Ad-hoc by default so a fresh clone builds with no Apple developer account.
# macOS keys Screen Recording / microphone grants to the signing identity, and
# ad-hoc re-signs with a new hash on every build — so you re-grant permissions
# after each rebuild. To keep grants sticky, sign with your own identity:
#   make run SIGN_IDENTITY="Apple Development: you@example.com (TEAMID)"
# List candidates with: security find-identity -v -p codesigning
SIGN_IDENTITY ?= -

.DEFAULT_GOAL := app

.PHONY: help
help:
	@echo 'Parrot — make targets'
	@echo
	@echo '  make           build + assemble $(APP) (the default)'
	@echo '  make build     compile the executable only (swift build -c $(CONFIG))'
	@echo '  make app       assemble + sign $(APP)'
	@echo '  make run       build, assemble, and launch Parrot'
	@echo '  make install   copy the built app into /Applications'
	@echo '  make test      run the bundled logic harness (--profile-test)'
	@echo '  make xcode     regenerate Parrot.xcodeproj from project.yml (needs xcodegen)'
	@echo '  make clean     remove .build/ and $(DIST)/'
	@echo
	@echo 'Vars: CONFIG=$(CONFIG) VERSION=$(VERSION) SIGN_IDENTITY=$(SIGN_IDENTITY)'

# Printed after a successful `make app` — the whole point of the default target
# is that it tells you what to open next.
.PHONY: howto
howto:
	@echo
	@echo 'Built $(APP)'
	@echo
	@echo 'Start it with either:'
	@echo
	@echo '    open $(APP)'
	@echo '    make run'
	@echo
	@echo 'First launch walks you through two macOS permissions:'
	@echo '  1. Screen Recording  — how macOS exposes system audio (audio only, never screen content)'
	@echo '  2. Microphone        — your side of the call'
	@echo 'Screen Recording only takes effect after a restart: quit and reopen if the row stays red.'
	@echo
	@echo 'Then pick a WhisperKit model in onboarding (`base` is a good default; it downloads on'
	@echo 'first use). Everything runs on-device — cloud engines and the Copilot are opt-in and'
	@echo 'need your own API keys, set in Settings.'
	@echo
	@echo 'Run `make help` for other targets.'

.PHONY: build
build:
	swift build -c $(CONFIG)

# Mirrors scripts/release.sh's assembly. Info.plist is xcodegen-managed and
# still holds $$(VAR) placeholders that Xcode would substitute — do it here.
.PHONY: app
app: bundle
	@$(MAKE) --no-print-directory howto

.PHONY: bundle
bundle: build
	@rm -rf $(DIST)
	@mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BINDIR)/Parrot $(APP)/Contents/MacOS/Parrot
	@printf 'APPL????' > $(APP)/Contents/PkgInfo
	@cp Parrot/Info.plist $(PLIST)
	@plutil -replace CFBundleExecutable         -string Parrot           $(PLIST)
	@plutil -replace CFBundleIdentifier         -string com.uygar.parrot $(PLIST)
	@plutil -replace CFBundleName               -string Parrot           $(PLIST)
	@plutil -replace CFBundleDevelopmentRegion  -string en               $(PLIST)
	@plutil -replace CFBundleShortVersionString -string "$(VERSION)"     $(PLIST)
	@plutil -replace CFBundleVersion            -string "$(BUILD_NUM)"   $(PLIST)
	@plutil -replace LSMinimumSystemVersion     -string "14.0"           $(PLIST)
	@# SwiftPM resource bundles + the UI fonts (Info.plist sets ATSApplicationFontsPath ".")
	cp -R $(BINDIR)/*.bundle $(APP)/Contents/Resources/
	cp Parrot/Fonts/*.otf $(APP)/Contents/Resources/
	@# swift build can't compile asset catalogs, so the icon goes through actool.
	xcrun actool Parrot/Assets.xcassets \
		--compile $(APP)/Contents/Resources \
		--platform macosx --minimum-deployment-target 14.0 \
		--app-icon AppIcon \
		--output-partial-info-plist $(DIST)/actool.plist > /dev/null
	@rm -f $(DIST)/actool.plist
	@[ -f $(APP)/Contents/Resources/AppIcon.icns ] && \
		plutil -replace CFBundleIconFile -string AppIcon $(PLIST) || true
	codesign --force --options runtime --timestamp=none \
		--entitlements Parrot/Parrot.entitlements \
		--sign "$(SIGN_IDENTITY)" $(APP)

.PHONY: run
run: bundle
	open $(APP)

.PHONY: install
install: bundle
	rm -rf /Applications/Parrot.app
	cp -R $(APP) /Applications/
	@echo "Installed /Applications/Parrot.app — start it from Spotlight or 'open -a Parrot'"

# ParrotApp.swift exposes CLI harness flags; --profile-test is the ~60-check
# logic harness that runs headless.
.PHONY: test
test: build
	$(BINDIR)/Parrot --profile-test

.PHONY: xcode
xcode:
	@command -v xcodegen >/dev/null 2>&1 || { \
		echo "xcodegen not installed. Install it with: brew install xcodegen"; exit 1; }
	xcodegen generate
	@echo "Regenerated Parrot.xcodeproj — open it with: open Parrot.xcodeproj"

.PHONY: clean
clean:
	rm -rf .build $(DIST)
