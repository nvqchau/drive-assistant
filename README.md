# DriveAssistant

[![Build DriveAssistant IPA](https://github.com/nvqchau/drive-assistant/actions/workflows/build-ipa.yml/badge.svg)](https://github.com/nvqchau/drive-assistant/actions/workflows/build-ipa.yml)

**DriveAssistant** is an experimental native iOS ADAS prototype built with **Swift**, **SwiftUI**, **AVFoundation**, **Vision**, **CoreML**, **CoreImage**, and **CoreMotion**. It uses the rear camera and GPS speed to estimate the distance to the closest detected vehicle ahead, visualize a dynamic forward-lane carpet with lane-departure warnings, warn when the gap falls below the configured threshold, and recognizes Vietnam traffic signs via a custom CoreML model to alert on overspeed and auto-clear stale limits.

> **Important:** This is not a certified or production-ready safety system. Monocular distance estimates can be wrong in low light, curves, hills, camera movement, occlusion, and when vehicle size changes. Use it only as a supplemental prototype while parked or during carefully supervised testing.

---

## Current Behavior

### Detection & distance
- Runs the **unified 86-class CoreML model** (`vn_adas_unified_ios16.mlpackage`) completely on device through Vision/CoreML; no camera frames leave the phone. Single pass detects **4 vehicle classes** (`car`, `truck`, `bus`, `motorbike`) + **82 Vietnam traffic sign classes**.
- Keeps vehicle observations with confidence ≥ `0.5` and minimum normalized box dimensions of `0.06`.
- Merges overlapping detections (`IoU > 0.30`), tracks a lead target across frames, and requires three consecutive plausible frames before switching to a new target.
- **Target switch protection:** Separate IoU tracker (`IoU < 0.15`) clears distance history on target swap (e.g., far car → passing motorcycle) to prevent fake closing-speed spikes.
- Filters detections to a narrowed static forward-road trapezoid: top `x = 0.42–0.58` (width `0.16`), bottom `x = 0.29–0.71` (width `0.42`) in normalized video space.
- **Strict left-edge filter:** For boxes with `midX < 0.5 + laneOffset`, only center/bottom-center inside ROI is accepted (edge overlap disabled) to reject oncoming/storefront detections; emits `oncoming_lane_suspect` diagnostic with midX, confidence, laneOffset.
- **Dynamic ROI override:** When lane detection is confident, the vehicle filter polygon snaps to detected lane edges for tighter relevance.
- Estimates distance from class-specific assumed physical widths (`car`: `1.8 m`, `truck`/`bus`: `2.5 m`, `motorbike`: `0.75 m`) divided by smoothed bounding-box width, then applies user calibration factor and hood offset.
- Smooths distance with EMA (`α = 0.3`), derives closing speed/TTC from `0.5 s` rolling history.
- **TTC critical threshold:** Critical alerts only fire when GPS speed ≥ `25 km/h` (prevents false criticals at standstill); below `25 km/h` uses distance `< 3.5 m` gate instead.

### Lane detection & LDWS (Lane Departure Warning System)
- **CoreImage + Vision contours** pipeline (no second CoreML model): enhances white/yellow lane markings in the lower road ROI, detects contours, classifies left/right by ROI center, fits **linear perspective lines** (`x = m*y + c`) via least-squares, and applies EMA smoothing (`α = 0.25`) with a 15-frame grace window.
- **Local-contrast edge enhancement (fixes daytime asphalt over-saturation):** `enhanceLaneMarkings` replaces absolute brightness thresholding with local-contrast extraction — paint stripes brighter than surrounding asphalt. White: grayscale (`contrast=1.4`) → `CIUnsharpMask(radius=5, intensity=3)` → `CIColorThreshold(0.68)`. Yellow center: high-sat warm (`sat=3.0, contrast=1.6`) → `CIUnsharpMask(radius=5, intensity=2.5)` → `CIColorThreshold(0.56)`. Combined with `CIMaximumCompositing` + `CIMorphologyMaximum(radius=1.5)`.
- **Slope validation:** Left lane must converge right toward horizon (`-2.2 ≤ m ≤ -0.10`), right lane must converge left (`0.10 ≤ m ≤ 2.2`) since Y decreases upward. Crossover guard ensures fitted top X at `roiTopY` stays on its side: left `topX < centerX - 0.02`, right `topX > centerX + 0.02`.
- **ROI geometry:** Static trapezoid in normalized video space (top `0.38`, bottom `0.95`, top width `0.14`, bottom width `0.44`, center offset `laneCenterOffsetX`) — shared by CameraManager static ROI, LaneDetector, and ContentView static fallback.
- **Single-line lane synthesis:** When only one side is detected with confidence > 0.5, the missing side is synthesized using perspective lane width `w(y) = 0.14 + 0.30 * ((y - 0.38) / (0.95 - 0.38))`, clamped to `[0.02, 0.98]`.
- **Dashed-line support:** `classifyLaneLines` uses `max(width, height) >= 0.04` instead of aspect ratio; perspective lanes at ~45° have near-square bbox (aspectRatio ~0.7–1.4).
- **Departure state machine:** `none` → `driftingLeft`/`driftingRight` (orange) when vehicle center is within 8% of a lane edge for `≥ 0.4 s`, or crosses it. Alert fires only on actual crossing with persistence + 3 s cooldown.
- **Speed gating:** LDWS only arms when GPS speed ≥ configurable threshold (default `50 km/h`, range `40–70 km/h`).
- **HUD visualization:** Dynamic straight lane carpet fading toward horizon; color shifts cyan → orange → red on drift/alert with pulsing dashed red on departure.
- **Lane carpet clipping:** Static fallback trapezoid clipped at lead vehicle rear bumper (`vehicleRect.maxY`) with perspective-preserving linear interpolation of top width. Dynamic rails clipped at same boundary via exact Y-interpolation.
- **Static fallback projection:** When dynamic lanes unavailable, static trapezoid defined in normalized video coordinates (`0...1` top-left origin) and projected through exact same `aspectFill` transform (`scale`, `xOffset`, `yOffset` using `cameraFrameSize`) as dynamic lanes — pixel-perfect alignment with CameraManager's lane filter boundaries on 19.5:9 screen.
- **Out-of-ROI vehicles:** Subtle gray boxes for vehicles detected outside the lane polygon (no alerts).
- **Diagnostics:** Emits `ldws_departure_alert` (on rising edge), `ldws_mode_changed` (dynamic↔static, throttled to 5 s), and **periodic `ldws_debug` every 2.0 s** (`contours=X leftPts=Y rightPts=Z leftConf=A rightConf=B dynamic=C`).
- **Thread-safety:** `NSLock` (`configLock`) protects `roiCenterOffsetX`, `isLDWSEnabled`, `minSpeedForDepartureAlert` accessed from main thread setters and background detection queue.

### Traffic Sign Recognition (TSR) — Vietnam Speed Limits & Advisory Signs
- **Unified CoreML model** (`vn_adas_unified_ios16.mlpackage`) runs single-pass inference in `CameraManager` at up to 4 Hz (`processInterval = 0.15 s` guard, ~6.6 Hz). Thermal-aware throttling: 4 Hz nominal, 2 Hz on `.fair`/`.serious`, paused at `.critical`. All observations forwarded to `TrafficSignDetector` via `processObservations()`.
- **Detections filtered** at `confidence ≥ 0.28` and `boundingBox.width ≥ 0.018`. Model outputs class labels (Count strings from training `data.yaml` / 0-based indices) mapped to sign types via lookup table in `TrafficSignDetector.swift`.
- **Speed limits (P.127):** Label → value: `"124"→10`, `"114"→20`, `"360"→40`, `"402"→50`, `"750"→60`, `"105"→70`, `"441"→80`, `"102"→90`, `"103"→100`, `"101"→110`. Requires 2 consecutive frames before updating `detectedSpeedLimit`; high-confidence (`≥ 0.45`) or OCR-verified detections confirm immediately.
- **Hybrid OCR verification:** For speed-limit labels, expands YOLO bbox by 15% and runs `VNRecognizeTextRequest` (fast, `vi-VN`/`en-US`) on cropped pixel buffer. Parses tokens split on non-digits; first token in valid set `{10,20,30,40,50,60,70,80,90,100,110,120}` wins.
- **Residential area:** Label `"164"` → sets `detectedSpeedLimit = 50` AND publishes advisory `"residential_area"` (localized "Khu dân cư" / "Residential Area").
- **Clear limit (DP.134 / DP.135):** Labels `"141"` (DP.134), `"190"` (DP.135), `"117"` (R.421) → auto-clears stale speed limit after 2 consecutive frames (6 s cooldown), fires `didClearSpeedLimitEvent`, shows emerald micro-badge "Limit ended" / "Hết hạn chế" for 2.5 s.
- **Advisory / prohibitory signs:** `"572"→"no_entry"`, `"279"→"no_cars"`, `"123"→"no_overtaking"`. Published as canonical keys in `activeAdvisorySignText` with 5 s auto-clear. Rendered as authentic Vietnam sign graphics next to speed limit badge; text localized to Vietnamese/English per language setting.
- **Dual carriageway:** Label `"142"` → sets `isDividedRoadFromSign = true` for TT38 divided-road tier.
- **Stability:** All classifications require 2 consecutive matches. Manual clear via tap on speed-limit badge.
- **Thread-safety:** `NSLock` (`stateLock`) protects all confirmation counters (`consecutiveMatchCount`, `lastMatchedLimit`, `missedMatchFrames`, `endSignConsecutiveCount`, `lastEndSignType`, `advisoryConsecutiveCount`, `lastAdvisoryText`, `endResidentialConsecutiveCount`, `lastEndResidentialTriggerTime`) accessed from `clearDetectedLimit()` (main thread) and `processFrame()` (background queue).
- **Diagnostics:** Emits `tsr_yolo_detect` (raw detections per frame) and `tsr_state` (confirmed actions) events.

### OpenStreetMap (Overpass API) & Vietnam TT38 Statutory Limits
- **RoadMetadataService** queries Overpass API (max once per 20 s or 150 m) for: `oneway`, `dual_carriageway`, `lanes`, `maxspeed`, `landuse=residential`, `place` in `{town,suburb,quarter,neighbourhood,village}`, and **Vietnam `admin_level=8` wards/townships** (`Phường` / `Thị trấn`).
- **Residential detection:** `osmIsInResidentialArea` is `Bool?` (`nil` = unknown until first response, `true` = inside, `false` = outside). Set true if: `landuse=residential` found, urban `place` found, `admin_level=8` with name matching `Phường`/`Thị trấn` (regex + localized case-insensitive), or nearest road is `residential`/`living_street`.
- **TT38 statutory limits (Vietnam Circular 38/2015):**
  - Residential: `50 km/h` (2-way) / `60 km/h` (divided)
  - Non-residential: `80 km/h` (2-way) / `90 km/h` (divided)
  - **80 km/h boundary fix:** 60.01–80.0 → 55 m, 80.01–100.0 → 70 m (previously both were 55 m).
- **Camera precedence:** Explicit camera signs (P.127/DP.134/135) have 5-minute precedence over OSM fallback via `lastCameraResidentialSignTime`.
- **HUD TT38 pill:** Shows `"Đôi • 60/90"` / `"Divided • 60/90"` or `"2 chiều • 50/80"` / `"2-Way • 50/80"` when residential state known and limit displayed; tap toggles `isDividedRoad` manual override.

### WeatherService
- **Open-Meteo parser exposed for testing:** `parseRoadCondition(from: Data) -> RoadCondition` evaluates wetness from `precipitation`, `rain`, and `weather_code` (wet if `precipitation > 0.1` or `rain > 0.1` or `weather_code ≥ 51`).

### Camera & thermal policy
- Captures `1280×720` at up to `15 FPS` on the rear wide-angle camera.
- Uses late-frame dropping (`alwaysDiscardsLateVideoFrames = true`) and an autorelease pool to control backpressure and memory.
- Unified inference runs at up to 4 Hz (TSR thermal-aware: 4 Hz nominal, 2 Hz on `.fair`/`.serious`, paused at `.critical`).
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
- **Top-left:** 64×64 circular **GPSSpeedPill** speedometer (VStack `speed` + `km/h`, red-orange when overspeeding with pulsing glow). Next to it: 38×38 **SpeedLimitSignBadge** (white circle, 4 pt red border, bold number or dimmed `"--"` — tap clears limit). Transient prohibitory advisories (`no_entry`, `no_cars`, `no_overtaking`) render as authentic Vietnam sign graphics next to badge.
- **Top-center:** Completely unobstructed (timestamp moved to bottom-right).
- **Top-right:** Consolidated **RuleWeatherPill** — GPS antenna icon → Divider → 2-line TT38 stack (Line 1: `TT38 • MIN Xm`, Line 2: tappable context-aware road-type toggle — e.g., `Khu dân cư • 2 chiều • 50/80` residential, `Cao tốc • Đôi • 60/90` expressway, `2 chiều • 50/80` normal) → Divider → LDWS indicator (cyan/orange/red/gray) → Divider → Weather button (`sun.max.fill` / `cloud.rain.fill`, localized, cycles Auto/Dry/Wet).
- **Bottom-left:** Distance card (progress bar, state text, calibration status).
- **Bottom-right:** `VStack(alignment: .trailing)` — live `dd/MM/yyyy HH:mm:ss` timestamp capsule (11 pt monospaced) above 3 circular action buttons: Screenshot (`camera.fill`), Eco Black HUD toggle (`leaf.fill`/`flame.fill`), Settings (`gearshape.fill`).
- **Display Theme:** Auto (3-tier: camera luminance → GPS astronomical sunrise/sunset → clock fallback), Day, Night.
- **HUD Mirror Mode:** Vertically flips the view for windshield reflection; sets screen brightness to maximum, restores on exit.
- **Eco Black HUD:** Replaces live video with black background to reduce power and heat.
- **Glass effect:** Ultra-thin material cards/pills with night-dim variant.
- **Screenshot capture:** Flash animation + composites live camera frame + HUD overlay into Photos library. **Fixed black background:** Captures HUD layer into transparent `UIImage` (`format.opaque = false`) via `UIGraphicsImageRendererFormat`, saves/restores `window.backgroundColor` and `rootViewController?.view.backgroundColor = .clear`, then composites `cameraImage` (aspectFill) + `hudImage`. **Silent auto-capture** (no flash/alert) on critical alerts and anomaly events via `debugCaptureTrigger`.
- Settings expose: Distance rule, calibration factor, hood offset, lane center offset, time headway, road condition, language (VI/EN), voice alerts, LDWS enable + speed threshold, display theme, mirror mode, Eco HUD, glass effect, horizon guide, out-of-lane vehicles, mount calibration save/reset.
- **TSR Settings:** "Speed Sign Recognition" toggle (default on) + "Overspeed tolerance" slider `0–10 km/h`.
- **Stop-and-Go Settings:** "Lead Vehicle Departure Alert" toggle (default on).
- **Diagnostics Settings:** "Auto-Capture Debug Snapshots" toggle (default on, persisted) — auto-captures silent screenshots on `oncoming_lane_suspect`, `oncoming_closing_speed_spike`, and critical alerts (shared 5 s cooldown).
- **DiagnosticsLogStore:** Persistent daily JSONL logging to `Documents/DriveAssistantLogs/DriveAssistant-yyyy-MM-dd.jsonl` (async append on serial background queue). In-memory ring buffer (5000 events) + `eventPublisher` PassthroughSubject for real-time observers. Export reads today's daily log if in-memory empty. `clear()` deletes all `.jsonl` files **after closing the active `FileHandle`** to prevent fd leaks on deleted inodes.
- **Anomaly event types:** `target_switched_iou`, `oncoming_lane_suspect`, `oncoming_closing_speed_spike`, `ldws_departure_alert`, `ldws_mode_changed`, `ldws_debug`, `overspeed_alert`, `stop_and_go_alert`, `mount_shifted`, `alert_state_changed` (with `state=warning/critical/clear` + `reason=ttc|distance_below_3.5m`), `tsr_yolo_detect`, `tsr_state`.

---

## Architecture

```text
DriveAssistant/
├── DriveAssistant.xcodeproj
├── vn_adas_unified_ios16.mlpackage/    # Unified 86-class CoreML model (vehicles + Vietnam signs, ~15 MB)
└── DriveAssistant/
    ├── Assets.xcassets
    ├── Info.plist                      # Camera/location usage, landscape support, launch screen
    └── Sources/
        ├── DriveAssistantApp.swift     # SwiftUI app lifecycle and idle-timer control
        ├── DriveAssistantModel.swift   # Observable state, rule engine, EMA/TTC, alert decisions, theme, TSR/stop-and-go logic
        ├── CameraManager.swift         # Capture session, Vision inference, tracking, thermal guard, brightness, TSR gate
        ├── CameraPreview.swift         # AVCaptureVideoPreviewLayer-backed SwiftUI view
        ├── ContentView.swift           # HUD (GPSSpeedPill 64×64 circular, SpeedLimitSignBadge 38×38, RuleWeatherPill consolidated), lane carpet, horizon, TwoHousesView (ZStack), screenshot, timestamp bottom-right, controls
        ├── SettingsView.swift          # Runtime settings, mount calibration, diagnostics export/clear
        ├── LocationManager.swift       # When-in-use GPS speed/accuracy, astronomical night, weather trigger
        ├── WeatherService.swift        # Rate-limited Open-Meteo dry/wet lookup
        ├── AlertManager.swift          # Cooldowns, system sounds, Vietnamese speech, synthesized chimes (AVAudioEngine)
        ├── DiagnosticsLogStore.swift   # Persistent daily JSONL logging + in-memory ring buffer (5000), eventPublisher, export/clear
        ├── LaneDetector.swift          # CoreImage/Vision contour lane detection, local-contrast edge enhancement (CIUnsharpMask), linear fit, EMA, single-line synthesis, LDWS state machine, periodic ldws_debug
        ├── MotionManager.swift         # CMMotionManager gravity-vector attitude, mount profile, horizon calibration, mount-shift (2 s @ 3.5°)
        ├── RoadMetadataService.swift   # Overpass API (OSM) road-type lookup for TT38: oneway, dual_carriageway, lanes, maxspeed, landuse, admin_level=8
        └── TrafficSignDetector.swift   # Shared observations from unified model, hybrid YOLO+OCR, confirmation state, advisory badge
```

The app intentionally avoids a separate distance manager: `CameraManager` owns Vision and tracking outputs, `LaneDetector` owns lane geometry, `MotionManager` owns horizon alignment, `TrafficSignDetector` owns TSR (shared observations from unified model), `RoadMetadataService` owns OSM/TT38 logic, while `DriveAssistantModel` combines those outputs with GPS, road condition, settings, and alert state.

---

## Requirements

- macOS with **Xcode 14.0+**
- iPhone or iPad running **iOS 16.0+** (Neural Engine required for unified CoreML model)
- Camera and location permissions
- Internet only for automatic wet-road detection and OSM Overpass queries; the remainder of the pipeline works offline

CoreML model included in the repository and configured as target resource:
- `vn_adas_unified_ios16.mlpackage` — unified 86-class model (4 vehicles + 82 Vietnam signs, ~15 MB)

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
- **Code Coverage Report:** Step summary shows per-file coverage for `DriveAssistant.app` target only (clean table via `xcrun xccov view --files-for-target DriveAssistant.app`).

### Testing & Code Coverage
- **82 unit tests** across 5 suites: `BusinessLogicCoverageTests`, `LaneAndMotionTests`, `TT38AndTSRPrecedenceTests`, `TrafficSignDetectorProcessObservationsTests`, `VisionFixtureTests`.
- **Coverage: 61.13%** (4354/7122 lines) for `DriveAssistant.app` target.
- **Key coverage tests (`BusinessLogicCoverageTests`):**
  - `TC01`: Manual speed sign tap clear → reverts to TT38 statutory
  - `TC02`: 3-tier auto display theme fallback (camera → astronomical → clock)
  - `TC03`: Overspeed tolerance & cooldown boundaries
  - `TC04`: Stop-and-Go lead vehicle departure sequence
  - `TC05`: Vehicle distance formula & hood offset floor
  - `TC06`: WeatherService Open-Meteo JSON parsing (rain/drizzle/dry/malformed)
  - `TC07`: SettingsView renders all conditional sections (VI/EN, mount profile, TSR/LDWS toggles)
  - `TC08`: LocationManager indoor stationary, outdoor moving, inaccurate fix isolation
  - `TC09`: DiagnosticsLogStore record/export/clear with FileHandle leak fix + daily-log isolation
- **Test isolation:** `LaneAndMotionTests.setUp()` resets `MotionManager` `@AppStorage` profile to prevent cross-test pollution.

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
- TSR runs on full frame via unified CoreML; signs on far left, center gantry, or heavily occluded may be missed. Model trained on Vietnamese sign dataset; non-standard or heavily faded signs may not trigger.
- Diagnostics persist daily as JSONL (`DriveAssistant-yyyy-MM-dd.jsonl`) in `Documents/DriveAssistantLogs/`; export reads today's log if in-memory buffer empty. No automatic log rotation (manual clear from Settings).
- Weather-based wet mode depends on network availability and uses coarse Open-Meteo conditions rather than direct road-surface sensing.
- OSM Overpass queries depend on network; residential/TT38 fallback uses `nil` (unknown) state until first response completes.
- **GPS stall detection:** If GPS speed < `1 km/h` for `> 10 s` while moving previously, `isSpeedStalled` flags true (prevents stale speed from triggering false alerts).
- Thermal throttling reduces inference FPS; prolonged use in direct sun may pause detection entirely.
- HUD Mirror Mode requires a reflective windshield surface; brightness is set to maximum and restored on exit.
- Avoid public-road use until tracking, calibration, permissions, thermal behavior, and alert timing have been validated on a closed course.

---

## Disclaimer

DriveAssistant is a supplemental experimental aid for personal engineering use. It does not replace attentive driving, visual judgment, legal requirements, or vehicle safety systems. The authors do not guarantee correctness, availability, or fitness for safety-critical use. Always obey posted traffic signs and local road conditions.