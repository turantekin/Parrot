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

# macOS keys Screen Recording and microphone grants to the app's *designated
# requirement*, not to its path or bundle ID. Signed with a real certificate
# that requirement is "bundle ID + this certificate", which survives rebuilds.
# Ad-hoc signing has no certificate, so it degrades to a cdhash of the binary —
# every rebuild is a different app to macOS, and every permission has to be
# granted again. Compare:
#
#   ad-hoc  designated => cdhash H"4666a893..."
#   signed  designated => identifier "com.uygar.parrot" and anchor apple generic
#                         and certificate leaf[subject.CN] = "Apple Development: ..."
#
# So: use whatever valid codesigning identity you already have, automatically.
# Most contributors with Xcode and an Apple ID have one and need to do nothing.
# We never create a certificate for you — see `make signing-help`.
#
# NB: no literal ")" anywhere in these $(shell ...) bodies — make balances
# parens itself, before the shell ever sees them, so a ")" inside even a quoted
# awk pattern ends the expression early and silently corrupts the value.
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | \
                          awk '$$2 ~ /^[0-9A-F]{40}$$/ { print $$2; exit }')

# Human-readable name of the same identity, for the status line.
SIGN_NAME := $(shell security find-identity -v -p codesigning 2>/dev/null | \
                       grep -m1 '"' | cut -d'"' -f2)

# Certs present but rejected as invalid — almost always expired. Worth calling
# out by name: an expired cert is skipped silently by every tool that filters on
# validity, so the symptom is "I have a certificate and permissions still reset",
# which is a genuinely confusing place to end up.
EXPIRED_IDS := $(shell security find-identity -p codesigning 2>/dev/null | \
                         grep -c CSSMERR_TP_CERT_EXPIRED)

ifeq ($(strip $(SIGN_IDENTITY)),)
SIGN_IDENTITY := -
endif

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
	@echo '  make signing-help   how to stop macOS permissions resetting every build'
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
	@$(MAKE) --no-print-directory signing-status

# Say which identity was used and, when that's ad-hoc, why it matters. Printed
# on every bundle so the ad-hoc case can never fail silently.
.PHONY: signing-status
signing-status:
ifeq ($(SIGN_IDENTITY),-)
	@echo
	@echo 'Signed ad-hoc — macOS permissions will reset on every rebuild.'
ifneq ($(EXPIRED_IDS),0)
	@echo
	@echo "  Found $(EXPIRED_IDS) code-signing certificate(s), but they are EXPIRED,"
	@echo '  which is why they were not used. Renew in Xcode:'
	@echo '    Settings > Accounts > (your team) > Manage Certificates > + > Apple Development'
else
	@echo '  No code-signing certificate found.'
endif
	@echo
	@echo '  Run `make signing-help` for how to fix this permanently.'
	@echo
else
	@echo
	@echo 'Signed with: $(SIGN_NAME)'
	@echo 'macOS permissions will persist across rebuilds.'
	@echo
endif

# Deliberately instructions, not automation: creating a certificate writes to
# your login keychain, and doing that as a side effect of `make run` would be a
# hostile surprise. You run these steps, or you don't.
.PHONY: signing-help
signing-help:
	@echo 'Making macOS permissions stick across rebuilds'
	@echo
	@echo 'Parrot needs Screen Recording (this is how macOS exposes system audio)'
	@echo 'and microphone access. macOS ties those grants to the signing identity,'
	@echo 'so without a stable one you re-grant them after every single build.'
	@echo
	@echo 'Either option below fixes that permanently. Pick one.'
	@echo
	@echo '1. Apple Development certificate — if you have Xcode and any Apple ID'
	@echo '   (a free one works; no paid membership needed):'
	@echo
	@echo '     Xcode > Settings > Accounts > add/select your Apple ID'
	@echo '            > select your team > Manage Certificates'
	@echo '            > + > Apple Development'
	@echo
	@echo '2. Self-signed certificate — no Apple account, no Xcode required.'
	@echo '   It never leaves your Mac and nobody else has to trust it; it only'
	@echo '   has to be the same certificate on your next rebuild:'
	@echo
	@echo '     Keychain Access > Certificate Assistant > Create a Certificate...'
	@echo '       Name:             Parrot Dev'
	@echo '       Identity Type:    Self Signed Root'
	@echo '       Certificate Type: Code Signing'
	@echo
	@echo 'Then just `make run` — the Makefile finds it on its own. Confirm with:'
	@echo
	@echo '    security find-identity -v -p codesigning'
	@echo
	@echo 'Already-granted permissions are bound to the old ad-hoc build, so clear'
	@echo 'them once after switching, then quit and relaunch Parrot:'
	@echo
	@echo '    tccutil reset ScreenCapture com.uygar.parrot'
	@echo '    tccutil reset Microphone com.uygar.parrot'
	@echo

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
