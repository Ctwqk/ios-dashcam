# DashCam

iOS DashCam application built with SwiftUI and AVFoundation.

## Features

- Real-time camera preview
- Continuous video recording with loop buffer
- Collision detection
- Speed tracking
- Auto-restart service
- Local storage management

## Requirements

- iOS 17.0+
- Xcode 15.0+

## Installation

1. Clone the repository
2. Open `dashcam/DashCam.xcodeproj` in Xcode
3. Build and run on your device

## Project Structure

```
dashcam/
└── dashcam/
    └── DashCam/
        ├── Sources/
        │   ├── Camera/         # Camera management
        │   ├── Detection/      # Collision detection
        │   ├── Models/         # Data models
        │   ├── Recording/     # Video recording
        │   ├── Services/      # App services
        │   ├── Storage/       # Storage management
        │   └── Views/         # SwiftUI views
        └── Assets.xcassets/   # App assets
```
