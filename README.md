# DriveAssistant

**DriveAssistant** is an experimental native iOS ADAS prototype built with **Swift**, **SwiftUI**, **AVFoundation**, **Vision**, **CoreML**, **CoreImage**, and **CoreMotion**. It uses the rear camera and GPS speed to estimate the distance to the closest detected vehicle ahead, visualize a dynamic forward-lane carpet with lane-departure warnings, warn when the gap falls below the configured threshold, and recognizes Vietnam traffic signs via a custom CoreML model to alert on overspeed and auto-clear stale limits.

> **Important:** This is not a certified or production-ready safety system. Monocular distance estimates can be wrong in low light, curves, hills, camera movement, occlusion, and when vehicle size changes. Use it only as a supplemental prototype while parked or during carefully supervised testing.

---

## Current Behavior

### Detection & distance
- Runs the quantized **YOLOv8n** CoreML model (`yolov8n.mlpackage`) completely on device through Vision/CoreML; no camera frames leave the phone.
- Keeps `car`, `truck`, `bus`, and `motorbike` observations with confidence ≥ `0.5` and minimum normalized box dimensions of `0.06`.
- Merges overlapping detections (`IoU > 0.30`), tracks a lead target across frames, and requires three consecutive plausible frames before switching to a new target.
- **Target switch protection:** Separate IoU tracker (`IoU < 0.15`) clears distance history on target swap (e.g., far car → passing motorcycle) to prevent fake closing-speed spikes.
- Filters detections to a narrowed static forward-road trapezoid: top `x = 0.42–0.58` (width `0.16`), bottom `x = 0.29–0.71` (width `0.42`) in normalized video space.
- **Strict left-edge filter:** For boxes with `midX < 0.5 + laneOffset`, only center/bottom-center inside ROI is accepted (edge overlap disabled) to reject oncoming/storefront detections; emits `oncoming_lane_suspect` diagnostic with midX, confidence, laneOffset.
- **Dynamic ROI override:** When lane detection is confident, the vehicle filter polygon snaps to detected lane edges for tighter relevance.
- Estimates distance from class-specific assumed physical widths (`car`: `1.8 m`, `truck`/`bus`: `2.5 m`, `motorbike`: `0.75 m`) divided by smoothed bounding-box width, then applies user calibration factor and hood offset.
- Smooths distance with EMA (`α = 0.3`), derives closing speed/TTC from `0.5 s` rolling history.
- **TTC critical threshold:** Critical alerts only fire when GPS speed ≥ `25 km/h` (prevents false criticals at standstill); below `25 km/h` uses distance `< 3.5 m` gate instead.

### Lane detection & LDWS (Lane Departure Warning System)
- **CoreImage + Vision contours** pipeline (no second CoreML model): enhances white/yellow lane markings in the lower road ROI, detects contours, classifies left/right by ROI center, fits quadratic curves, and applies EMA smoothing (`α = 0.25`) with a 15-frame grace window.
- **ROI geometry:** Static trapezoid in normalized video space (top `0.38`, bottom `0.95`, top width `0.16`, bottom width `0.42`, center offset `laneCenterOffsetX`) — shared by CameraManager static ROI, LaneDetector, and ContentView static fallback.
- **Departure state machine:** `none` → `driftingLeft`/`driftingRight` (orange) when vehicle center is within 8% of a lane edge for `≥ 0.4 s`, or crosses it. Alert fires only on actual crossing with persistence + 3 s cooldown.
- **Speed gating:** LDWS only arms when GPS speed ≥ configurable threshold (default `50 km/h`, range `40–70 km/h`).
- **HUD visualization:** Dynamic curved lane carpet fading toward horizon; color shifts cyan → orange → red on drift/alert with pulsing dashed red on departure.
- **Lane carpet clipping:** Static fallback trapezoid clipped at lead vehicle rear bumper (`vehicleRect.maxY`) with perspective-preserving linear interpolation of top width. Dynamic curved rails clipped at same boundary via exact Y-interpolation.
- **Static fallback projection:** When dynamic lanes unavailable, static trapezoid defined in normalized video coordinates (`0...1` top-left origin) and projected through exact same `aspectFill` transform (`scale`, `xOffset`, `yOffset` using `cameraFrameSize`) as dynamic lanes — pixel-perfect alignment with CameraManager's lane filter boundaries on 19.5:9 screen.
- **Out-of-ROI vehicles:** Subtle gray boxes for vehicles detected outside the lane polygon (no alerts).
- **Diagnostics:** Emits `ldws_departure_alert` (on rising edge) and `ldws_mode_changed` (dynamic↔static, throttled to 5 s) events.

### Traffic Sign Recognition (TSR) — Vietnam Speed Limits & Advisory Signs
- **Custom CoreML model** (`vn_signs_ios16.mlpackage` compiled to `.mlmodelc`) runs at 2 Hz (`processInterval = 0.5 s`) on Neural Engine via `VNCoreMLRequest` with `MLComputeUnits.cpuAndNeuralEngine`. Uses `.scaleFill` on full frame, paused at critical thermal state.
- **Detections filtered** at `confidence ≥ 0.48` and `boundingBox.width ≥ 0.018`. Model outputs class labels (Count strings from `data.yaml` / 0-based indices) mapped to sign types via lookup table in `TrafficSignDetector.swift`.
- **Speed limits (P.127):** Label → value: `"124"/"57"→10`, `"114"/"61"→20`, `"62"→30`, `"360"/"2"→40`, `"402"/"39"→50`, `"750"/"12"→60`, `"105"/"40"→70`, `"441"/"41"→80`, `"102"/"63"→90`, `"103"/"58"→100`, `"101"/"59"→110`, `"60"→120`. Requires 2 consecutive frames before updating `detectedSpeedLimit`.
- **Residential area:** Labels `"164"/"79"` → sets `detectedSpeedLimit = 50` AND publishes advisory `"Residential Area"` (localized).
- **Clear limit (DP.134 / DP.135):** Labels `"190"/"48"`, `"141"/"78"`, `"117"/"80"` → auto-clears stale speed limit after 2 consecutive frames, fires `didClearSpeedLimitEvent`.
- **Advisory / prohibitory signs:** `"572"/"0"→"No Entry"`, `"279"/"6"→"No Cars"`, `"123"/"45"→"No Overtaking"`. Published as canonical keys (`"no_entry"`, `"no_cars"`, `"no_overtaking"`, `"residential_area"`) in `activeAdvisorySignText` with 3.5 s auto-clear. Rendered as secondary blue badge next to speed limit badge; text localized to Vietnamese/English per language setting.
- **Stability:** All classifications require 2 consecutive matches. Manual clear via tap on speed-limit badge.
- **Diagnostics:** Emits `tsr_yolo_detect` (raw detections per frame) and `tsr_state` (confirmed actions) events.

### Camera & thermal policy
- Captures `1280×720` at up to `15 FPS` on the rear wide-angle camera.
- Uses late-frame dropping (`alwaysDiscardsLateVideoFrames = true`) and an autorelease pool to control backpressure and memory.
- Runs inference at `10 FPS` after a fast five-frame warm-up, or `6 FPS` if warm-up is slower; thermal pressure reduces this to `6 FPS` (fair) or `3 FPS` (serious), and pauses inference in critical thermal state.
- Lane detector runs on every 2nd inference frame (skipped at serious/critical thermal).
- TSR runs at 2 Hz independent of inference cadence; paused at critical thermal.
- Supports both landscape orientations and maps device/video/Vision orientations for display and inference.
- **Live ambient luminance sampling:** Every ~1.5 s reads EXIF brightness or computes average luma from the pixel buffer for auto Day/Night theme switching with hysteresis (`< 1.2` night, `> 2.2` day).

### Mount calibration & horizon alignment
- **MotionManager** uses `CMMotionManager` at 10 Hz with gravity-vector attitude computation (Gimbal-lock-free for landscape mounting).
- **Reference profile:** Save current pitch/roll as mount reference; deltas from reference drive the horizon line.
- **Mount aligned indicator:** Green when `ΔRoll ≤ 1.5°` and `ΔPitch ≤ 1.5°`; amber otherwise.
- **Level indicator:** Green when `ΔRoll ≤ 1.5°` and `ΔPitch ≤ 3.0°`.
- **Dynamic effective horizon:** Gyro baseline + slow EMA (`α = 0.02`) toward vision-inferred horizon during straight driving, clamped to `±0.06` of gyro baseline.
- **Horizon overlay:** Dashed line with center text showing `R/P` deltas or `MOUNT ALIGNED` / `0.0° LEVEL`.

### In-drive auto-calibration
- **Progress tracking:** While driving straight (`> 25 km/h`, `ΔRoll < 2°`) with a stable lead vehicle or confident lane lines, calibration progress increments `~2%` per valid frame (visible in HUD as `"Đang tự hiệu chỉnh X%"` / `"Auto-calibrating X%"` in cyan).
- **Auto-persist:** On reaching `100%`, the current pose becomes the new calibrated reference (`calibratedPitch/Roll`, `hasSavedMountProfile = true`) and the learned horizon offset is saved to `UserDefaults`. Future drives start calibrated immediately without manual setup.
- **Mount-shift detection:** If `ΔRoll > 3.5°` or `ΔPitch > 3.5°` persists for `≥ 2 s` at speed `> 10 km/h`, HUD shows `"⚠ Máy bị xê dịch"` / `"⚠ Mount shifted"` (amber). Calibration progress resets to `0` and auto-recalibrates once the mount settles back within `±1.5°`.
- **Continuous adaptation:** During driving, the effective horizon slowly adapts via EMA toward vision-inferred horizon (lead vehicle box geometry or lane vanishing point), with the learned offset continuously persisted.

### Stop-and-Go Alert (Lead Vehicle Departure)
- **Trigger:** Vehicle ahead detected within `20 m` → arm; vehicle moves beyond `12 m` (or is lost) while speed ≤ `5 km/h` → fire.
- **State machine:** `idle` → `armed` (distance ≤ 20 m & speed ≤ 5 km/h) → `triggered` (distance > 12 m or lost) → `cooldown` (8 s).
- **Disarm:** Speed > 5 km/h for ≥ 1 s or distance > 25 m returns to `idle`.
- **Alert:** Ascending two-note chime `C5 (523.25 Hz) → E5 (659.25 Hz)` with 0.15 s gap + success haptic + Vietnamese speech "Lead vehicle has moved".

### Rules & alerts
- **VN TT38-style mode** applies speed-tiered minimum gaps: `max(5, speed × 0.5)` below `58 km/h`, `35 m` around `58–60 km/h`, `55 m` from `60–80 km/h`, `70 m` from `80–100 km/h`, and `100 m` above `100 km/h`. It suppresses alerts below `10 km/h`.
- **Time-headway mode** uses `max(5, speed × timeHeadway)` with a configurable `1.5–4.0 s` headway; its warning threshold also covers very short low-speed gaps (`< 4 m`).
- Wet-road detection can increase VN-law minimums by `1.3×`. Open-Meteo is queried at most every `5 minutes` or after moving more than `5 km`; network failure falls back to dry.
- Critical state requires three consecutive candidate frames. Warning chimes have a `5 s` cooldown; critical alerts have a `3 s` cooldown. Critical speech is Vietnamese (`vi-VN`) and can be disabled.
- **Overspeed Alert (TSR):** When TSR active limit exists, `speed > limit + tolerance` triggers sharp A5 (880 Hz) chime + error haptic + Vietnamese "Exceeds speed limit X kilometers per hour". Cooldown `10 s`. Tolerance configurable `0–10 km/h` (default `3 km/h`).
- **Speed Limit Cleared Alert (DP.134/DP.135):** Descending `E5 → C5` (0.12 s gap) + success haptic + "Speed limit ended". Shows emerald micro-badge "Limit ended" under badge for 2.5 s.

### HUD, settings & diagnostics
- Landscape dark HUD shows GPS speed and accuracy, distance, safe-gap progress, thermal state, detected/target vehicle, and weather/road-condition pill.
- **GPSSpeedPill:** Speed text turns red-orange (`1.0, 0.2, 0.0`) when overspeeding (pulsing glow + scale animation).
- **SpeedLimitSignBadge:** 38 pt white circle with 4 pt red border, bold number (or dimmed `"--"`). Tap clears limit. Red glow pulse when overspeeding.
- **Secondary Advisory Badge:** Blue rounded-rect with exclamation-triangle icon + localized text (e.g., "No Overtaking" / "Cấm vượt", "Residential Area" / "Khu dân cư") rendered next to speed limit badge; auto-clears after 3.5 s.
- **Calibration status** (in Distance card): Shows "Auto-calibrating X%" (cyan) while auto-calibrating, "⚠ Mount shifted" (amber) on mount shift, hidden when calibrated.
- **Display Theme:** Auto (3-tier: camera luminance → GPS astronomical sunrise/sunset → clock fallback), Day, Night.
- **HUD Mirror Mode:** Vertically flips the view for windshield reflection; sets screen brightness to maximum, restores on exit.
- **Eco Black HUD:** Replaces live video with black background to reduce power and heat.
- **Glass effect:** Ultra-thin material cards/pills with night-dim variant.
- **Screenshot capture:** Flash animation + composites live camera frame + HUD overlay into Photos library. **Silent auto-capture** (no flash/alert) on critical alerts and anomaly events via `debugCaptureTrigger`.
- **Live timestamp:** Bottom-center HUD label `dd/MM/yyyy HH:mm:ss` (11 pt monospaced), updates via 1 s timer.
- Settings expose: Distance rule, calibration factor, hood offset, lane center offset, time headway, road condition, language (VI/EN), voice alerts, LDWS enable + speed threshold, display theme, mirror mode, Eco HUD, glass effect, horizon guide, out-of-lane vehicles, mount calibration save/reset.
- **TSR Settings:** "Speed Sign Recognition" toggle (default on) + "Overspeed tolerance" slider `0–10 km/h`.
- **Stop-and-Go Settings:** "Lead Vehicle Departure Alert" toggle (default on).
- **Diagnostics Settings:** "Auto-Capture Debug Snapshots" toggle (default on, persisted) — auto-captures silent screenshots on `oncoming_lane_suspect`, `oncoming_closing_speed_spike`, and critical alerts (shared 5 s cooldown).
- **DiagnosticsLogStore:** Persistent daily JSONL logging to `Documents/DriveAssistantLogs/DriveAssistant-yyyy-MM-dd.jsonl` (async append on serial background queue). In-memory ring buffer (5000 events) + `eventPublisher` PassthroughSubject for real-time observers. Export reads today's daily log if in-memory empty. `clear()` deletes all `.jsonl` files.
- **Anomaly event types:** `target_switched_iou`, `oncoming_lane_suspect`, `oncoming_closing_speed_spike`, `ldws_departure_alert`, `ldws_mode_changed`, `overspeed_alert`, `stop_and_go_alert`, `mount_shifted`, `alert_state_changed` (with `state=warning/critical/clear` + `reason=ttc|distance_below_3.5m`), `tsr_yolo_detect`, `tsr_state`.

---

## Architecture

```text
DriveAssistant/
├── DriveAssistant.xcodeproj
├── yolov8n.mlpackage/                 # Quantized CoreML object-detection model (~6.5 MB)
├── vn_signs_ios16.mlpackage/          # Custom CoreML traffic sign classifier (~8 MB)
└── DriveAssistant/
    ├── Assets.xcassets
    ├── Info.plist                     # Camera/location usage, landscape support, launch screen
    └── Sources/
        ├── DriveAssistantApp.swift    # SwiftUI app lifecycle and idle-timer control
        ├── DriveAssistantModel.swift  # Observable state, rule engine, EMA/TTC, alert decisions, theme, TSR/stop-and-go logic
        ├── CameraManager.swift        # Capture session, Vision inference, tracking, thermal guard, brightness, TSR gate
        ├── CameraPreview.swift        # AVCaptureVideoPreviewLayer-backed SwiftUI view
        ├── ContentView.swift          # HUD, overlays, lane carpet, horizon, screenshot, progress, thermal badge, controls
        ├── SettingsView.swift         # Runtime settings, mount calibration, diagnostics export/clear
        ├── LocationManager.swift      # When-in-use GPS speed/accuracy, astronomical night, weather trigger
        ├── WeatherService.swift       # Rate-limited Open-Meteo dry/wet lookup
        ├── AlertManager.swift         # Cooldowns, system sounds, Vietnamese speech, synthesized chimes (AVAudioEngine)
        ├── DiagnosticsLogStore.swift  # Persistent daily JSONL logging + in-memory ring buffer (5000), eventPublisher, export/clear
        ├── LaneDetector.swift         # CoreImage/Vision contour lane detection, EMA, LDWS state machine, departure/mode diagnostics
        ├── MotionManager.swift        # CMMotionManager gravity-vector attitude, mount profile, horizon calibration, mount-shift (2 s @ 3.5°)
        └── TrafficSignDetector.swift  # VNCoreMLRequest on vn_signs_ios16 (2 Hz, Neural Engine), class-index→label mapping, advisory badge
```

The app intentionally avoids a separate distance manager: `CameraManager` owns Vision and tracking outputs, `LaneDetector` owns lane geometry, `MotionManager` owns horizon alignment, `TrafficSignDetector` owns TSR (CoreML-based), while `DriveAssistantModel` combines those outputs with GPS, road condition, settings, and alert state.

---

## Requirements

- macOS with **Xcode 14.0+**
- iPhone or iPad running **iOS 16.0+** (Neural Engine required for TSR model)
- Camera and location permissions
- Internet only for automatic wet-road detection; the remainder of the pipeline works offline

CoreML models included in the repository and configured as target resources:
- `yolov8n.mlpackage` — quantized object detection (~6.5 MB)
- `vn_signs_ios16.mlpackage` — Vietnam traffic sign classifier (~8 MB)

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

### CI / GitHub Actions
- **Workflow:** `.github/workflows/build-ipa.yml` builds unsigned Release IPA on `macos-latest` on every push to `main` and via `workflow_dispatch`.
- **Artifact:** `DriveAssistant-Release.ipa` uploaded with 7-day retention.
- **Build flags:** `CODE_SIGNING_ALLOWED=NO`, `CODE_SIGNING_REQUIRED=NO`, `CODE_SIGN_IDENTITY=""`.

---

## Calibration

### Manual mount calibration
1. Mount the phone in landscape with the rear camera facing forward.
2. In Settings → **Mount Calibration**, place iPhone in mount and tap **Save Current Mount Angle** (or **Update Mount Angle**).
3. Verify the HUD shows **✓ Mount aligned** (green) and the horizon line matches the visual horizon.

### In-drive auto-calibration (recommended)
1. Ensure **Show Horizon Guide** is enabled in Settings → **Interface**.
2. Drive straight on a level road at `> 25 km/h` with a visible lead vehicle or clear lane markings.
3. Watch the Distance card: it shows `"Auto-calibrating X%"` (cyan) as progress increases.
4. At `100%`, the mount angle and horizon offset are automatically saved. The HUD shows **✓ Mount aligned** (green) on next launch.
5. If the mount shifts (`"⚠ Mount shifted"` appears), simply drive straight again — it will auto-recalibrate once settled.

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
- TSR runs on full frame via CoreML; signs on far left, center gantry, or heavily occluded may be missed. Model trained on Vietnamese sign dataset; non-standard or heavily faded signs may not trigger.
- Diagnostics persist daily as JSONL (`DriveAssistant-yyyy-MM-dd.jsonl`) in `Documents/DriveAssistantLogs/`; export reads today's log if in-memory buffer empty. No automatic log rotation (manual clear from Settings).
- Weather-based wet mode depends on network availability and uses coarse Open-Meteo conditions rather than direct road-surface sensing.
- **GPS stall detection:** If GPS speed < `1 km/h` for `> 10 s` while moving previously, `isSpeedStalled` flags true (prevents stale speed from triggering false alerts).
- Thermal throttling reduces inference FPS; prolonged use in direct sun may pause detection entirely.
- HUD Mirror Mode requires a reflective windshield surface; brightness is set to maximum and restored on exit.
- Avoid public-road use until tracking, calibration, permissions, thermal behavior, and alert timing have been validated on a closed course.

---

## Disclaimer

DriveAssistant is a supplemental experimental aid for personal engineering use. It does not replace attentive driving, visual judgment, legal requirements, or vehicle safety systems. The authors do not guarantee correctness, availability, or fitness for safety-critical use. Always obey posted traffic signs and local road conditions.