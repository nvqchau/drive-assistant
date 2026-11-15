# DriveAssistant

**DriveAssistant** is an experimental native iOS ADAS prototype built with **Swift**, **SwiftUI**, **AVFoundation**, **Vision**, and **CoreML**. It uses the rear camera and GPS speed to estimate the distance to the closest detected vehicle ahead, visualize a target bracket and forward-lane carpet, and warn when the gap falls below the configured threshold.

> **Important:** This is not a certified or production-ready safety system. Monocular distance estimates can be wrong in low light, curves, hills, camera movement, occlusion, and when vehicle size changes. Use it only as a supplemental prototype while parked or during carefully supervised testing.

---

## Current Behavior

### Detection & distance
- Runs the quantized [`YOLOv3TinyInt8LUT.mlmodel`](YOLOv3TinyInt8LUT.mlmodel) completely on device through Vision/CoreML; no camera frames leave the phone.
- Keeps `car`, `truck`, `bus`, and `motorbike` observations with confidence ≥ `0.5` and minimum normalized box dimensions of `0.06`.
- Merges overlapping detections (`IoU > 0.30`), tracks a lead target across frames, and requires three consecutive plausible frames before switching to a new target.
- Filters detections to a fixed forward-road trapezoid spanning normalized `x = 0.38–0.62` at the top and `x = 0.20–0.80` near the bottom.
- Estimates distance from class-specific assumed physical widths (`car`: `1.8 m`, `truck`/`bus`: `2.5 m`, `motorbike`: `0.75 m`) divided by the smoothed bounding-box width, then applies the user calibration factor.
- Smooths distance with an EMA (`α = 0.3`) and derives closing speed/TTC from a `0.5 s` rolling distance history.

### Camera & thermal policy
- Captures `1280×720` at up to `15 FPS` on the rear wide-angle camera.
- Uses late-frame dropping (`alwaysDiscardsLateVideoFrames = true`) and an autorelease pool to control backpressure and memory.
- Runs inference at `10 FPS` after a fast five-frame warm-up, or `6 FPS` if warm-up is slower; thermal pressure reduces this to `6 FPS` (fair) or `3 FPS` (serious), and pauses inference in critical thermal state.
- Supports both landscape orientations and maps device/video/Vision orientations for display and inference.

### Rules & alerts
- **VN TT38-style mode** applies speed-tiered minimum gaps: `max(5, speed × 0.5)` below `58 km/h`, `35 m` around `58–60 km/h`, `55 m` from `60–80 km/h`, `70 m` from `80–100 km/h`, and `100 m` above `100 km/h`. It suppresses alerts below `10 km/h`.
- **Time-headway mode** uses `max(5, speed × timeHeadway)` with a configurable `1.5–4.0 s` headway; its warning threshold also covers very short low-speed gaps (`< 4 m`).
- Wet-road detection can increase VN-law minimums by `1.3×`. Open-Meteo is queried at most every `5 minutes` or after moving more than `5 km`; network failure falls back to dry.
- Critical state requires three consecutive candidate frames. Warning chimes have a `5 s` cooldown; critical alerts have a `3 s` cooldown. Critical speech is Vietnamese (`vi-VN`) and can be disabled.

### HUD, settings & diagnostics
- Landscape dark HUD shows GPS speed and accuracy, distance, safe-gap progress, thermal state, detected/target vehicle, and weather/road-condition pill.
- Eco Black HUD replaces live video with a black background to reduce power and heat.
- Settings expose VN-law/time-headway mode, calibration factor, headway, road condition, Vietnamese/English labels, voice alerts, and eco HUD.
- Diagnostics records session, alert, orientation, camera-performance, inference, thermal, target-switch, and anonymized detection-box events to an in-memory JSON export. The temporary export file is not persisted automatically and can be cleared from Settings.

---

## Architecture

```text
DriveAssistant/
├── DriveAssistant.xcodeproj
├── YOLOv3TinyInt8LUT.mlmodel          # Quantized CoreML object-detection model (~8.9 MB)
└── DriveAssistant/
    ├── Assets.xcassets
    ├── Info.plist                     # Camera/location usage, landscape support, launch screen
    └── Sources/
        ├── DriveAssistantApp.swift    # SwiftUI app lifecycle and idle-timer control
        ├── DriveAssistantModel.swift  # Observable state, rule engine, EMA/TTC, alert decisions
        ├── CameraManager.swift        # Capture session, Vision inference, tracking, thermal guard
        ├── CameraPreview.swift        # AVCaptureVideoPreviewLayer-backed SwiftUI view
        ├── ContentView.swift          # HUD, overlays, progress, thermal badge, controls
        ├── SettingsView.swift         # Runtime settings, diagnostics export/clear
        ├── LocationManager.swift      # When-in-use GPS speed/accuracy and weather trigger
        ├── WeatherService.swift       # Rate-limited Open-Meteo dry/wet lookup
        ├── AlertManager.swift         # Cooldowns, system sounds, Vietnamese speech
        └── DiagnosticsLogStore.swift  # In-memory diagnostics and JSON export
```

The app intentionally avoids a separate distance manager: `CameraManager` owns Vision and tracking outputs, while `DriveAssistantModel` combines those outputs with GPS, road condition, settings, and alert state.

---

## Requirements

- macOS with **Xcode 14.0+**
- iPhone or iPad running **iOS 16.0+**
- Camera and location permissions
- Internet only for automatic wet-road detection; the remainder of the pipeline works offline

The CoreML model is included in the repository and configured as a target resource.

---

## Build & Install

### Run from Xcode
1. Open `DriveAssistant.xcodeproj`.
2. Select the **DriveAssistant** target → **Signing & Capabilities**.
3. Choose your development team and connect an iOS device.
4. Build and run.

### Package a sideload `.ipa`
1. Archive for **Any iOS Device (arm64)**.
2. In Xcode Organizer, right-click the archive → **Show in Finder** → **Show Package Contents**.
3. Copy `Products/Applications/DriveAssistant.app` into an empty `Payload` folder.
4. From the folder containing `Payload`, run:
   ```bash
   find Payload -name ".DS_Store" -delete
   zip -ry DriveAssistant.ipa Payload
   ```
5. Install with Xcode devices, Apple Configurator, `ideviceinstaller`, or another sideloading tool.

---

## Calibration

1. Mount the phone in landscape with the rear camera facing forward.
2. Align the fixed road carpet with your lane and horizon as closely as possible.
3. Park about one car length (`4.5–5.0 m`) behind a standard sedan.
4. In Settings, adjust **Distance calibration factor** (default `1.40`) until the HUD distance matches the measured gap.
5. Recheck calibration after changing mounting position, device, or camera crop/scale.

---

## Limitations & Road-Testing Notes

- Distance is monocular and depends on bounding-box width; it is not radar/LiDAR-grade and can be biased by vehicle type, crop, scale, occlusion, and tracking error.
- The road ROI is fixed, not lane-detected; camera pitch changes can include adjacent lanes or exclude the real lead vehicle.
- There is no persistent log rotation. Diagnostics are cleared on app restart and held in memory until exported.
- Weather-based wet mode depends on network availability and uses coarse Open-Meteo conditions rather than direct road-surface sensing.
- Avoid public-road use until tracking, calibration, permissions, thermal behavior, and alert timing have been validated on a closed course.

---

## Disclaimer

DriveAssistant is a supplemental experimental aid for personal engineering use. It does not replace attentive driving, visual judgment, legal requirements, or vehicle safety systems. The authors do not guarantee correctness, availability, or fitness for safety-critical use. Always obey posted traffic signs and local road conditions.
