# DriveAssistant

**DriveAssistant** is an experimental native iOS ADAS prototype built with **Swift**, **SwiftUI**, **AVFoundation**, **Vision**, **CoreML**, **CoreImage**, and **CoreMotion**. It uses the rear camera and GPS speed to estimate the distance to the closest detected vehicle ahead, visualize a dynamic forward-lane carpet with lane-departure warnings, and warn when the gap falls below the configured threshold.

> **Important:** This is not a certified or production-ready safety system. Monocular distance estimates can be wrong in low light, curves, hills, camera movement, occlusion, and when vehicle size changes. Use it only as a supplemental prototype while parked or during carefully supervised testing.

---

## Current Behavior

### Detection & distance
- Runs the quantized **YOLOv8n** CoreML model (`yolov8n.mlpackage`) completely on device through Vision/CoreML; no camera frames leave the phone.
- Keeps `car`, `truck`, `bus`, and `motorbike` observations with confidence ≥ `0.5` and minimum normalized box dimensions of `0.06`.
- Merges overlapping detections (`IoU > 0.30`), tracks a lead target across frames, and requires three consecutive plausible frames before switching to a new target.
- Filters detections to a fixed forward-road trapezoid spanning normalized `x = 0.38–0.62` at the top and `x = 0.20–0.80` near the bottom.
- **Dynamic ROI override:** When lane detection is confident, the vehicle filter polygon snaps to the detected lane edges for tighter relevance.
- Estimates distance from class-specific assumed physical widths (`car`: `1.8 m`, `truck`/`bus`: `2.5 m`, `motorbike`: `0.75 m`) divided by the smoothed bounding-box width, then applies the user calibration factor and hood offset.
- Smooths distance with an EMA (`α = 0.3`) and derives closing speed/TTC from a `0.5 s` rolling distance history.

### Lane detection & LDWS (Lane Departure Warning System)
- **CoreImage + Vision contours** pipeline (no second CoreML model): enhances white/yellow lane markings in the lower road ROI, detects contours, classifies left/right by ROI center, fits quadratic curves, and applies EMA smoothing (`α = 0.25`) with a 15-frame grace window.
- **Departure state machine:** `none` → `driftingLeft`/`driftingRight` (orange) when vehicle center is within 8% of a lane edge for `≥ 0.4 s`, or crosses it. Alert fires only on actual crossing with persistence + 3 s cooldown.
- **Speed gating:** LDWS only arms when GPS speed ≥ configurable threshold (default `50 km/h`, range `40–70 km/h`).
- **HUD visualization:** Dynamic curved lane carpet fading toward horizon; color shifts cyan → orange → red on drift/alert with pulsing dashed red on departure.
- **Out-of-ROI vehicles:** Subtle gray boxes for vehicles detected outside the lane polygon (no alerts).

### Camera & thermal policy
- Captures `1280×720` at up to `15 FPS` on the rear wide-angle camera.
- Uses late-frame dropping (`alwaysDiscardsLateVideoFrames = true`) and an autorelease pool to control backpressure and memory.
- Runs inference at `10 FPS` after a fast five-frame warm-up, or `6 FPS` if warm-up is slower; thermal pressure reduces this to `6 FPS` (fair) or `3 FPS` (serious), and pauses inference in critical thermal state.
- Lane detector runs on every 2nd inference frame (skipped at serious/critical thermal).
- Supports both landscape orientations and maps device/video/Vision orientations for display and inference.
- **Live ambient luminance sampling:** Every ~1.5 s reads EXIF brightness or computes average luma from the pixel buffer for auto Day/Night theme switching with hysteresis (`< 1.2` night, `> 2.2` day).

### Mount calibration & horizon alignment
- **MotionManager** uses `CMMotionManager` at 10 Hz with gravity-vector attitude computation (Gimbal-lock-free for landscape mounting).
- **Reference profile:** Save current pitch/roll as mount reference; deltas from reference drive the horizon line.
- **Mount aligned indicator:** Green when `ΔRoll ≤ 1.5°` and `ΔPitch ≤ 1.5°`; amber otherwise.
- **Level indicator:** Green when `ΔRoll ≤ 1.5°` and `ΔPitch ≤ 3.0°`.
- **Dynamic effective horizon:** Gyro baseline + slow EMA (`α = 0.02`) toward vision-inferred horizon during straight driving, clamped to `±0.06` of gyro baseline.
- **Horizon overlay:** Dashed line with center text showing `R/P` deltas or `MOUNT ALIGNED` / `0.0° LEVEL`.

### In-drive auto-calibration (new)
- **Progress tracking:** While driving straight (`> 25 km/h`, `ΔRoll < 2°`) with a stable lead vehicle or confident lane lines, calibration progress increments `~2%` per valid frame (visible in HUD as `"Đang tự hiệu chỉnh X%"` / `"Auto-calibrating X%"` in cyan).
- **Auto-persist:** On reaching `100%`, the current pose becomes the new calibrated reference (`calibratedPitch/Roll`, `hasSavedMountProfile = true`) and the learned horizon offset is saved to `UserDefaults`. Future drives start calibrated immediately without manual setup.
- **Mount-shift detection:** If `ΔRoll > 3.5°` or `ΔPitch > 3.5°` persists for `≥ 2 s` at speed `> 10 km/h`, HUD shows `"⚠ Máy bị xê dịch"` / `"⚠ Mount shifted"` (amber). Calibration progress resets to `0` and auto-recalibrates once the mount settles back within `±1.5°`.
- **Continuous adaptation:** During driving, the effective horizon slowly adapts via EMA toward vision-inferred horizon (lead vehicle box geometry or lane vanishing point), with the learned offset continuously persisted.

### Rules & alerts
- **VN TT38-style mode** applies speed-tiered minimum gaps: `max(5, speed × 0.5)` below `58 km/h`, `35 m` around `58–60 km/h`, `55 m` from `60–80 km/h`, `70 m` from `80–100 km/h`, and `100 m` above `100 km/h`. It suppresses alerts below `10 km/h`.
- **Time-headway mode** uses `max(5, speed × timeHeadway)` with a configurable `1.5–4.0 s` headway; its warning threshold also covers very short low-speed gaps (`< 4 m`).
- Wet-road detection can increase VN-law minimums by `1.3×`. Open-Meteo is queried at most every `5 minutes` or after moving more than `5 km`; network failure falls back to dry.
- Critical state requires three consecutive candidate frames. Warning chimes have a `5 s` cooldown; critical alerts have a `3 s` cooldown. Critical speech is Vietnamese (`vi-VN`) and can be disabled.

### HUD, settings & diagnostics
- Landscape dark HUD shows GPS speed and accuracy, distance, safe-gap progress, thermal state, detected/target vehicle, and weather/road-condition pill.
- **Calibration status** (in Distance card): Shows `"Đang tự hiệu chỉnh X%"` (cyan) while auto-calibrating, `"⚠ Máy bị xê dịch"` (amber) on mount shift, hidden when calibrated.
- **Display Theme:** Auto (3-tier: camera luminance → GPS astronomical sunrise/sunset → clock fallback), Day, Night.
- **HUD Mirror Mode:** Vertically flips the view for windshield reflection; sets screen brightness to maximum, restores on exit.
- **Eco Black HUD:** Replaces live video with black background to reduce power and heat.
- **Glass effect:** Ultra-thin material cards/pills with night-dim variant.
- **Screenshot capture:** Flash animation + composites live camera frame + HUD overlay into Photos library.
- Settings expose: Distance rule, calibration factor, hood offset, lane center offset, time headway, road condition, language (VI/EN), voice alerts, LDWS enable + speed threshold, display theme, mirror mode, Eco HUD, glass effect, horizon guide, out-of-lane vehicles, mount calibration save/reset.
- Diagnostics records session, alert, orientation, camera-performance, inference, thermal, target-switch, lane-detection, and anonymized detection-box events to an in-memory JSON export. The temporary export file is not persisted automatically and can be cleared from Settings.

---

## Architecture

```text
DriveAssistant/
├── DriveAssistant.xcodeproj
├── yolov8n.mlpackage/                 # Quantized CoreML object-detection model (~6.5 MB)
└── DriveAssistant/
    ├── Assets.xcassets
    ├── Info.plist                     # Camera/location usage, landscape support, launch screen
    └── Sources/
        ├── DriveAssistantApp.swift    # SwiftUI app lifecycle and idle-timer control
        ├── DriveAssistantModel.swift  # Observable state, rule engine, EMA/TTC, alert decisions, theme
        ├── CameraManager.swift        # Capture session, Vision inference, tracking, thermal guard, brightness
        ├── CameraPreview.swift        # AVCaptureVideoPreviewLayer-backed SwiftUI view
        ├── ContentView.swift          # HUD, overlays, lane carpet, horizon, screenshot, progress, thermal badge, controls
        ├── SettingsView.swift         # Runtime settings, mount calibration, diagnostics export/clear
        ├── LocationManager.swift      # When-in-use GPS speed/accuracy, astronomical night, weather trigger
        ├── WeatherService.swift       # Rate-limited Open-Meteo dry/wet lookup
        ├── AlertManager.swift         # Cooldowns, system sounds, Vietnamese speech
        ├── DiagnosticsLogStore.swift  # In-memory diagnostics and JSON export
        ├── LaneDetector.swift         # CoreImage/Vision contour lane detection, EMA, LDWS state machine
        └── MotionManager.swift        # CMMotionManager gravity-vector attitude, mount profile, horizon calibration
```

The app intentionally avoids a separate distance manager: `CameraManager` owns Vision and tracking outputs, `LaneDetector` owns lane geometry, `MotionManager` owns horizon alignment, while `DriveAssistantModel` combines those outputs with GPS, road condition, settings, and alert state.

---

## Requirements

- macOS with **Xcode 14.0+**
- iPhone or iPad running **iOS 16.0+**
- Camera and location permissions
- Internet only for automatic wet-road detection; the remainder of the pipeline works offline

The CoreML model (`yolov8n.mlpackage`) is included in the repository and configured as a target resource.

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

### Manual mount calibration
1. Mount the phone in landscape with the rear camera facing forward.
2. In Settings → **Mount Calibration**, place iPhone in mount and tap **Save Current Mount Angle** (or **Update Mount Angle**).
3. Verify the HUD shows **✓ Mount aligned** (green) and the horizon line matches the visual horizon.

### In-drive auto-calibration (recommended)
1. Ensure **Show Horizon Guide** is enabled in Settings → **Interface**.
2. Drive straight on a level road at `> 25 km/h` with a visible lead vehicle or clear lane markings.
3. Watch the Distance card: it shows `"Đang tự hiệu chỉnh X%"` (cyan) as progress increases.
4. At `100%`, the mount angle and horizon offset are automatically saved. The HUD shows **✓ Mount aligned** (green) on next launch.
5. If the mount shifts (`"⚠ Máy bị xê dịch"` appears), simply drive straight again — it will auto-recalibrate once settled.

### Distance calibration
1. Park about one car length (`4.5–5.0 m`) behind a standard sedan.
2. In Settings → **Calibration**, adjust **Distance calibration factor** (default `1.40`) until the HUD distance matches the measured gap.
3. Adjust **Hood offset (m)** if the distance is consistently off by a fixed amount (vehicle mounting height).
4. Adjust **Lane center offset** if the lane carpet sits left/right of your lane.
5. Recheck calibration after changing mounting position, device, or camera crop/scale.

---

## Limitations & Road-Testing Notes

- Distance is monocular and depends on bounding-box width; it is not radar/LiDAR-grade and can be biased by vehicle type, crop, scale, occlusion, and tracking error.
- Lane detection uses contour heuristics on the lower ROI; it can fail in rain, glare, faded markings, or heavy shadows.
- The dynamic ROI for vehicle filtering snaps to detected lanes but falls back to the fixed trapezoid when confidence is low.
- There is no persistent log rotation. Diagnostics are cleared on app restart and held in memory until exported.
- Weather-based wet mode depends on network availability and uses coarse Open-Meteo conditions rather than direct road-surface sensing.
- Thermal throttling reduces inference FPS; prolonged use in direct sun may pause detection entirely.
- HUD Mirror Mode requires a reflective windshield surface; brightness is set to maximum and restored on exit.
- Avoid public-road use until tracking, calibration, permissions, thermal behavior, and alert timing have been validated on a closed course.

---

## Disclaimer

DriveAssistant is a supplemental experimental aid for personal engineering use. It does not replace attentive driving, visual judgment, legal requirements, or vehicle safety systems. The authors do not guarantee correctness, availability, or fitness for safety-critical use. Always obey posted traffic signs and local road conditions.