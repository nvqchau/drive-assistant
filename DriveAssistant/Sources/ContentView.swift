import CoreLocation
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: DriveAssistantModel

    private var activeStateColor: Color {
        switch model.alertState {
        case .normal: return Color(red: 0.0, green: 0.902, blue: 0.463)
        case .warning: return Color(red: 1.0, green: 0.769, blue: 0.0)
        case .critical: return Color(red: 1.0, green: 0.09, blue: 0.267)
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let screenBox = model.camera.leadVehicleBox.map { screenRect(forVisionBox: $0, in: proxy.size) }
            ZStack {
                if model.ecoBlackHUD {
                    Color.black
                } else {
                    CameraPreview(camera: model.camera)
                }

                LaneCarpet(color: activeStateColor, vehicleRect: screenBox)

                if let screenBox {
                    VehicleTargetOverlay(screenRect: screenBox, distance: model.distance, color: activeStateColor)
                }

                hud
            }
        }
        .background(Color.black)
        .ignoresSafeArea(.all)
        .sheet(isPresented: $model.isSettingsPresented) { SettingsView(model: model) }
        .statusBarHidden(true)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
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
        GeometryReader { _ in
            VStack {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        GPSSpeedPill(speed: model.speedKMPH, accuracy: model.gpsAccuracy)
                        ThermalBadge(state: model.camera.thermalState)
                    }
                    Spacer()
                    RuleWeatherPill(model: model)
                }
                .padding(.horizontal, 28)
                .padding(.top, 22)

                Spacer()

                HStack(alignment: .bottom) {
                    DistanceCard(model: model, color: activeStateColor)
                    Spacer()
                    HStack(spacing: 10) {
                        Button { model.ecoBlackHUD.toggle() } label: {
                            Image(systemName: model.ecoBlackHUD ? "leaf.fill" : "flame.fill")
                                .foregroundColor(model.ecoBlackHUD ? .green : .white)
                                .font(.system(size: 20, weight: .semibold))
                                .frame(width: 50, height: 50)
                                .glassCircle()
                        }
                        Button { model.isSettingsPresented = true } label: {
                            Image(systemName: "gearshape.fill")
                                .foregroundColor(.white)
                                .font(.system(size: 20, weight: .semibold))
                                .frame(width: 50, height: 50)
                                .glassCircle()
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
            }
        }
        .ignoresSafeArea(.all)
    }
}

private struct GPSSpeedPill: View {
    let speed: Double
    let accuracy: CLLocationAccuracy

    private var signalColor: Color { accuracy >= 0 && accuracy < 20 ? .cyan : .gray }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 21, weight: .bold))
                .foregroundColor(signalColor)
            Text(String(format: "%.0f", speed))
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(.white)
            Text("km/h")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.82))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassCapsule()
    }
}

private struct RuleWeatherPill: View {
    @ObservedObject var model: DriveAssistantModel

    var body: some View {
        Button(action: model.cycleRoadCondition) {
            HStack(spacing: 10) {
                Text(model.distanceRuleMode == .vnLaw ? "TT38 • MIN \(String(format: "%.0f", model.activeMinimumDistance))m" : "MIN \(String(format: "%.0f", model.activeMinimumDistance))m")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                Divider().frame(height: 20).overlay(Color.white.opacity(0.35))
                VStack(spacing: 1) {
                    Image(systemName: weatherIcon)
                        .font(.system(size: 13, weight: .semibold))
                    Text(weatherText)
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                }
            }
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .glassCapsule()
        }
        .buttonStyle(.plain)
    }

    private var weatherText: String {
        switch model.roadCondition {
        case .auto: return "Auto"
        case .dry: return "Dry"
        case .wet: return "Wet"
        }
    }

    private var weatherIcon: String { model.effectiveRoadCondition == .wet ? "cloud.rain.fill" : "sun.max.fill" }
}

private struct DistanceCard: View {
    @ObservedObject var model: DriveAssistantModel
    let color: Color

    private var progress: Double {
        guard let distance = model.distance else { return 0 }
        return min(max(distance / max(model.activeMinimumDistance * 1.5, 1), 0), 1)
    }

    private var statusText: String {
        switch model.alertState {
        case .normal: return "SAFE GAP"
        case .warning: return "GAP CLOSING"
        case .critical: return "TOO CLOSE"
        }
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
            SegmentedProgressBar(progress: progress, color: color)
        }
        .padding(18)
        .frame(width: 245, alignment: .leading)
        .glassCard(cornerRadius: 20)
    }
}

private struct SegmentedProgressBar: View {
    let progress: Double
    let color: Color
    private let threshold = 2.0 / 3.0

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
                    .offset(x: proxy.size.width * threshold - 1)
            }
        }
        .frame(height: 14)
    }
}

private struct LaneCarpet: View {
    let color: Color
    let vehicleRect: CGRect?

    var body: some View {
        GeometryReader { proxy in
            let shape = LaneCarpetShape(vehicleRect: vehicleRect, canvasSize: proxy.size)
            shape
                .fill(LinearGradient(colors: [color.opacity(0.06), color.opacity(0.32)], startPoint: .top, endPoint: .bottom))
                .overlay(shape.stroke(color.opacity(0.72), style: StrokeStyle(lineWidth: 2, lineCap: .round)))
                .shadow(color: color.opacity(0.55), radius: 8)
        }
        .ignoresSafeArea(.all)
        .allowsHitTesting(false)
    }
}

private struct LaneCarpetShape: Shape {
    let vehicleRect: CGRect?
    let canvasSize: CGSize

    func path(in rect: CGRect) -> Path {
        let topY = vehicleRect?.maxY ?? canvasSize.height * 0.45
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
                .animation(.easeInOut(duration: 0.55), value: pulse)
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
                .background(Color.black.opacity(0.78), in: Capsule())
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

private extension View {
    func glassCapsule() -> some View {
        background(Color.black.opacity(0.60), in: Capsule())
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
    }

    func glassCard(cornerRadius: CGFloat) -> some View {
        background(Color.black.opacity(0.62), in: RoundedRectangle(cornerRadius: cornerRadius))
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(Color.white.opacity(0.16), lineWidth: 1))
    }

    func glassCircle() -> some View {
        background(Color.black.opacity(0.62), in: Circle())
            .background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 1))
    }
}
