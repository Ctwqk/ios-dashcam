# Convenience targets; CI runs the same commands (see .github/workflows/ci.yml).
# The app/iOS targets need macOS with Xcode 16 or newer.

PROJECT  := dashcam/DashCam.xcodeproj
SCHEME   := DashCam
CORE_DIR := dashcam/DashCamCore
DERIVED  := build/DerivedData

.PHONY: test-core test-core-ios test-app-ios build lint screenshots

## Unit tests of the pure logic (macOS host, no simulator needed)
test-core:
	cd $(CORE_DIR) && swift test --jobs 4

## The same unit tests, run inside an iOS simulator
test-core-ios:
	cd $(CORE_DIR) && xcodebuild test -scheme DashCamCore -jobs 4 \
		-destination "platform=iOS Simulator,id=$$(../../scripts/sim-udid.sh)"

## App adapters: synthetic video writing/merging and interruption notifications
test-app-ios:
	xcodebuild test -project $(PROJECT) -scheme DashCamIOTests -jobs 4 -parallel-testing-enabled NO \
		-destination "platform=iOS Simulator,id=$$(scripts/sim-udid.sh)" \
		-derivedDataPath $(DERIVED) CODE_SIGNING_ALLOWED=NO

## Build the app for the iOS Simulator (no code signing)
build:
	xcodebuild build -project $(PROJECT) -scheme $(SCHEME) -jobs 4 \
		-destination 'generic/platform=iOS Simulator' \
		-derivedDataPath $(DERIVED) CODE_SIGNING_ALLOWED=NO

lint:
	swiftlint lint

## Launch the built app in a simulator and save screenshots to build/screenshots
screenshots: build
	scripts/capture-screenshots.sh $(DERIVED) build/screenshots
