.PHONY: build test app run install update quit-sr clean

build:
	swift build

# CLT-only toolchain: Swift Testing framework lives outside the default
# search path (and XCTest is absent entirely — tests use Swift Testing).
TESTING_FW := /Library/Developer/CommandLineTools/Library/Developer/Frameworks
DEVELOPER_DIR := $(shell xcode-select -p 2>/dev/null)
ifeq ($(DEVELOPER_DIR),/Library/Developer/CommandLineTools)
ifneq ($(wildcard $(TESTING_FW)/Testing.framework),)
SWIFT_TEST_FLAGS := -Xswiftc -F$(TESTING_FW) \
	-Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
	-Xlinker -F$(TESTING_FW) -Xlinker -rpath -Xlinker $(TESTING_FW)
endif
endif

# -disable-cross-import-overlays lets test files import Foundation alongside
# Testing (the _Testing_Foundation overlay module is not resolvable under CLT).
test:
	swift test $(SWIFT_TEST_FLAGS)
	python3 -m unittest discover -s Tests/DaemonTests -p 'test_*.py'

app:
	bash scripts/build-app.sh release

run: app
	open dist/sr.app

# First install (and the clean-slate repair if a bundle ever gets confused):
# replaces /Applications/sr.app outright. The Accessibility grant follows the
# signing identity (bundle id + sr-dev cert), not the path, so it survives this.
# For routine updates prefer `make update`.
install: app
	@$(MAKE) --no-print-directory quit-sr
	rm -rf /Applications/sr.app
	cp -R dist/sr.app /Applications/sr.app
	open /Applications/sr.app

# Everyday "get the latest" command: pull, rebuild, swap the bundle, relaunch.
#
# It is gentler than `install` in two ways that matter. It quits sr through the
# app instead of signalling it, so applicationShouldTerminate actually runs —
# pending ElevenLabs history deletions get persisted and the local daemon is
# stopped, rather than killed mid-flight. And it syncs the bundle in place
# instead of deleting and recopying it, so unchanged files keep their inodes
# and extended attributes.
#
# Neither command can reset your preferences: voices, models, hotkeys, speed,
# budget and backend mode live in UserDefaults (com.patrickellis.sr), the API
# key lives in the login Keychain, and the audio cache and local voice live in
# ~/Library/Application Support/sr. None of those are inside sr.app.
update:
	git pull --ff-only
	@$(MAKE) --no-print-directory app
	@$(MAKE) --no-print-directory quit-sr
	@rsync -a --delete dist/sr.app/ /Applications/sr.app/
	@open /Applications/sr.app
	@security find-identity -v -p codesigning 2>/dev/null | grep -q '"sr-dev"' || \
	  printf 'note: no "sr-dev" signing certificate. Every rebuild then has a different\n      identity, so macOS treats it as a new app and re-prompts for Keychain\n      and Accessibility access. Creating the cert once stops that for good —\n      see README > Development.\n' >&2
	@echo "sr updated and relaunched. Preferences, API key and cache untouched."

# Quit a running sr the way the Quit menu item does, so shutdown work happens.
# Falls back to a kill if it has not exited in ~5s. The bracketed dot keeps the
# pattern from matching the shell that is running the pattern.
quit-sr:
	@osascript -e 'quit app "sr"' >/dev/null 2>&1 || true
	@n=0; \
	while pgrep -f 'sr[.]app/Contents/MacOS/sr' >/dev/null 2>&1 && [ $$n -lt 50 ]; do \
		sleep 0.1; n=$$((n + 1)); \
	done; \
	pkill -f 'sr[.]app/Contents/MacOS/sr' >/dev/null 2>&1 || true

clean:
	rm -rf .build dist
