# Convenience targets; CI runs the same commands (see .github/workflows/ci.yml).
# The app/iOS targets need macOS with Xcode 15 or newer.

PROJECT  := dashcam/DashCam.xcodeproj
SCHEME   := DashCam
CORE_DIR := dashcam/DashCamCore
DERIVED  := build/DerivedData

.PHONY: test-core test-core-ios build lint screenshots

## Unit tests of the pure logic (macOS host, no simulator needed)
test-core:
	cd $(CORE_DIR) && swift test

## The same unit tests, run inside an iOS simulator
test-core-ios:
	cd $(CORE_DIR) && xcodebuild test -scheme DashCamCore \
		-destination "platform=iOS Simulator,id=$$(../../scripts/sim-udid.sh)"

## Build the app for the iOS Simulator (no code signing)
build:
	xcodebuild build -project $(PROJECT) -scheme $(SCHEME) \
		-destination 'generic/platform=iOS Simulator' \
		-derivedDataPath $(DERIVED) CODE_SIGNING_ALLOWED=NO

lint:
	swiftlint lint

## Launch the built app in a simulator and save screenshots to build/screenshots
screenshots: build
	scripts/capture-screenshots.sh $(DERIVED) build/screenshots
