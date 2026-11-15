import SwiftUI

struct ContentView: View {
    @ObservedObject var model: DriveAssistantModel

    var body: some View {
        ZStack {
            CameraPreview(camera: model.camera)
                .ignoresSafeArea(.all)
            LaneROIOverlay()
                .fill(Color.cyan.opacity(0.14))
                .overlay(LaneROIOverlay().stroke(Color.cyan.opacity(0.6), lineWidth: 1.5))
            if let box = model.camera.leadVehicleBox {
                VehicleTargetBrackets(box: box, state: model.alertState)
            }
            hud
        }
        .background(Color.black)
        .ignoresSafeArea(.all)
        .sheet(isPresented: $model.isSettingsPresented) { SettingsView(model: model) }
        .statusBarHidden(true)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private var hud: some View {
        GeometryReader { _ in
            ZStack {
                VStack {
                    HStack(alignment: .top) {
                        SpeedCard(speedKMPH: model.speedKMPH)
                        Spacer()
                        DistanceCard(model: model)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 22)
                    Spacer()
                    HStack {
                        Spacer()
                        Button { model.isSettingsPresented = true } label: {
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 52, height: 52)
                                .background(Color.black.opacity(0.65), in: Circle())
                                .background(.ultraThinMaterial, in: Circle())
                                .overlay(Circle().stroke(Color.white.opacity(0.22), lineWidth: 1))
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 24)
                }
                VStack {
                    StatusPill(model: model).padding(.top, 22)
                    Spacer()
                }
            }
        }
        .ignoresSafeArea(.all)
    }
}

private struct SpeedCard: View {
    let speedKMPH: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("DRIVE ASSISTANT").font(.caption.weight(.bold)).foregroundColor(.white.opacity(0.72))
            HStack(alignment: .lastTextBaseline, spacing: 7) {
                Text(String(format: "%.0f", speedKMPH)).font(.system(size: 48, weight: .bold, design: .rounded)).monospacedDigit().foregroundColor(.white)
                Text("km/h").font(.system(size: 18, weight: .bold, design: .rounded)).foregroundColor(.white.opacity(0.9))
                Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 17, weight: .semibold)).foregroundColor(.green)
            }
        }
        .padding(14)
        .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 16))
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.15), lineWidth: 1))
    }
}

private struct StatusPill: View {
    @ObservedObject var model: DriveAssistantModel
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(stateColor).frame(width: 9, height: 9)
            Text(stateText).font(.system(size: 16, weight: .bold, design: .rounded))
            Text("•").foregroundColor(.white.opacity(0.7))
            Text(metricText).font(.system(size: 16, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        .foregroundColor(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Color.black.opacity(0.65), in: Capsule())
        .background(.ultraThinMaterial, in: Capsule())
    }
    private var stateText: String {
        switch model.alertState { case .normal: return "SAFE"; case .warning: return "CAUTION"; case .critical: return "BRAKE" }
    }
    private var metricText: String {
        if let ttc = model.timeToCollision { return String(format: "%.1fs", ttc) }
        return String(format: "%.1fs", model.timeHeadway)
    }
    private var stateColor: Color {
        switch model.alertState { case .normal: return .green; case .warning: return .yellow; case .critical: return .red }
    }
}

private struct DistanceCard: View {
    @ObservedObject var model: DriveAssistantModel
    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Text(model.distance.map { String(format: "%.0f m", $0) } ?? "-- m")
                .font(.system(size: 48, weight: .bold, design: .rounded)).monospacedDigit().foregroundColor(stateColor)
            Button(action: model.cycleRoadCondition) {
                Label(ruleText, systemImage: weatherIcon)
                    .font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundColor(.white)
                    .padding(.horizontal, 11).padding(.vertical, 7).background(Color.white.opacity(0.15), in: Capsule())
            }
        }
        .padding(14)
        .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 16))
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.15), lineWidth: 1))
    }
    private var ruleText: String {
        let mode = model.roadCondition == .auto ? "Auto" : model.roadCondition == .wet ? "Wet" : "Dry"
        let prefix = model.distanceRuleMode == .vnLaw ? "TT38 Min" : "Min"
        return "\(prefix): \(String(format: "%.0f", model.activeMinimumDistance))m  \(mode)"
    }
    private var weatherIcon: String { model.effectiveRoadCondition == .wet ? "cloud.rain.fill" : "sun.max.fill" }
    private var stateColor: Color {
        switch model.alertState { case .normal: return Color(red: 0, green: 0.902, blue: 0.463); case .warning: return Color(red: 1, green: 0.769, blue: 0); case .critical: return Color(red: 1, green: 0.09, blue: 0.267) }
    }
}

private struct LaneROIOverlay: Shape {
    func path(in rect: CGRect) -> Path {
        let topY = rect.minY + rect.height * 0.38
        let bottomY = rect.minY + rect.height * 0.95
        return Path { path in
            path.move(to: CGPoint(x: rect.minX + rect.width * 0.38, y: topY))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.62, y: topY))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.80, y: bottomY))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.20, y: bottomY))
            path.closeSubpath()
        }
    }
}

private struct VehicleTargetBrackets: View {
    let box: CGRect
    let state: ADASAlertState
    @State private var pulse = false
    var body: some View {
        GeometryReader { proxy in
            BracketShape(box: box, containerSize: proxy.size)
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .square, lineJoin: .round))
                .opacity(state == .critical && pulse ? 0.45 : 1)
                .scaleEffect(state == .critical && pulse ? 1.04 : 1)
                .animation(.easeInOut(duration: 0.55), value: pulse)
        }
        .onAppear {
            guard state == .critical else { return }
            withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
    private var color: Color {
        switch state { case .normal: return Color(red: 0, green: 0.902, blue: 0.463); case .warning: return Color(red: 1, green: 0.769, blue: 0); case .critical: return Color(red: 1, green: 0.09, blue: 0.267) }
    }
}

private struct BracketShape: Shape {
    let box: CGRect
    let containerSize: CGSize
    func path(in rect: CGRect) -> Path {
        let left = box.minX * containerSize.width
        let right = box.maxX * containerSize.width
        let top = (1 - box.maxY) * containerSize.height
        let bottom = (1 - box.minY) * containerSize.height
        let length = min(22, min(right - left, bottom - top) * 0.3)
        return Path { path in
            path.move(to: CGPoint(x: left, y: top + length)); path.addLine(to: CGPoint(x: left, y: top)); path.addLine(to: CGPoint(x: left + length, y: top))
            path.move(to: CGPoint(x: right - length, y: top)); path.addLine(to: CGPoint(x: right, y: top)); path.addLine(to: CGPoint(x: right, y: top + length))
            path.move(to: CGPoint(x: left, y: bottom - length)); path.addLine(to: CGPoint(x: left, y: bottom)); path.addLine(to: CGPoint(x: left + length, y: bottom))
            path.move(to: CGPoint(x: right - length, y: bottom)); path.addLine(to: CGPoint(x: right, y: bottom)); path.addLine(to: CGPoint(x: right, y: bottom - length))
        }
    }
}
