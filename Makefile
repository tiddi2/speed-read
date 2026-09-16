.PHONY: build test app run install update setup-signing reset-permissions \
        signing-status quit-sr clean pin-f5-model check-offline

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

# What is wrong with the offline voice, in full. The daemon reports an
# unexpected exception by class name alone (its message could quote the text
# being read), which leaves "RuntimeError" standing for a missing checkpoint,
# a Metal allocation failure and an unreadable recording alike. This runs the
# same stack in the foreground on a sentence of its own, so it can print the
# exception, its traceback and the file sizes behind it. Uses the installed
# venv, so it needs no rebuild.
VENV_PYTHON := $(HOME)/Library/Application Support/sr/kokoro/venv/bin/python3
check-offline:
	@test -x "$(VENV_PYTHON)" || { \
	  printf 'No offline voice installed: %s is missing.\n' "$(VENV_PYTHON)" >&2; \
	  exit 1; }
	@"$(VENV_PYTHON)" daemon/sr_tts_server.py --self-test $(VOICE)


run: app
	open dist/sr.app

# First install (and the clean-slate repair if a bundle ever gets confused):
# replaces /Applications/sr.app outright. The Accessibility grant follows the
# signing identity (bundle id + sr-dev cert), not the path, so it survives this.
# For routine updates prefer `make update`.
install: app
	@$(MAKE) --no-print-directory setup-signing || \
	  printf 'note: continuing with ad-hoc signing — see the message above.\n' >&2
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
# key lives in the login Keychain, and the audio cache, the offline models and
# your Norwegian reference recordings live in ~/Library/Application Support/sr.
# None of those are inside sr.app.
update:
	git pull --ff-only
	@$(MAKE) --no-print-directory setup-signing || \
	  printf 'note: continuing with ad-hoc signing — see the message above.\n' >&2
	@$(MAKE) --no-print-directory app
	@$(MAKE) --no-print-directory quit-sr
	@prev="$$(codesign -d -r- /Applications/sr.app 2>/dev/null | sed -n 's/^designated => //p')"; \
	 new="$$(codesign -d -r- dist/sr.app 2>/dev/null | sed -n 's/^designated => //p')"; \
	 rsync -a --delete dist/sr.app/ /Applications/sr.app/; \
	 open /Applications/sr.app; \
	 if [ -n "$$prev" ] && [ "$$new" != "$$prev" ]; then \
	   printf 'note: this build'"'"'s code identity differs from the installed one, so\n      macOS will ask for Accessibility (and the Keychain) once more.\n      It is stable from the next update on.\n' >&2; \
	 fi
	@echo "sr updated and relaunched. Preferences, API key and cache untouched."

# Creates the local "sr-dev" code-signing identity the first time, then does
# nothing on later runs. This is what keeps macOS from treating each rebuild as
# a new app — see README > Development. `make app` runs it too.
#
# `install` and `update` call it but do not stop when it fails. The script
# already says a failure means "builds stay ad-hoc signed", and the only cost
# of that is re-approving Accessibility after each update — aborting the whole
# update over it contradicts the message and leaves no way to build at all.
# Run this target on its own to see a failure as an error.
setup-signing:
	@bash scripts/setup-signing.sh

# Print the Swift pins for the Norwegian model you have installed, so a
# community fine-tune with no stable revision can be frozen to one commit.
# See scripts/pin-f5-model.sh.
pin-f5-model:
	@bash scripts/pin-f5-model.sh

# Prove the identity works, and say where its key lives.
signing-status:
	@bash scripts/setup-signing.sh --check

# Clear sr's stale Accessibility grants in one go — the list can hold one dead
# entry per ad-hoc build ever installed, and a stale entry can look enabled
# while granting nothing. Run once after `make setup-signing`, approve sr when
# it asks, and that grant then survives every update.
reset-permissions:
	@$(MAKE) --no-print-directory quit-sr
	@tccutil reset Accessibility com.patrickellis.sr >/dev/null 2>&1 || true
	@echo "Cleared sr's Accessibility entries. Remove any leftover 'sr' rows in"
	@echo "System Settings > Privacy & Security > Accessibility, then relaunch sr"
	@echo "and approve once."
	@open /Applications/sr.app 2>/dev/null || true

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
