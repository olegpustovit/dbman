# DBMan — build, run, install.
#   make run        debug build, launch it (ad-hoc signed; passwords kept in a dev file, no Keychain prompts)
#   make install    release build signed with your code-signing identity → /Applications (or ~/Applications)
#   make test       unit + integration tests (integration needs: make db-up)
#   SIGN_IDENTITY="Apple Development: …" make install   to pick a specific identity

APP        := dist/DBMan.app
INSTALL_TO := $(shell [ -w /Applications ] && echo /Applications || echo $(HOME)/Applications)
# First valid code-signing identity, preferring Developer ID, then Apple Development.
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | grep -E '"Developer ID Application|"Apple Development' | head -1 | sed -E 's/.*"(.*)"/\1/')

.PHONY: build run install uninstall test check-signing db-up db-down clean

build:
	scripts/bundle.sh debug

run: build
	open -n $(APP)

check-signing:
	@if [ -z "$(SIGN_IDENTITY)" ]; then \
	  echo "error: no code-signing identity found."; \
	  echo "  A stable signature lets macOS remember your Keychain 'Always Allow' between installs."; \
	  echo "  Create one in Xcode › Settings › Accounts › Manage Certificates (+ Apple Development),"; \
	  echo "  or pass one explicitly: SIGN_IDENTITY=\"Apple Development: you@example.com (TEAMID)\" make install"; \
	  echo "  Available identities:"; security find-identity -v -p codesigning | sed 's/^/    /'; \
	  exit 1; \
	fi
	@echo "Signing with: $(SIGN_IDENTITY)"

install: check-signing
	SIGN_IDENTITY="$(SIGN_IDENTITY)" scripts/bundle.sh release
	mkdir -p "$(INSTALL_TO)"
	rm -rf "$(INSTALL_TO)/DBMan.app"
	cp -R $(APP) "$(INSTALL_TO)/DBMan.app"
	codesign --verify --strict "$(INSTALL_TO)/DBMan.app"
	@echo "Installed $(INSTALL_TO)/DBMan.app — open it from Launchpad or: open \"$(INSTALL_TO)/DBMan.app\""

uninstall:
	rm -rf "$(INSTALL_TO)/DBMan.app"

test:
	swift test

db-up:
	testdb/up.sh

db-down:
	testdb/down.sh

clean:
	rm -rf .build dist
