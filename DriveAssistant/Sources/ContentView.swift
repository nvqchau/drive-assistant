import AVFoundation
import CoreLocation
import CoreMotion
import Photos
import SwiftUI
import UIKit

struct ContentView: View {
    @ObservedObject var model: DriveAssistantModel
    @State private var screenshotFlash = false
    @State private var screenshotSaved = false
    @State private var isCapturingScreenshot = false
    @State private var currentTimestamp = Date()
    @State private var timestampTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    private var activeStateColor: Color {
        switch model.alertState {
        case .normal: return Color(red: 0.0, green: 0.902, blue: 0.463)
        case .warning: return Color(red: 1.0, green: 0.769, blue: 0.0)
        case .critical: return Color(red: 1.0, green: 0.09, blue: 0.267)
        }
    }

    private func takeScreenshot(silent: Bool = false) {
        isCapturingScreenshot = true

        if !silent {
            // Flash screen
            withAnimation(.easeInOut(duration: 0.08)) { screenshotFlash = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                withAnimation(.easeInOut(duration: 0.15)) { screenshotFlash = false }
            }
        }

        // Allow SwiftUI to render CameraPreview hidden before capturing
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            // Capture the full screen (HUD overlay)
            guard let window = UIApplication.shared.connectedScenes
                .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else {
                isCapturingScreenshot = false
                return
            }

            let bounds = window.bounds
            let renderer = UIGraphicsImageRenderer(bounds: bounds)

            // First get the camera frame
            let cameraImage = model.camera.snapshotCameraImage()

            let composited = renderer.image { ctx in
                // 1. Draw camera image (aspectFill to match CameraPreview)
                if let camImg = cameraImage {
                    let videoSize = model.camera.cameraFrameSize
                    let scale = max(bounds.width / videoSize.width, bounds.height / videoSize.height)
                    let scaledVideoSize = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
                    let xOffset = (bounds.width - scaledVideoSize.width) / 2
                    let yOffset = (bounds.height - scaledVideoSize.height) / 2
                    camImg.draw(in: CGRect(x: xOffset, y: yOffset, width: scaledVideoSize.width, height: scaledVideoSize.height))
                }

                // 2. Draw the HUD overlay (window hierarchy) - skip CameraPreview black background
                window.drawHierarchy(in: bounds, afterScreenUpdates: true)
            }

            isCapturingScreenshot = false

            // Save to photo library
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                guard status == .authorized else { return }
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.creationRequestForAsset(from: composited)
                }) { success, _ in
                    if success && !silent {
                        DispatchQueue.main.async { screenshotSaved = true }
                    }
                }
            }
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let screenBox = model.camera.leadVehicleBox.map { screenRect(forVisionBox: $0, in: proxy.size) }
            ZStack {
                if model.ecoBlackHUD || model.hudMirrorMode {
                    Color.black
                } else if isCapturingScreenshot {
                    Color.clear
                } else {
                    CameraPreview(camera: model.camera)
                }

                if model.showHorizonGuide && model.motion.isActive {
                    HorizonOverlay(motion: model.motion)
                }

                LaneCarpet(cameraFrameSize: model.camera.cameraFrameSize, laneDetector: model.laneDetector, vehicleRect: screenBox, horizonY: model.motion.effectiveHorizonY, laneCenterOffsetX: model.laneCenterOffsetX, isLDWSEnabled: model.enableLaneDetection)

                if let screenBox {
                    VehicleTargetOverlay(screenRect: screenBox, distance: model.distance, color: activeStateColor)
                }

                // Out-of-ROI vehicles: subtle gray boxes (no alerts)
                if model.showOutOfROIVehicles {
                    ForEach(Array(model.camera.outOfROIVehicles.enumerated()), id: \.offset) { _, item in
                        let (box, conf, label) = item
                        let screenRect = screenRect(forVisionBox: box, in: proxy.size)
                        Rectangle()
                            .stroke(Color.gray.opacity(0.35), lineWidth: 1)
                            .frame(width: screenRect.width, height: screenRect.height)
                            .position(x: screenRect.midX, y: screenRect.midY)
                            .allowsHitTesting(false)
                    }
                }

                hud
            }
        }
        .background(Color.black)
        .ignoresSafeArea(.all)
        .scaleEffect(x: 1, y: model.hudMirrorMode ? -1 : 1)
        .sheet(isPresented: $model.isSettingsPresented) { SettingsView(model: model) }
        .statusBarHidden(true)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .overlay(alignment: .top) {
            if model.camera.cameraAuthorizationStatus == .denied || model.camera.cameraAuthorizationStatus == .restricted {
                CameraPermissionBanner()
            }
        }
        .overlay(alignment: .topTrailing) {
            if screenshotFlash {
                Color.white.opacity(0.3)
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
        }
        .alert("Screenshot saved", isPresented: $screenshotSaved) {
            Button("OK", role: .cancel) {}
        }
    }

    private func screenRect(forVisionBox box: CGRect, in screenSize: CGSize) -> CGRect {
        let videoSize = model.camera.cameraFrameSize
        let scale = max(screenSize.width / videoSize.width, screenSize.height / videoSize.height)
        let scaledVideoSize = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        let xOffset = (screenSize.width - scaledVideoSize.width) / 2
        let yOffset = (screenSize.height - scaledVideoSize.height) / 2
        let rawRect = CGRect(
            x: box.minX * videoSize.width,
            y: (1 - box.maxY) * videoSize.height,
            width: box.width * videoSize.width,
            height: box.height * videoSize.height
        )
        return CGRect(
            x: rawRect.minX * scale + xOffset,
            y: rawRect.minY * scale + yOffset,
            width: rawRect.width * scale,
            height: rawRect.height * scale
        )
    }

    private var hud: some View {
        GeometryReader { proxy in
            VStack {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            GPSSpeedPill(speed: model.speedKMPH, accuracy: model.gpsAccuracy, glassEnabled: model.glassHUD, nightDim: model.isNightThemeActive && !model.hudMirrorMode, isOverspeeding: model.isOverspeeding)
                            if model.enableSpeedSignRecognition {
                                HStack(spacing: 6) {
                                    VStack(spacing: 2) {
                                        SpeedLimitSignBadge(
                                            limit: model.detectedSpeedLimit,
                                            isOverspeeding: model.isOverspeeding,
                                            onTap: { model.camera.trafficSignDetector.clearDetectedLimit() }
                                        )
                                        // Speed limit cleared micro-badge (DP.134 / DP.135)
                                        if model.showSpeedLimitCleared {
                                            Text(model.usesVietnamese ? "Hết hạn chế" : "Limit ended")
                                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                                .foregroundColor(Color(red: 0.0, green: 0.902, blue: 0.463))  // Emerald
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.black.opacity(0.6), in: Capsule())
                                                .transition(.opacity.combined(with: .move(edge: .top)))
                                        }
                                    }
                                    // DP.135 (End of All Restrictions) indicator
                                    if model.showEndOfAllRestrictions {
                                        VStack(spacing: 2) {
                                            ZStack {
                                                Circle()
                                                    .fill(Color.white)
                                                    .frame(width: 38, height: 38)
                                                Circle()
                                                    .stroke(Color.gray, lineWidth: 4)
                                                    .frame(width: 38, height: 38)
                                                Image(systemName: "slash.circle.fill")
                                                    .font(.system(size: 18, weight: .bold))
                                                    .foregroundColor(.gray)
                                            }
                                            .frame(width: 38, height: 38)
                                            .shadow(color: Color.black.opacity(0.3), radius: 4)
                                            Text(model.usesVietnamese ? "Hết tất cả" : "All ended")
                                                .font(.system(size: 8, weight: .bold, design: .rounded))
                                                .foregroundColor(.gray)
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 1)
                                                .background(Color.black.opacity(0.5), in: Capsule())
                                        }
                                        .transition(.opacity.combined(with: .scale))
                                    }
                                    // Secondary advisory sign (localized from canonical keys) — red for prohibitory, blue for informational
                                    if let advisoryKey = model.activeAdvisorySignText {
                                        let isProhibitory = advisoryKey == "no_entry" || advisoryKey == "no_cars" || advisoryKey == "no_overtaking"
                                        let badgeColor: Color = isProhibitory ? .red : .blue
                                        let badgeIcon: String = isProhibitory ? "xmark.octagon.fill" : "house.fill"
                                        let advisoryText: String = {
                                            switch advisoryKey {
                                            case "no_entry":
                                                return model.usesVietnamese ? "Cấm ngược chiều" : "No Entry"
                                            case "no_cars":
                                                return model.usesVietnamese ? "Cấm ô tô" : "No Cars"
                                            case "no_overtaking":
                                                return model.usesVietnamese ? "Cấm vượt" : "No Overtaking"
                                            case "residential_area":
                                                return model.usesVietnamese ? "Khu dân cư" : "Residential Area"
                                            default:
                                                return advisoryKey
                                            }
                                        }()
                                        VStack(spacing: 2) {
                                            ZStack {
                                                RoundedRectangle(cornerRadius: 6)
                                                    .fill(badgeColor.opacity(0.15))
                                                    .frame(width: 38, height: 38)
                                                RoundedRectangle(cornerRadius: 6)
                                                    .stroke(badgeColor, lineWidth: 3)
                                                    .frame(width: 38, height: 38)
                                                Image(systemName: badgeIcon)
                                                    .font(.system(size: 16, weight: .bold))
                                                    .foregroundColor(badgeColor)
                                            }
                                            .frame(width: 38, height: 38)
                                            .shadow(color: Color.black.opacity(0.3), radius: 4)
                                            Text(advisoryText)
                                                .font(.system(size: 8, weight: .bold, design: .rounded))
                                                .foregroundColor(badgeColor)
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 1)
                                                .background(Color.black.opacity(0.5), in: Capsule())
                                        }
                                        .transition(.opacity.combined(with: .scale))
                                    }
                                }
                            }
                        }
                        ThermalBadge(state: model.camera.thermalState)
                    }
                    Spacer()
                    RuleWeatherPill(model: model, nightDim: model.isNightThemeActive && !model.hudMirrorMode)
                }
                .padding(.horizontal, 28)
                .padding(.top, 22)

                Spacer()

                // Live timestamp label (bottom-center, low-glare)
                HStack {
                    Spacer()
                    Text(timestampString)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.45), in: Capsule())
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    Spacer()
                }
                .padding(.bottom, 8)

                HStack(alignment: .bottom) {
                    DistanceCard(model: model, color: activeStateColor, nightDim: model.isNightThemeActive && !model.hudMirrorMode)
                    Spacer()
                    HStack(spacing: 10) {
                        Button { takeScreenshot() } label: {
                            Image(systemName: "camera.fill")
                                .foregroundColor(.white)
                                .font(.system(size: 20, weight: .semibold))
                                .frame(width: 50, height: 50)
                                .glassCircle(enabled: model.glassHUD)
                        }
                        Button { model.ecoBlackHUD.toggle() } label: {
                            Image(systemName: model.ecoBlackHUD ? "leaf.fill" : "flame.fill")
                                .foregroundColor(model.ecoBlackHUD ? .green : .white)
                                .font(.system(size: 20, weight: .semibold))
                                .frame(width: 50, height: 50)
                                .glassCircle(enabled: model.glassHUD)
                        }
                        Button { model.isSettingsPresented = true } label: {
                            Image(systemName: "gearshape.fill")
                                .foregroundColor(.white)
                                .font(.system(size: 20, weight: .semibold))
                                .frame(width: 50, height: 50)
                                .glassCircle(enabled: model.glassHUD)
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
            }
        }
        .ignoresSafeArea(.all)
        .onReceive(timestampTimer) { currentTimestamp = $0 }
        .onChange(of: model.debugCaptureTrigger) { trigger in
            if trigger != nil {
                takeScreenshot(silent: true)
            }
        }
    }

    private var timestampString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM/yyyy HH:mm:ss"
        return formatter.string(from: currentTimestamp)
    }

}

private struct CameraPermissionBanner: View {
    var body: some View {
        HStack {
            Image(systemName: "camera.fill")
                .font(.system(size: 16, weight: .semibold))
            Text("Camera access denied. Enable in Settings to use DriveAssistant.")
                .font(.system(size: 14, weight: .medium, design: .rounded))
            Spacer()
        }
        .foregroundColor(.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.red.opacity(0.9), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }
}

private struct GPSSpeedPill: View {
    let speed: Double
    let accuracy: CLLocationAccuracy
    let glassEnabled: Bool
    let nightDim: Bool
    let isOverspeeding: Bool

    private var signalColor: Color { accuracy >= 0 && accuracy < 20 ? .cyan : .gray }
    private var speedColor: Color { isOverspeeding ? Color(red: 1.0, green: 0.2, blue: 0.0) : .white }  // Red-orange when overspeeding

    var body: some View {
        HStack(spacing: 10) {

            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 21, weight: .bold))
                .foregroundColor(signalColor)
            Text(String(format: "%.0f", speed))
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(speedColor)
            Text("km/h")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundColor(speedColor.opacity(nightDim ? 0.78 : 0.82))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassCapsule(enabled: glassEnabled, nightDim: nightDim)
    }
}


private struct RuleWeatherPill: View {
    @ObservedObject var model: DriveAssistantModel
    let nightDim: Bool

    var body: some View {
        Button(action: model.cycleRoadCondition) {
            HStack(spacing: 10) {
                Text(model.distanceRuleMode == .vnLaw ? "TT38 • MIN \(String(format: "%.0f", model.activeMinimumDistance))m" : "MIN \(String(format: "%.0f", model.activeMinimumDistance))m")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                Divider().frame(height: 20).overlay(Color.white.opacity(nightDim ? 0.27 : 0.35))
                
                // LDWS status indicator (compact)
                if model.enableLaneDetection && (model.laneDetector.isLaneDetectionActive || model.laneDetector.isSpeedGated) {
                    VStack(spacing: 1) {
                        Image(systemName: "road.lanes")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(ldwsStatusColor)
                        Text("LDWS")
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundColor(ldwsStatusColor)
                    }
                    Divider().frame(height: 20).overlay(Color.white.opacity(nightDim ? 0.27 : 0.35))
                }
                
                VStack(spacing: 1) {
                    Image(systemName: weatherIcon)
                        .font(.system(size: 13, weight: .semibold))
                    Text(weatherText)
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                }
            }
            .foregroundColor(.white.opacity(nightDim ? 0.78 : 1.0))
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .glassCapsule(enabled: model.glassHUD, nightDim: nightDim)
        }
        .buttonStyle(.plain)
    }

    private var ldwsStatusColor: Color {
        if model.laneDetector.isSpeedGated {
            return .gray
        }
        switch model.laneDetector.departureState {
        case .driftingLeft, .driftingRight:
            return model.laneDetector.departureAlertActive ? .red : .orange
        case .none:
            return .cyan
        }
    }

    private var weatherText: String {
        if model.usesVietnamese {
            switch model.roadCondition {
            case .auto: return "Tự động"
            case .dry: return "Nắng"
            case .wet: return "Mưa"
            }
        } else {
            switch model.roadCondition {
            case .auto: return "Auto"
            case .dry: return "Dry"
            case .wet: return "Wet"
            }
        }
    }

    private var weatherIcon: String { model.effectiveRoadCondition == .wet ? "cloud.rain.fill" : "sun.max.fill" }
}

// MARK: - Vietnam Speed Limit Sign Badge (TSR)
private struct SpeedLimitSignBadge: View {
    let limit: Int?
    let isOverspeeding: Bool
    let onTap: () -> Void

    @State private var pulse = false

    var body: some View {
        ZStack {
            // White circle background
            Circle()
                .fill(Color.white)
                .frame(width: 38, height: 38)

            // Red border (Vietnam speed limit sign style)
            Circle()
                .stroke(Color.red, lineWidth: 4)
                .frame(width: 38, height: 38)

            // Speed limit number or "--"
            Text(limit.map { String($0) } ?? "--")
                .font(.system(size: 16, weight: .black, design: .rounded))
                .foregroundColor(limit == nil ? .gray.opacity(0.5) : .black)
                .monospacedDigit()

            // Red glow pulse when overspeeding
            if isOverspeeding {
                Circle()
                    .stroke(Color.red, lineWidth: 3)
                    .frame(width: 46, height: 46)
                    .scaleEffect(pulse ? 1.15 : 1.0)
                    .opacity(pulse ? 0.3 : 0.7)
                    .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: pulse)
                    .onAppear { pulse = true }
            }
        }
        .frame(width: 38, height: 38)
        .contentShape(Circle())
        .onTapGesture(perform: onTap)
        .shadow(color: isOverspeeding ? Color.red.opacity(0.6) : Color.black.opacity(0.3), radius: isOverspeeding ? 8 : 4)
    }
}

private struct DistanceCard: View {
    @ObservedObject var model: DriveAssistantModel
    let color: Color
    let nightDim: Bool

    private var progress: Double {
        guard let distance = model.distance else { return 0 }
        return min(max(distance / max(model.activeMinimumDistance * 1.5, 1), 0), 1)
    }

    private var statusText: String {
        if model.usesVietnamese {
            switch model.alertState {
            case .normal: return "Đủ khoảng cách"
            case .warning: return "Thiếu khoảng cách"
            case .critical: return "Quá gần"
            }
        } else {
            switch model.alertState {
            case .normal: return "Safe gap"
            case .warning: return "Gap closing"
            case .critical: return "Too close"
            }
        }
    }

    // Calibration status text for HUD
    private var calibrationStatusText: String? {
        let motion = model.motion
        if motion.isMountShifted {
            return model.usesVietnamese ? "⚠ Máy bị xê dịch" : "⚠ Mount shifted"
        } else if !motion.isAutoCalibrated && model.speedKMPH > 25 {
            return model.usesVietnamese ? "Đang tự hiệu chỉnh \(motion.calibrationProgress)%" : "Auto-calibrating \(motion.calibrationProgress)%"
        }
        return nil
    }

    private var calibrationStatusColor: Color {
        if model.motion.isMountShifted {
            return .orange
        }
        return .cyan
    }

    // Stop-and-Go alert status (emerald when active)
    private var stopAndGoStatusText: String? {
        guard model.isLeadVehicleMovingAlertActive else { return nil }
        return model.usesVietnamese ? "Xe trước đã di chuyển" : "Lead vehicle moving"
    }

    private var stopAndGoStatusColor: Color {
        Color(red: 0.0, green: 0.902, blue: 0.463)  // Emerald
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .lastTextBaseline, spacing: 7) {
                Text(model.distance.map { String(format: "%.0f", $0) } ?? "--")
                    .font(.system(size: 54, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(.white)
                Text("m")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.9))
            }
            Text(statusText)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(color)
            SegmentedProgressBar(progress: progress, color: color, activeMinimumDistance: model.activeMinimumDistance)

            // Calibration status indicator (only when relevant)
            if let statusText = calibrationStatusText {
                Text(statusText)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(calibrationStatusColor)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Stop-and-Go alert status
            if let statusText = stopAndGoStatusText {
                Text(statusText)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(stopAndGoStatusColor)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(18)
        .frame(width: 245, alignment: .leading)
        .glassCard(cornerRadius: 20, enabled: model.glassHUD, nightDim: nightDim)
        .animation(.easeInOut(duration: 0.3), value: calibrationStatusText)
        .animation(.easeInOut(duration: 0.3), value: stopAndGoStatusText)
    }
}

private struct SegmentedProgressBar: View {
    let progress: Double
    let color: Color
    let activeMinimumDistance: Double

    private var thresholdRatio: Double {
        activeMinimumDistance / (activeMinimumDistance * 1.5)
    }

    var body: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 4
            let segmentWidth = (proxy.size.width - spacing * 9) / 10
            ZStack(alignment: .leading) {
                HStack(spacing: spacing) {
                    ForEach(0..<10, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Double(index) / 10 < progress ? color : Color.white.opacity(0.20))
                            .frame(width: segmentWidth, height: 6)
                    }
                }
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: 14)
                    .offset(x: proxy.size.width * thresholdRatio - 1)
            }
        }
        .frame(height: 14)
    }
}

private struct LaneCarpet: View {
    let cameraFrameSize: CGSize
    @ObservedObject var laneDetector: LaneDetector
    let vehicleRect: CGRect?
    let horizonY: Double
    let laneCenterOffsetX: Double
    let isLDWSEnabled: Bool

    var body: some View {
        GeometryReader { proxy in
            let canvasSize = proxy.size
            
            // Use dynamic lanes if detected with good confidence, else static fallback
            let (leftPath, rightPath, fillPath, leftColor, rightColor, showLeftAlert, showRightAlert) = buildLanePaths(canvasSize: canvasSize, cameraFrameSize: cameraFrameSize)
            
            ZStack {
                // Interior fill
                fillPath
                    .fill(
                        LinearGradient(
                            colors: [.cyan.opacity(0.08), .cyan.opacity(0.0)],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                
                // Left lane line - color based on state: cyan (normal) -> amber (drifting) -> red (alert)
                leftPath
                    .stroke(
                        LinearGradient(
                            colors: [leftColor.opacity(0.55), leftColor.opacity(0.0)],
                            startPoint: .bottom,
                            endPoint: .top
                        ),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                    )
                
                // Right lane line
                rightPath
                    .stroke(
                        LinearGradient(
                            colors: [rightColor.opacity(0.55), rightColor.opacity(0.0)],
                            startPoint: .bottom,
                            endPoint: .top
                        ),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                    )
                
                // Departure pulsing alert on crossed rail
                if showLeftAlert {
                    leftPath
                        .stroke(Color.red.opacity(0.9), style: StrokeStyle(lineWidth: 5, lineCap: .round, dash: [6, 3]))
                        .animation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true), value: laneDetector.departureAlertActive)
                }
                if showRightAlert {
                    rightPath
                        .stroke(Color.red.opacity(0.9), style: StrokeStyle(lineWidth: 5, lineCap: .round, dash: [6, 3]))
                        .animation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true), value: laneDetector.departureAlertActive)
                }
            }
        }
        .ignoresSafeArea(.all)
        .allowsHitTesting(false)
    }
    
        private func buildLanePaths(canvasSize: CGSize, cameraFrameSize: CGSize) -> (left: Path, right: Path, fill: Path, leftColor: Color, rightColor: Color, showLeftAlert: Bool, showRightAlert: Bool) {
        var leftPath = Path()
        var rightPath = Path()
        var fillPath = Path()
        
        let hasDynamicLanes = laneDetector.isLaneDetectionActive &&
                              laneDetector.leftLaneConfidence > 0.5 &&
                              laneDetector.rightLaneConfidence > 0.5 &&
                              !laneDetector.leftLanePoints.isEmpty &&
                              !laneDetector.rightLanePoints.isEmpty
        
        // Determine colors based on departure state
        let leftColor: Color
        let rightColor: Color
        let showLeftAlert: Bool
        let showRightAlert: Bool
        
        switch laneDetector.departureState {
        case .driftingLeft:
            leftColor = .orange
            rightColor = .cyan
            showLeftAlert = laneDetector.departureAlertActive
            showRightAlert = false
        case .driftingRight:
            leftColor = .cyan
            rightColor = .orange
            showLeftAlert = false
            showRightAlert = laneDetector.departureAlertActive
        case .none:
            leftColor = .cyan
            rightColor = .cyan
            showLeftAlert = false
            showRightAlert = false
        }
        
        // Clip lane carpet at lead vehicle's bottom edge (rear bumper)
        let horizonTopY = canvasSize.height * horizonY
        let bottomY = canvasSize.height
        let effectiveTopY = vehicleRect.map { max(horizonTopY, min(bottomY, $0.maxY)) } ?? horizonTopY
        
        if hasDynamicLanes {
            // Aspect-fill transform matching screenRect(forVisionBox:in:)
            let videoSize = cameraFrameSize
            let scale = max(canvasSize.width / videoSize.width, canvasSize.height / videoSize.height)
            let scaledVideoSize = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
            let xOffset = (canvasSize.width - scaledVideoSize.width) / 2
            let yOffset = (canvasSize.height - scaledVideoSize.height) / 2
            func transformPoint(_ pt: CGPoint) -> CGPoint {
                // pt is normalized (0..1) top-left origin from LaneDetector
                // Convert directly to raw video pixel coordinates (no Y-flip needed)
                let rawX = pt.x * videoSize.width
                let rawY = pt.y * videoSize.height
                // Apply aspect-fill scale and offset
                return CGPoint(x: rawX * scale + xOffset, y: rawY * scale + yOffset)
            }

            var leftPoints = laneDetector.leftLanePoints.map(transformPoint)
            var rightPoints = laneDetector.rightLanePoints.map(transformPoint)

            // Clip dynamic curved rails to effectiveTopY (interpolate at boundary)
            leftPoints = clipPointsToY(leftPoints, minY: effectiveTopY)
            rightPoints = clipPointsToY(rightPoints, minY: effectiveTopY)

            if !leftPoints.isEmpty && !rightPoints.isEmpty {
                leftPath.move(to: leftPoints[0])
                for i in 1..<leftPoints.count {
                    leftPath.addLine(to: leftPoints[i])
                }

                rightPath.move(to: rightPoints[0])
                for i in 1..<rightPoints.count {
                    rightPath.addLine(to: rightPoints[i])
                }

                fillPath.move(to: leftPoints[0])
                for point in leftPoints { fillPath.addLine(to: point) }
                for point in rightPoints.reversed() { fillPath.addLine(to: point) }
                fillPath.closeSubpath()

                return (leftPath, rightPath, fillPath, leftColor, rightColor, showLeftAlert, showRightAlert)
            }
            // Fallback to static if clipping leaves nothing
        }

        // Static fallback trapezoid in NORMALIZED VIDEO SPACE (0..1, top-left origin)
        // Matches CameraManager.isInsideForwardLaneROI static ROI and model.laneCenterOffsetX
        let videoSize = cameraFrameSize
        let scale = max(canvasSize.width / videoSize.width, canvasSize.height / videoSize.height)
        let scaledVideoSize = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        let xOffset = (canvasSize.width - scaledVideoSize.width) / 2
        let yOffset = (canvasSize.height - scaledVideoSize.height) / 2

        func projectNorm(_ norm: CGPoint) -> CGPoint {
            let rawX = norm.x * videoSize.width
            let rawY = norm.y * videoSize.height
            return CGPoint(x: rawX * scale + xOffset, y: rawY * scale + yOffset)
        }

        let centerXNorm = 0.5 + laneCenterOffsetX
        let horizonTopYNorm = max(0.25, min(0.65, horizonY))
        let bottomYNorm = 0.95
        let topWidthNorm = 0.16
        let bottomWidthNorm = 0.42

        // Compute effectiveTopY in normalized video space (clip at lead vehicle bottom)
        let effectiveTopYNorm: CGFloat
        if let vRect = vehicleRect {
            // Convert screen vehicleRect.maxY back to normalized video Y
            let rawY = (vRect.maxY - yOffset) / scale
            let normY = rawY / videoSize.height
            effectiveTopYNorm = max(horizonTopYNorm, min(bottomYNorm, normY))
        } else {
            effectiveTopYNorm = horizonTopYNorm
        }

        // Interpolate top width at effectiveTopYNorm to preserve true perspective angle
        let totalHeightNorm = bottomYNorm - horizonTopYNorm
        let tNorm = totalHeightNorm > 0 ? (effectiveTopYNorm - horizonTopYNorm) / totalHeightNorm : 0
        let clippedTopWidthNorm = topWidthNorm + (bottomWidthNorm - topWidthNorm) * tNorm

        // Four corners in normalized video space
        let leftTopNorm = CGPoint(x: centerXNorm - clippedTopWidthNorm / 2, y: effectiveTopYNorm)
        let rightTopNorm = CGPoint(x: centerXNorm + clippedTopWidthNorm / 2, y: effectiveTopYNorm)
        let leftBottomNorm = CGPoint(x: centerXNorm - bottomWidthNorm / 2, y: bottomYNorm)
        let rightBottomNorm = CGPoint(x: centerXNorm + bottomWidthNorm / 2, y: bottomYNorm)

        // Project all corners through aspect-fill transform
        let leftTop = projectNorm(leftTopNorm)
        let rightTop = projectNorm(rightTopNorm)
        let leftBottom = projectNorm(leftBottomNorm)
        let rightBottom = projectNorm(rightBottomNorm)

        leftPath.move(to: leftBottom)
        leftPath.addLine(to: leftTop)

        rightPath.move(to: rightTop)
        rightPath.addLine(to: rightBottom)

        fillPath.move(to: leftTop)
        fillPath.addLine(to: rightTop)
        fillPath.addLine(to: rightBottom)
        fillPath.addLine(to: leftBottom)
        fillPath.closeSubpath()

        return (leftPath, rightPath, fillPath, leftColor, rightColor, showLeftAlert, showRightAlert)
    }
    
    // Clip a point array to y >= minY, interpolating the exact crossing point
    private func clipPointsToY(_ points: [CGPoint], minY: CGFloat) -> [CGPoint] {
        guard points.count >= 2 else { return points }
        var result: [CGPoint] = []
        for i in 0..<points.count - 1 {
            let p1 = points[i]
            let p2 = points[i + 1]
            let y1 = p1.y
            let y2 = p2.y
            
            if y1 >= minY && y2 >= minY {
                // Both below clip line — keep p1 (p2 will be handled next iteration or as last)
                if i == 0 { result.append(p1) }
            } else if y1 < minY && y2 >= minY {
                // Crossing from above to below — add interpolated point at minY
                let t = (minY - y1) / (y2 - y1)
                let x = p1.x + (p2.x - p1.x) * t
                result.append(CGPoint(x: x, y: minY))
            } else if y1 >= minY && y2 < minY {
                // Crossing from below to above — add p1 and interpolated point
                if i == 0 { result.append(p1) }
                let t = (minY - y1) / (y2 - y1)
                let x = p1.x + (p2.x - p1.x) * t
                result.append(CGPoint(x: x, y: minY))
            }
            // Both above — skip
        }
        // Ensure last point if it's below clip line
        if let last = points.last, last.y >= minY, result.last?.x != last.x || result.last?.y != last.y {
            result.append(last)
        }
        return result
    }
}

private struct LaneCarpetShape: Shape {
    let vehicleRect: CGRect?
    let canvasSize: CGSize
    let horizonY: Double

    func path(in rect: CGRect) -> Path {
        let topY = vehicleRect?.maxY ?? canvasSize.height * horizonY
        let topWidth = vehicleRect?.width ?? canvasSize.width * 0.12
        let topCenter = vehicleRect?.midX ?? canvasSize.width / 2
        let bottomY = canvasSize.height
        let bottomWidth = canvasSize.width * 0.36
        return Path { path in
            path.move(to: CGPoint(x: topCenter - topWidth / 2, y: topY))
            path.addLine(to: CGPoint(x: topCenter + topWidth / 2, y: topY))
            path.addLine(to: CGPoint(x: canvasSize.width / 2 + bottomWidth / 2, y: bottomY))
            path.addLine(to: CGPoint(x: canvasSize.width / 2 - bottomWidth / 2, y: bottomY))
            path.closeSubpath()
        }
    }
}

private struct VehicleTargetOverlay: View {
    let screenRect: CGRect
    let distance: Double?
    let color: Color
    @State private var pulse = false

    var body: some View {
        GeometryReader { proxy in
            let tagX = min(max(screenRect.maxX + 6 + 24, 24), proxy.size.width - 24)
            let tagY = min(max(screenRect.minY - 12, 14), proxy.size.height - 14)
            BracketShape(screenRect: screenRect)
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .square, lineJoin: .round))
                .shadow(color: color.opacity(0.8), radius: 5)
                .overlay(alignment: .topLeading) {
                    if let distance {
                        Text(String(format: "%.0fm", distance))
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.black.opacity(0.62), in: Capsule())
                            .position(x: tagX, y: tagY)
                    }
                }
                .opacity(pulse ? 0.45 : 1)
                .animation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true), value: pulse)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) { pulse = true }
        }
        .allowsHitTesting(false)
    }
}

private struct ThermalBadge: View {
    let state: ProcessInfo.ThermalState

    var body: some View {
        if state == .serious || state == .critical {
            Label(state == .critical ? "AI PAUSED (COOLING)" : "Phone warm · AI 3 FPS", systemImage: "thermometer.high")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(.orange)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.55), in: Capsule())
        }
    }
}

private struct BracketShape: Shape {
    let screenRect: CGRect

    func path(in rect: CGRect) -> Path {
        let left = screenRect.minX
        let right = screenRect.maxX
        let top = screenRect.minY
        let bottom = screenRect.maxY
        let length = min(22, min(right - left, bottom - top) * 0.3)
        return Path { path in
            path.move(to: CGPoint(x: left, y: top + length)); path.addLine(to: CGPoint(x: left, y: top)); path.addLine(to: CGPoint(x: left + length, y: top))
            path.move(to: CGPoint(x: right - length, y: top)); path.addLine(to: CGPoint(x: right, y: top)); path.addLine(to: CGPoint(x: right, y: top + length))
            path.move(to: CGPoint(x: left, y: bottom - length)); path.addLine(to: CGPoint(x: left, y: bottom)); path.addLine(to: CGPoint(x: left + length, y: bottom))
            path.move(to: CGPoint(x: right - length, y: bottom)); path.addLine(to: CGPoint(x: right, y: bottom)); path.addLine(to: CGPoint(x: right, y: bottom - length))
        }
    }
}

private struct HorizonOverlay: View {
    @ObservedObject var motion: MotionManager
    
    private var levelColor: Color {
        (motion.isLevel || motion.isMountAligned) ? Color(red: 0.0, green: 0.902, blue: 0.463) : Color(red: 1.0, green: 0.769, blue: 0.0)
    }
    
    private var levelText: String {
        if motion.isMountAligned {
            return "MOUNT ALIGNED"
        } else if motion.isLevel {
            return "0.0° LEVEL"
        } else {
            return String(format: "R: %.1f° P: %.1f°", motion.deltaRoll, motion.deltaPitch)
        }
    }
    
    private var rollRadians: Double { motion.rollDegrees * .pi / 180 }
    
    private func makeLinePath(in size: CGSize) -> Path {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let horizonY = size.height * motion.effectiveHorizonY
        let lineLen = size.width * 1.2
        let halfLen = lineLen / 2
        let rollRad = rollRadians
        let dy = horizonY - center.y
        
        let rotCenterX = center.x - dy * sin(rollRad)
        let rotCenterY = center.y + dy * cos(rollRad)
        let dirX = cos(rollRad)
        let dirY = sin(rollRad)
        
        let startX = rotCenterX - dirX * halfLen
        let startY = rotCenterY - dirY * halfLen
        let endX = rotCenterX + dirX * halfLen
        let endY = rotCenterY + dirY * halfLen
        
        return Path { path in
            path.move(to: CGPoint(x: startX, y: startY))
            path.addLine(to: CGPoint(x: endX, y: endY))
        }
    }
    
    var body: some View {
        GeometryReader { proxy in
            let linePath = makeLinePath(in: proxy.size)
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            
            let horizonLine = linePath
                .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [12, 8], dashPhase: 0))
                .foregroundColor(levelColor)
                .shadow(color: levelColor.opacity(0.6), radius: 3)
            
            let centerText = Text(levelText)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundColor(levelColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.black.opacity(0.65), in: Capsule())
                .position(center)
            
            ZStack {
                horizonLine
                centerText
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea(.all)
    }
}

extension View {
    func glassCapsule(enabled: Bool, nightDim: Bool = false) -> some View {
        modifier(GlassBackgroundModifier(shape: Capsule(), isEnabled: enabled, nightDim: nightDim))
    }

    func glassCard(cornerRadius: CGFloat, enabled: Bool, nightDim: Bool = false) -> some View {
        modifier(GlassBackgroundModifier(shape: RoundedRectangle(cornerRadius: cornerRadius), isEnabled: enabled, nightDim: nightDim))
    }

    func glassCircle(enabled: Bool, nightDim: Bool = false) -> some View {
        modifier(GlassBackgroundModifier(shape: Circle(), isEnabled: enabled, nightDim: nightDim))
    }
}

private struct GlassBackgroundModifier<ShapeType: Shape>: ViewModifier {
    let shape: ShapeType
    let isEnabled: Bool
    let nightDim: Bool

    func body(content: Content) -> some View {
        content.background {
            if isEnabled {
                GlassSurface(shape: shape, nightDim: nightDim)
            } else {
                SolidSurface(shape: shape, nightDim: nightDim)
            }
        }
    }
}

private struct GlassSurface<ShapeType: Shape>: View {
    let shape: ShapeType
    let nightDim: Bool

    var body: some View {
        shape
            .fill(.ultraThinMaterial)
            .overlay(
                LinearGradient(
                    colors: [
                        Color.white.opacity(nightDim ? 0.15 : 0.22),
                        Color.white.opacity(nightDim ? 0.03 : 0.05),
                        Color.black.opacity(nightDim ? 0.10 : 0.07)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .clipShape(shape)
            )
            .overlay(
                shape
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(nightDim ? 0.30 : 0.45),
                                Color.white.opacity(nightDim ? 0.05 : 0.08),
                                Color.white.opacity(nightDim ? 0.15 : 0.22)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: Color.black.opacity(nightDim ? 0.20 : 0.16), radius: 10, x: 0, y: 5)
    }
}

private struct SolidSurface<ShapeType: Shape>: View {
    let shape: ShapeType
    let nightDim: Bool

    var body: some View {
        shape
            .fill(Color.black.opacity(nightDim ? 0.75 : 0.58))
            .overlay(shape.stroke(Color.white.opacity(nightDim ? 0.08 : 0.12), lineWidth: 1))
    }
}
