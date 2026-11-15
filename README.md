# DriveAssistant

**DriveAssistant** is a native iOS Advanced Driver-Assistance System (ADAS) built with **Swift** and **SwiftUI**. Using on-device computer vision (`CoreML` + `Vision`) and GPS telemetry (`CoreLocation`), it estimates the real-time distance to the lead vehicle ahead and alerts the driver when following distances drop below safe thresholds.

---

## Key Features

- **On-Device Vehicle Detection:** Runs Apple's quantized `YOLOv3TinyInt8LUT` CoreML model locally on the Neural Engine to detect `car`, `truck`, `bus`, and `motorbike` classes with zero cloud latency.
- **Forward-Lane ROI Filtering:** Projects a configurable trapezoid Region of Interest (ROI) onto the live landscape camera feed to ignore parked cars and oncoming traffic in adjacent lanes.
- **Monocular Distance & TTC Estimation:** Calculates real-world distance in meters using class-specific vehicle widths and camera focal-length calibration, smoothed via an Exponential Moving Average (EMA) filter alongside Time-To-Collision (TTC) tracking.
- **Vietnam Traffic Law Compliance (TT38/2024/TT-BGTVT):**
  - Supports official speed-tiered minimum following distances (`35m` at 60 km/h, `55m` for 60–80 km/h, `70m` for 80–100 km/h, `100m` for >100 km/h) alongside a customizable Time-Headway (seconds) mode.
  - Automatically adjusts safe distance multipliers (`1.0x` Dry / `1.3x` Wet) using live GPS weather data from Open-Meteo, with one-tap manual override on the HUD.
- **Smart Non-Intrusive Alerts:** Suppresses audio warnings in stop-and-go traffic (`< 10 km/h`), uses 3-frame debounce filtering to prevent false positives, and delivers Vietnamese voice alerts (`AVSpeechSynthesizer`) only during genuine caution or critical braking scenarios.
- **Thermal-Safe Operation:** Captures at `640×480` / `720p` with adaptive AI frame throttling (`10 FPS` nominal, scaling down automatically via `ProcessInfo.thermalState`) to prevent overheating during extended windshield-mounted drives.

---

## Tech Stack & Architecture

- **Language & UI:** Swift 5.7+, SwiftUI (Landscape-locked, OLED dark-mode HUD)
- **Computer Vision:** `AVFoundation`, `Vision`, `CoreML` (`YOLOv3TinyInt8LUT.mlmodel`)
- **Telemetry & Weather:** `CoreLocation`, `URLSession` (Open-Meteo API, no API key required)
- **Audio Feedback:** `AVSpeechSynthesizer` (`vi-VN`), `AudioToolbox`
- **Minimum Target:** iOS 16.0+ (Tested on iPhone 12 Pro Max)

```text
DriveAssistant/
├── DriveAssistant.xcodeproj
├── YOLOv3TinyInt8LUT.mlmodel      # Quantized CoreML object detection model (~8.9 MB)
└── DriveAssistant/
    └── Sources/
        ├── DriveAssistantApp.swift # App entry point, landscape lock & idle timer disable
        ├── ContentView.swift       # Edge-to-edge HUD layout, trapezoid & bracket overlays
        ├── CameraManager.swift     # AVFoundation capture, Vision inference & thermal guard
        ├── DistanceManager.swift   # ROI filtering, EMA smoothing, TTC & TT38 rule engine
        ├── LocationManager.swift   # Real-time GPS speed (km/h) tracking
        ├── WeatherService.swift    # Automatic Dry/Wet road condition detection
        ├── AlertManager.swift      # Speed-gated chime & Vietnamese voice synthesis
        ├── SettingsView.swift      # Calibration factor, rule mode & alert configuration
        └── Info.plist              # Camera, Location & UILaunchScreen configurations
```

---

## Setup & Installation

### 1. Prerequisites
- macOS with **Xcode 14.2+**
- `YOLOv3TinyInt8LUT.mlmodel` placed in the project root and added to the `DriveAssistant` target's **Copy Bundle Resources**.

### 2. Building the `.ipa`
1. Open `DriveAssistant.xcodeproj` in Xcode.
2. Select the **DriveAssistant** target → **Signing & Capabilities** → enable **Automatically manage signing** and select your Personal Team / Apple ID.
3. Select **Any iOS Device (arm64)** as the build destination and run **Product → Archive**.
4. Locate the generated `.xcarchive` in Organizer (**Right-click → Show in Finder → Show Package Contents**), copy `Products/Applications/DriveAssistant.app` into a folder named `Payload`, and package it cleanly via Terminal:
   ```bash
   find Payload -name ".DS_Store" -delete
   zip -ry DriveAssistant.ipa Payload
   ```
5. Sideload `DriveAssistant.ipa` onto your iPhone using `ideviceinstaller` or Sideloadly (with dylib injection disabled for maximum stability).

---

## Calibration & Mounting Tips

1. **Mounting:** Use an air-vent mount rather than direct windshield mounting under strong sunlight to keep the device cool during long drives.
2. **Horizon Alignment:** Tilt the phone mount so the top edge of the cyan trapezoid aligns with the road horizon and the side edges sit inside your current lane markings.
3. **Distance Calibration:** Park roughly one car length (`~4.5m–5.0m`) behind a standard sedan and adjust the **Calibration Factor** slider in Settings (default `1.40`) until the HUD readout matches reality.

---

## Disclaimer

This software is intended solely as a supplemental driver-assistance aid for personal use. It does not replace attentive driving, visual judgment, or official vehicle safety systems. Always obey posted traffic signs and local road conditions.