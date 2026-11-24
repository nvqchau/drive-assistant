import AVFoundation
import CoreLocation
import CoreMotion
import Photos
import SwiftUI
import UIKit

// MARK: - Authentic Vietnam Advisory Sign Graphics
private struct VietnamAdvisorySign: View {
    let advisoryKey: String
    let size: CGFloat = 38

    var body: some View {
        switch advisoryKey {
        case "no_entry":          // P.102 — Cấm ngược chiều
            ZStack {
                Circle()
                    .fill(Color.red)
                    .frame(width: size, height: size)
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 22, height: 6)
                    .cornerRadius(1.5)
            }
        case "no_cars":           // P.103a — Cấm ô tô
            ZStack {
                Circle()
                    .stroke(Color.red, lineWidth: 4)
                    .frame(width: size, height: size)
                    .background(Circle().fill(Color.white))
                Image(systemName: "car.fill")
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundColor(.black)
                Rectangle()
                    .fill(Color.red)
                    .frame(width: 34, height: 3.5)
                    .rotationEffect(.degrees(-45))
            }
        case "no_overtaking":     // P.125 — Cấm vượt
            ZStack {
                Circle()
                    .stroke(Color.red, lineWidth: 4)
                    .frame(width: size, height: size)
                    .background(Circle().fill(Color.white))
                HStack(spacing: 2) {
                    Image(systemName: "car.fill")
                        .font(.system(size: size * 0.38, weight: .bold))
                        .foregroundColor(.red)
                    Image(systemName: "car.fill")
                        .font(.system(size: size * 0.38, weight: .bold))
                        .foregroundColor(.black)
                }
                Rectangle()
                    .fill(Color.red)
                    .frame(width: 34, height: 3.5)
                    .rotationEffect(.degrees(-45))
            }
        case "residential_area":  // R.420 — Khu dân cư (authentic landscape blue rectangle 52x38)
            ZStack {
                // Outer blue landscape rectangle (52 x 38) matching SpeedLimitSignBadge height
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(red: 0.0, green: 0.35, blue: 0.85))  // Vietnam traffic sign blue
                    .frame(width: 52, height: 38)
                // White inner border (inset by 2pt on each side = 48 x 34)
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.white, lineWidth: 2)
                    .frame(width: 48, height: 34)
                // Authentic QCVN 41:2019 R.420 skyline silhouette
                VietnamResidentialSilhouette()
            }
        default:
            Circle()
                .fill(Color.gray.opacity(0.3))
                .frame(width: size, height: size)
                .overlay(
                    Text(advisoryKey)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white)
                )
        }
    }
}

// Authentic QCVN 41:2019 R.420 residential area sign silhouette — landscape 48x34 inner frame
private struct VietnamResidentialSilhouette: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width   // 48
            let h = geo.size.height  // 34
            let groundY = h * 0.84   // Continuous ground baseline

            ZStack {
                ApartmentBuildingView(w: w, h: h, groundY: groundY)
                TwoHousesView(w: w, h: h, groundY: groundY)
                GroundBaselineView(w: w, h: h, groundY: groundY)
            }
        }
        .frame(width: 48, height: 34)
    }
}

// MARK: - VietnamResidentialSilhouette Sub-Views

private struct ApartmentBuildingView: View {
    let w: CGFloat
    let h: CGFloat
    let groundY: CGFloat

    var body: some View {
        let aptLeft = w * 0.14
        let aptRight = w * 0.38
        let aptTopY = h * 0.18
        let aptBottomY = groundY

        ZStack {
            // Building body (flat roof)
            Path { path in
                path.addRect(CGRect(x: aptLeft, y: aptTopY, width: aptRight - aptLeft, height: aptBottomY - aptTopY))
            }
            .fill(Color.white)

            // 4 dark-blue rectangular windows in 2x2 grid
            ApartmentWindowsView(aptLeft: aptLeft, aptRight: aptRight, aptTopY: aptTopY, aptBottomY: aptBottomY)
        }
    }
}

private struct ApartmentWindowsView: View {
    let aptLeft: CGFloat
    let aptRight: CGFloat
    let aptTopY: CGFloat
    let aptBottomY: CGFloat

    var body: some View {
        let windowW = (aptRight - aptLeft) * 0.25
        let windowH = (aptBottomY - aptTopY) * 0.20
        let startX = aptLeft + (aptRight - aptLeft) * 0.15
        let startY = aptTopY + (aptBottomY - aptTopY) * 0.20
        let gapX = (aptRight - aptLeft) * 0.35
        let gapY = (aptBottomY - aptTopY) * 0.40

        Path { path in
            // Row 0, Col 0
            path.addRect(CGRect(x: startX, y: startY, width: windowW, height: windowH))
            // Row 0, Col 1
            path.addRect(CGRect(x: startX + gapX, y: startY, width: windowW, height: windowH))
            // Row 1, Col 0
            path.addRect(CGRect(x: startX, y: startY + gapY, width: windowW, height: windowH))
            // Row 1, Col 1
            path.addRect(CGRect(x: startX + gapX, y: startY + gapY, width: windowW, height: windowH))
        }
        .fill(Color(red: 0.0, green: 0.15, blue: 0.55))
    }
}

private struct TwoHousesView: View {
    let w: CGFloat
    let h: CGFloat
    let groundY: CGFloat

    var body: some View {
        let houseRegionLeft = w * 0.41
        let houseRegionRight = w * 0.86
        let houseRegionWidth = houseRegionRight - houseRegionLeft
        let houseWidth = houseRegionWidth / 2.0

        ZStack {
            PitchedRoofHouseView(
                xStart: houseRegionLeft,
                houseWidth: houseWidth,
                groundY: groundY,
                h: h
            )
            PitchedRoofHouseView(
                xStart: houseRegionLeft + houseWidth,
                houseWidth: houseWidth,
                groundY: groundY,
                h: h
            )
        }
    }
}

private struct PitchedRoofHouseView: View {
    let xStart: CGFloat
    let houseWidth: CGFloat
    let groundY: CGFloat
    let h: CGFloat

    var body: some View {
        let xMid = xStart + houseWidth * 0.5
        let xEnd = xStart + houseWidth
        let wallLeft = xStart + houseWidth * 0.12
        let wallRight = xEnd - houseWidth * 0.12
        let wallTopY = groundY - (groundY - h * 0.18) * 0.75
        let wallBottomY = groundY
        let peakY = wallTopY - houseWidth * 0.35
        let winSize = houseWidth * 0.18

        ZStack {
            // House: roof triangle + rectangular wall
            Path { path in
                path.move(to: CGPoint(x: wallLeft, y: wallTopY))
                path.addLine(to: CGPoint(x: xMid, y: peakY))
                path.addLine(to: CGPoint(x: wallRight, y: wallTopY))
                path.closeSubpath()
                path.addRect(CGRect(x: wallLeft, y: wallTopY, width: wallRight - wallLeft, height: wallBottomY - wallTopY))
            }
            .fill(Color.white)

            // Small dark-blue window (centered)
            Path { path in
                path.addRect(CGRect(x: xMid - winSize / 2, y: wallTopY + (wallBottomY - wallTopY) * 0.25 - winSize / 2, width: winSize, height: winSize))
            }
            .fill(Color(red: 0.0, green: 0.15, blue: 0.55))
        }
    }
}

private struct GroundBaselineView: View {
    let w: CGFloat
    let h: CGFloat
    let groundY: CGFloat

    var body: some View {
        Path { path in
            path.addRect(CGRect(x: 0, y: groundY, width: w, height: h - groundY))
        }
        .fill(Color.white)
    }
}

struct ContentView: View {
    @ObservedObject var model: DriveAssistantModel
    @State private var screenshotFlash = false
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
        // 1. Fetch camera image FIRST (may be nil if session not running)
        let cameraImage = model.camera.snapshotCameraImage()

        // 2. Only hide CameraPreview if we got a camera image; otherwise keep it visible
        isCapturingScreenshot = cameraImage != nil

        if !silent {
            // Flash screen
            withAnimation(.easeInOut(duration: 0.08)) { screenshotFlash = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                withAnimation(.easeInOut(duration: 0.15)) { screenshotFlash = false }
            }
            // Subtle haptic on manual capture — no modal alert
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }

        // 3. Wait 0.06s for SwiftUI to flush transparent background before compositing
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            guard let window = UIApplication.shared.connectedScenes
                .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else {
                isCapturingScreenshot = false
                return
            }

            let bounds = window.bounds

            // Save original backgrounds to restore after HUD capture
            let originalWindowBg = window.backgroundColor
            let originalRootViewBg = window.rootViewController?.view.backgroundColor

            // Force transparent backgrounds so HUD layer captures without black window background
            window.backgroundColor = .clear
            window.rootViewController?.view.backgroundColor = .clear

            // Capture HUD layer into transparent UIImage (opaque=false)
            let hudFormat = UIGraphicsImageRendererFormat()
            hudFormat.opaque = false
            hudFormat.scale = UIScreen.main.scale
            let hudRenderer = UIGraphicsImageRenderer(bounds: bounds, format: hudFormat)
            let hudImage = hudRenderer.image { ctx in
                window.layer.render(in: ctx.cgContext)
            }

            // Restore original backgrounds immediately
            window.backgroundColor = originalWindowBg
            window.rootViewController?.view.backgroundColor = originalRootViewBg

            // Composite camera + HUD into final opaque image
            let renderer = UIGraphicsImageRenderer(bounds: bounds)
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

                // 2. Draw HUD overlay on top (transparent background, no CameraPreview black)
                hudImage.draw(in: bounds)
            }

            isCapturingScreenshot = false

            // Save to photo library
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                guard status == .authorized else { return }
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.creationRequestForAsset(from: composited)
                }) { _, _ in }
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
        .background(isCapturingScreenshot ? Color.clear : Color.black)
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
                    // LEFT: Circular speedometer + SpeedLimitSignBadge (44x44) + transient prohibitory advisories
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            // Circular speedometer (64x64)
                            GPSSpeedPill(speed: model.speedKMPH, accuracy: model.gpsAccuracy, glassEnabled: model.glassHUD, nightDim: model.isNightThemeActive && !model.hudMirrorMode, isOverspeeding: model.isOverspeeding)

                            if model.enableSpeedSignRecognition {
                                HStack(spacing: 6) {
                                    // Speed limit sign badge (44x44)
                                    SpeedLimitSignBadge(
                                        limit: model.detectedSpeedLimit,
                                        isOverspeeding: model.isOverspeeding,
                                        onTap: { model.camera.trafficSignDetector.clearDetectedLimit() }
                                    )
                                    // Transient prohibitory advisory signs only (no_entry, no_cars, no_overtaking)
                                    if let advisoryKey = model.activeAdvisorySignText {
                                        let isProhibitory = advisoryKey == "no_entry" || advisoryKey == "no_cars" || advisoryKey == "no_overtaking"
                                        if isProhibitory {
                                            let badgeColor: Color = .red
                                            let advisoryText: String = {
                                                switch advisoryKey {
                                                case "no_entry": return model.usesVietnamese ? "Cấm ngược chiều" : "No Entry"
                                                case "no_cars": return model.usesVietnamese ? "Cấm ô tô" : "No Cars"
                                                case "no_overtaking": return model.usesVietnamese ? "Cấm vượt" : "No Overtaking"
                                                default: return advisoryKey
                                                }
                                            }()
                                            VStack(spacing: 2) {
                                                VietnamAdvisorySign(advisoryKey: advisoryKey)
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
                        }
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
                        ThermalBadge(state: model.camera.thermalState)
                    }

                    Spacer()
                    // Top-center timestamp
                    Text(timestampString)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundColor(.white.opacity(0.8))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.35), in: Capsule())
                    Spacer()

                    // RIGHT: Consolidated status pill
                    RuleWeatherPill(model: model, nightDim: model.isNightThemeActive && !model.hudMirrorMode)
                }
                .padding(.horizontal, 28)
                .padding(.top, 22)

                Spacer()

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
    private var speedColor: Color { isOverspeeding ? Color(red: 1.0, green: 0.2, blue: 0.0) : .white }
    private var borderColor: Color { isOverspeeding ? .red : .white.opacity(0.35) }

    var body: some View {
        ZStack {
            // Subtle border
            Circle()
                .stroke(borderColor, lineWidth: isOverspeeding ? 3 : 1.5)
                .frame(width: 64, height: 64)

            VStack(spacing: -2) {
                // Speed digits
                Text(String(format: "%.0f", speed))
                    .font(.system(size: 24, weight: .black, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(speedColor)
                    .minimumScaleFactor(0.75)
                    .lineLimit(1)
                    .frame(width: 52)
                // "km/h" label
                Text("km/h")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(speedColor.opacity(nightDim ? 0.78 : 0.82))
            }
        }
        .frame(width: 64, height: 64)
        .glassCircle(enabled: glassEnabled, nightDim: nightDim)
    }
}


private struct RuleWeatherPill: View {
    @ObservedObject var model: DriveAssistantModel
    let nightDim: Bool

    var body: some View {
        HStack(spacing: 0) {
            // GPS antenna icon
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(nightDim ? 0.78 : 1.0))
                .padding(.horizontal, 10)

            Divider().frame(height: 20).overlay(Color.white.opacity(nightDim ? 0.27 : 0.35))

            // R.420 sign when in residential area
            if model.isInResidentialArea == true {
                VietnamAdvisorySign(advisoryKey: "residential_area")
                    .frame(width: 24, height: 18)
                    .padding(.horizontal, 4)
                Divider().frame(height: 20).overlay(Color.white.opacity(nightDim ? 0.27 : 0.35))
            }

            // 2-line TT38 stack
            VStack(alignment: .leading, spacing: 0) {
                // Line 1: TT38•MIN Xm
                Text(model.distanceRuleMode == .vnLaw ? "TT38 • MIN \(String(format: "%.0f", model.displayMinimumDistance))m" : "MIN \(String(format: "%.0f", model.displayMinimumDistance))m")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(nightDim ? 0.78 : 1.0))
                // Line 2: Tappable "2 chiều•50/80" toggle
                Button(action: { model.location.roadMetadata.toggleDividedRoad() }) {
                    Text(model.usesVietnamese
                        ? (model.isDividedRoad ? "Đôi • 60/90" : "2 chiều • 50/80")
                        : (model.isDividedRoad ? "Divided • 60/90" : "2-Way • 50/80"))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(nightDim ? 0.65 : 0.85))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.blue.opacity(0.4), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)

            Divider().frame(height: 28).overlay(Color.white.opacity(nightDim ? 0.27 : 0.35))

            // LDWS indicator
            if model.enableLaneDetection && (model.laneDetector.isLaneDetectionActive || model.laneDetector.isSpeedGated) {
                VStack(spacing: 1) {
                    Image(systemName: "road.lanes")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(ldwsStatusColor)
                    Text("LDWS")
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .foregroundColor(ldwsStatusColor)
                }
                .padding(.horizontal, 8)
                Divider().frame(height: 28).overlay(Color.white.opacity(nightDim ? 0.27 : 0.35))
            }

            // Weather button wrapping only weather VStack
            Button(action: model.cycleRoadCondition) {
                VStack(spacing: 1) {
                    Image(systemName: weatherIcon)
                        .font(.system(size: 13, weight: .semibold))
                    Text(weatherText)
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                }
                .foregroundColor(.white.opacity(nightDim ? 0.78 : 1.0))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 7)
        .glassCapsule(enabled: model.glassHUD, nightDim: nightDim)
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
        let topWidthNorm = 0.14
        let bottomWidthNorm = 0.44

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
