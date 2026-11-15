# Role & Objective
Act as a **Principal iOS & Mobile Systems Engineer** specializing in real-time computer vision, AVFoundation camera pipelines, CoreML inference (`YOLOv3TinyInt8LUT`), CoreLocation, and SwiftUI architecture.

Your task is to perform a **comprehensive, production-readiness code and architecture review** of everything implemented so far in this repository (`drive-assistant`).

# Context & Execution Instructions
1. **Inspect the entire codebase first**: Read `AGENTS.md`, `README.md`, `Info.plist`, and all Swift source files under `DriveAssistant/Sources/` (`DriveAssistantApp.swift`, `DriveAssistantModel.swift`, `CameraManager.swift`, `CameraPreview.swift`, `AlertManager.swift`, `LocationManager.swift`, `WeatherService.swift`, `DiagnosticsLogStore.swift`, `ContentView.swift`, `SettingsView.swift`), as well as recent git history (`git log -n 10 --stat`) to understand what has been built up to now.
2. **Do NOT modify any files yet**. Operate strictly in read-only audit mode and produce a structured engineering review report.

# Audit Dimensions (Evaluate Rigorously)
1. **Architecture & State Management**:
   - Separation of concerns across `DriveAssistantModel`, managers, and SwiftUI views.
   - Memory leaks, retain cycles (`[weak self]`), actor isolation, and Swift concurrency safety (`@MainActor`, `Sendable`, data races).
2. **Real-Time Camera & CoreML Pipeline (`CameraManager` + YOLO)**:
   - Frame dropping / backpressure handling (`alwaysDiscardsLateVideoFrames`), dispatch queue priorities, and thermal/battery throttling risks during continuous driving.
   - Input preprocessing, confidence/NMS thresholds, and edge cases in object detection.
3. **Safety-Critical Alerting (`AlertManager`)**:
   - False-positive suppression, alert cooldown/debouncing, audio session interruptions (e.g., navigation voice, phone calls, CarPlay/Bluetooth), and haptic/visual fallback reliability.
4. **Sensors, Networking & Privacy (`LocationManager`, `WeatherService`, `Info.plist`)**:
   - GPS accuracy/battery trade-offs, offline/poor-cellular resilience for weather APIs, required `Info.plist` usage descriptions, and background execution behavior.
5. **Diagnostics & Production Readiness (`DiagnosticsLogStore`)**:
   - Log rotation/disk bloat prevention, PII/location scrubbing, error handling (no silent failures or force-unwraps `!` in production paths), and testability.

# Required Output Format
Organize your review strictly into these sections:
1. **Executive Summary & Production Readiness Score (1–10)**: Brief assessment of current maturity and overall architectural health.
2. **Critical & High-Severity Issues (P0 / P1)**: Bugs, race conditions, memory leaks, or safety/reliability flaws that block real-world road testing. Include exact `File:Line` references, root cause, and concrete fix strategy.
3. **Medium & Low-Severity Improvements (P2 / P3)**: Performance optimizations, Swift idiom improvements, and maintainability refactoring.
4. **Missing Edge Cases & Hardening Checklist**: Scenarios likely to fail during actual driving (e.g., thermal throttling, permissions revoked mid-session, low light, network drop).
5. **Prioritized Action Plan (Next 3 Milestones)**: Ordered list of concrete tasks we should execute next, starting with highest impact/lowest risk.