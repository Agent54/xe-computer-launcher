# Load .env file if it exists
-include .env
export

APP_NAME = XE Launcher
BUNDLE_ID = dev.xe.computer
BUILD_DIR = .build
BUILD_CONFIG ?= release
SWIFT_BUILD_FLAGS ?=
SPARKLE_PUBLIC_ED_KEY ?=
DIST_DIR = dist
APP_BUNDLE = $(DIST_DIR)/$(APP_NAME).app
CONTENTS = $(APP_BUNDLE)/Contents
MACOS_DIR = $(CONTENTS)/MacOS
RESOURCES = $(CONTENTS)/Resources
FRAMEWORKS = $(CONTENTS)/Frameworks
SPARKLE_FRAMEWORK = $(FRAMEWORKS)/Sparkle.framework
BUILT_SPARKLE_FRAMEWORK = $(BUILD_DIR)/$(BUILD_CONFIG)/Sparkle.framework
DMG_NAME = $(APP_NAME).dmg
ENTITLEMENTS = Sources/macos/Entitlements.plist

# Set in .env or pass on the command line
# DEVELOPER_ID ?=
# APPLE_ID ?=
# TEAM_ID ?=
NOTARY_PROFILE ?= notarytool-profile
NOTARY_KEYCHAIN_ARG = $(if $(strip $(NOTARY_KEYCHAIN)),--keychain "$(NOTARY_KEYCHAIN)",)

.PHONY: all clean build package sign-sparkle bundle run release release-sign check notarize dmg dev-dmg verify-sparkle

all: release

zip-helpers:
	@echo "Zipping helpers..."
	@ditto -c -k --keepParent $(BUILD_DIR)/Helium.zip Sources/macos/helpers/Helium.app

build:
	swift build -c $(BUILD_CONFIG) $(SWIFT_BUILD_FLAGS)

package: build
	@echo "Creating app package..."
	@mkdir -p "$(MACOS_DIR)"
	@mkdir -p "$(RESOURCES)"
	@mkdir -p "$(FRAMEWORKS)"
	@cp "$(BUILD_DIR)/$(BUILD_CONFIG)/macos" "$(MACOS_DIR)/bin"
	@cp Sources/macos/Info.plist "$(CONTENTS)/Info.plist"
	@if [ -n "$(SPARKLE_PUBLIC_ED_KEY)" ]; then \
		plutil -replace SUPublicEDKey -string "$(SPARKLE_PUBLIC_ED_KEY)" "$(CONTENTS)/Info.plist"; \
	fi
	@echo 'APPL????' > "$(CONTENTS)/PkgInfo"
	@rsync -a Sources/macos/Resources/ "$(RESOURCES)/"
	@rsync -a --delete Sources/macos/sandbox/ "$(RESOURCES)/sandbox/"
	@rsync -a --delete "$(BUILT_SPARKLE_FRAMEWORK)/" "$(SPARKLE_FRAMEWORK)/"
	@echo "App package created at $(APP_BUNDLE)"

# Sparkle contains several nested signed executables. Sign from the innermost
# XPC services and helpers outward; using codesign --deep here would overwrite
# the Downloader service's required entitlements.
SIGN_IDENTITY ?= -
CODESIGN_TIMESTAMP = $(if $(filter-out -,$(SIGN_IDENTITY)),--timestamp,)

sign-sparkle:
	@echo "Signing Sparkle framework with: $(SIGN_IDENTITY)"
	@codesign --force --options runtime $(CODESIGN_TIMESTAMP) \
		--sign "$(SIGN_IDENTITY)" \
		"$(SPARKLE_FRAMEWORK)/Versions/B/XPCServices/Installer.xpc"
	@codesign --force --options runtime $(CODESIGN_TIMESTAMP) \
		--preserve-metadata=entitlements \
		--sign "$(SIGN_IDENTITY)" \
		"$(SPARKLE_FRAMEWORK)/Versions/B/XPCServices/Downloader.xpc"
	@codesign --force --options runtime $(CODESIGN_TIMESTAMP) \
		--sign "$(SIGN_IDENTITY)" \
		"$(SPARKLE_FRAMEWORK)/Versions/B/Autoupdate"
	@codesign --force --options runtime $(CODESIGN_TIMESTAMP) \
		--sign "$(SIGN_IDENTITY)" \
		"$(SPARKLE_FRAMEWORK)/Versions/B/Updater.app"
	@codesign --force --options runtime $(CODESIGN_TIMESTAMP) \
		--sign "$(SIGN_IDENTITY)" \
		"$(SPARKLE_FRAMEWORK)"

bundle: package
	@echo "Creating app bundle..."
	@$(MAKE) SIGN_IDENTITY=- sign-sparkle
	@echo "Signing app bundle (ad-hoc)..."
	@codesign --force --options runtime --entitlements "$(ENTITLEMENTS)" --sign - "$(APP_BUNDLE)"
	@echo "App bundle created at $(APP_BUNDLE)"

run: bundle
	@open "$(APP_BUNDLE)"

# Release build with Developer ID signing
release-sign: BUILD_CONFIG=release
release-sign: package
	@echo "Creating signed app bundle for distribution..."
	@public_key="$$(plutil -extract SUPublicEDKey raw "$(CONTENTS)/Info.plist")"; \
		if [ -z "$$public_key" ] || [ "$$public_key" = "SPARKLE_PUBLIC_ED_KEY" ]; then \
			echo "ERROR: Set SPARKLE_PUBLIC_ED_KEY before creating a release build." >&2; \
			exit 1; \
		fi
	@$(MAKE) SIGN_IDENTITY="$(DEVELOPER_ID)" sign-sparkle
	@echo "Signing with Developer ID: $(DEVELOPER_ID)"
	@codesign --force --options runtime --timestamp --entitlements "$(ENTITLEMENTS)" --sign "$(DEVELOPER_ID)" "$(APP_BUNDLE)"
	@echo "Verifying signature..."
	@codesign --verify --verbose "$(APP_BUNDLE)"

	@echo "Checking Gatekeeper (requires Developer ID cert for distribution)..."
	-@spctl --assess --verbose --type execute "$(APP_BUNDLE)"
	@echo "Signed app bundle created at $(APP_BUNDLE)"

verify-sparkle:
	@Tests/Integration/verify-sparkle.sh "$(APP_BUNDLE)"

# Pre-notarization checks (catches issues locally before slow upload)
check: release-sign
	@Tests/Integration/verify-sparkle.sh "$(APP_BUNDLE)" --release

	@echo "Deep strict signature verification..."
	@codesign --verify --deep --strict --verbose=2 "$(APP_BUNDLE)"

	@echo "Checking hardened runtime on all executables..."
	@fail=0; find "$(APP_BUNDLE)" -type f -perm +111 | while read f; do \
		if file "$$f" | grep -q 'Mach-O'; then \
			if ! codesign -dvv "$$f" 2>&1 | grep -q 'flags=.*runtime'; then \
				echo "ERROR: no hardened runtime: $$f"; \
				exit 1; \
			fi; \
		fi; \
	done

	# @echo "Gatekeeper assessment..."
	# @spctl --assess --verbose --type execute $(APP_BUNDLE)
	# @echo "All pre-notarization checks passed!"


# Notarize the app bundle (requires check first)
notarize: check
	@echo "Creating ZIP for notarization..."
	@ditto -c -k --keepParent "$(APP_BUNDLE)" "$(BUILD_DIR)/$(APP_NAME)-notarize.zip"
	@echo "Submitting to Apple for notarization..."
	@xcrun notarytool submit "$(BUILD_DIR)/$(APP_NAME)-notarize.zip" \
		--keychain-profile "$(NOTARY_PROFILE)" $(NOTARY_KEYCHAIN_ARG) \
		--wait
	@echo "Stapling notarization ticket..."
	@xcrun stapler staple "$(APP_BUNDLE)"
	@rm "$(BUILD_DIR)/$(APP_NAME)-notarize.zip"
	@echo "Notarization complete!"

# Create DMG for distribution (after notarization)
dmg: notarize
	@echo "Creating DMG..."
	@mkdir -p "$(DIST_DIR)"
	@rm -f "$(DIST_DIR)/$(DMG_NAME)"
	@create-dmg \
		--volname "$(APP_NAME)" \
		--window-pos 510 370 \
		--window-size 380 340 \
		--icon-size 100 \
		--icon "$(APP_NAME).app" 180 140 \
		--hide-extension "$(APP_NAME).app" \
		--codesign "$(DEVELOPER_ID)" \
		"$(DIST_DIR)/$(DMG_NAME)" \
		"$(APP_BUNDLE)"
	@echo "DMG created at $(DIST_DIR)/$(DMG_NAME)"

# Development DMG: debug build, ad-hoc app signature, no Developer ID or
# notarization. It intentionally uses the same create-dmg layout as releases.
dev-dmg:
	@command -v create-dmg >/dev/null 2>&1 || { \
		echo "ERROR: create-dmg is required (install it with: brew install create-dmg)" >&2; \
		exit 1; \
	}
	@$(MAKE) BUILD_CONFIG=debug bundle
	@echo "Creating development DMG..."
	@mkdir -p "$(DIST_DIR)"
	@rm -f "$(DIST_DIR)/$(DMG_NAME)"
	@create-dmg \
		--volname "$(APP_NAME)" \
		--window-pos 510 370 \
		--window-size 380 340 \
		--icon-size 100 \
		--icon "$(APP_NAME).app" 180 140 \
		--hide-extension "$(APP_NAME).app" \
		"$(DIST_DIR)/$(DMG_NAME)" \
		"$(APP_BUNDLE)"
	@echo "Development DMG created at $(DIST_DIR)/$(DMG_NAME)"

# Full release: sign, notarize, create DMG
release: dmg
	@echo "Release build complete!"
	@echo "  App: $(APP_BUNDLE)"
	@echo "  DMG: $(DIST_DIR)/$(DMG_NAME)"

clean:
	swift package clean
	rm -rf "$(APP_BUNDLE)"
	rm -f "$(DIST_DIR)/$(DMG_NAME)"
