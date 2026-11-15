import SwiftUI
import UIKit

struct SettingsView: View {
    @ObservedObject var model: DriveAssistantModel
    @State private var exportURL: URL?
    @State private var isShareSheetPresented = false
    @State private var isClearConfirmationPresented = false

    var body: some View {
        NavigationView {
            Form {
                Section(model.usesVietnamese ? "Hiệu chỉnh" : "Calibration") {
                    Picker(model.usesVietnamese ? "Quy tắc khoảng cách" : "Distance rule", selection: $model.distanceRuleMode) {
                        Text(model.usesVietnamese ? "Luật VN (TT38)" : "VN Law (TT38)").tag(DistanceRuleMode.vnLaw)
                        Text(model.usesVietnamese ? "Thời gian bám (giây)" : "Time Headway (Seconds)").tag(DistanceRuleMode.timeHeadway)
                    }
                    .pickerStyle(.segmented)
                    VStack(alignment: .leading) { Text(model.usesVietnamese ? "Hệ số khoảng cách" : "Distance calibration factor"); Slider(value: $model.calibrationFactor, in: 0.80...2.20, step: 0.05); Text(String(format: "%.2f", model.calibrationFactor)).font(.caption.monospacedDigit()).foregroundColor(.secondary) }
                    if model.distanceRuleMode == .timeHeadway {
                        VStack(alignment: .leading) { Text(model.usesVietnamese ? "Thời gian an toàn" : "Safe time headway"); Slider(value: $model.timeHeadway, in: 1.5...4.0, step: 0.1); Text(String(format: "%.1f s", model.timeHeadway)).font(.caption.monospacedDigit()).foregroundColor(.secondary) }
                    } else {
                        Picker(model.usesVietnamese ? "Điều kiện đường" : "Road condition", selection: $model.roadCondition) {
                            Text(model.usesVietnamese ? "Tự động (Thời tiết)" : "Auto (Weather)").tag(RoadCondition.auto)
                            Text(model.usesVietnamese ? "Đường khô" : "Dry Road").tag(RoadCondition.dry)
                            Text(model.usesVietnamese ? "Mưa / Ướt" : "Rain / Wet").tag(RoadCondition.wet)
                        }
                        .pickerStyle(.segmented)
                    }
                }
                Section(model.usesVietnamese ? "Cảnh báo" : "Alerts") { Toggle(model.usesVietnamese ? "Cảnh báo bằng giọng nói" : "Voice alerts", isOn: $model.voiceAlertsEnabled) }
                Section(model.usesVietnamese ? "Giao diện" : "Interface") {
                    Picker(model.usesVietnamese ? "Ngôn ngữ" : "Language", selection: $model.usesVietnamese) { Text("Tiếng Việt").tag(true); Text("English").tag(false) }.pickerStyle(.segmented)
                    Toggle(model.usesVietnamese ? "HUD đen tiết kiệm" : "Eco Black HUD", isOn: $model.ecoBlackHUD)
                }
                Section(model.usesVietnamese ? "Chẩn đoán" : "Diagnostics") {
                    Button {
                        exportURL = model.exportDiagnostics()
                        isShareSheetPresented = true
                    } label: {
                        Label(model.usesVietnamese ? "Xuất nhật ký kiểm tra" : "Export diagnostics", systemImage: "square.and.arrow.up")
                    }
                    Text(model.usesVietnamese ? "Xuất sau khi đỗ xe. Tệp gồm dữ liệu phiên chạy và trạng thái camera." : "Export after parking. File contains drive-session and camera-state data.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button(role: .destructive) {
                        isClearConfirmationPresented = true
                    } label: {
                        Label(model.usesVietnamese ? "Xóa nhật ký" : "Clear logs", systemImage: "trash")
                    }
                }
            }
            .navigationTitle(model.usesVietnamese ? "Cài đặt nhanh" : "Quick Settings")
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button(model.usesVietnamese ? "Xong" : "Done") { model.isSettingsPresented = false } } }
        }
        .sheet(isPresented: $isShareSheetPresented) {
            if let exportURL {
                ActivityView(activityItems: [exportURL])
            }
        }
        .alert(model.usesVietnamese ? "Xóa nhật ký?" : "Clear logs?", isPresented: $isClearConfirmationPresented) {
            Button(model.usesVietnamese ? "Xóa" : "Clear", role: .destructive) {
                model.clearDiagnostics()
            }
            Button(model.usesVietnamese ? "Hủy" : "Cancel", role: .cancel) {}
        } message: {
            Text(model.usesVietnamese ? "Không thể khôi phục nhật ký hiện tại." : "Current logs cannot be restored.")
        }
    }
}

private struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ viewController: UIActivityViewController, context: Context) {}
}
