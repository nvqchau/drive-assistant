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
                    VStack(alignment: .leading) {
                        Text(model.usesVietnamese ? "Hệ số khoảng cách" : "Distance calibration factor")
                        Slider(value: $model.calibrationFactor, in: 0.50...2.00, step: 0.05)
                        Text(String(format: "%.2f", model.calibrationFactor)).font(.caption.monospacedDigit()).foregroundColor(.secondary)
                    }
                    VStack(alignment: .leading) {
                        Text(model.usesVietnamese ? "Độ dài mui xe (m)" : "Hood offset (m)")
                        Slider(value: $model.hoodOffsetMeters, in: 0.0...3.0, step: 0.1)
                        Text(String(format: "%.1f m", model.hoodOffsetMeters)).font(.caption.monospacedDigit()).foregroundColor(.secondary)
                    }
                    VStack(alignment: .leading) {
                        Text(model.usesVietnamese ? "Độ lệch làn đường" : "Lane center offset")
                        Slider(value: $model.laneCenterOffsetX, in: -0.15...0.15, step: 0.01)
                        Text(String(format: "%.2f", model.laneCenterOffsetX)).font(.caption.monospacedDigit()).foregroundColor(.secondary)
                    }
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
                
                Section(model.usesVietnamese ? "Cài đặt góc gắn" : "Mount Calibration") {
                    VStack(alignment: .leading, spacing: 8) {
                        if model.motion.hasSavedMountProfile {
                            HStack {
                                Text(model.usesVietnamese ? "Góc tham chiếu đã lưu" : "Saved reference angle")
                                Spacer()
                                Text(String(format: "Pitch: %.1f°  Roll: %.1f°", model.motion.calibratedPitch, model.motion.calibratedRoll))
                                    .font(.caption.monospacedDigit())
                                    .foregroundColor(.secondary)
                            }
                            HStack {
                                Text(model.usesVietnamese ? "Độ lệch hiện tại" : "Current delta")
                                Spacer()
                                Text(String(format: "ΔPitch: %.1f°  ΔRoll: %.1f°", model.motion.deltaPitch, model.motion.deltaRoll))
                                    .font(.caption.monospacedDigit())
                                    .foregroundColor(model.motion.isMountAligned ? .green : .orange)
                            }
                            Text(model.motion.isMountAligned ? (model.usesVietnamese ? "✓ Đã căn chỉnh" : "✓ Mount aligned") : (model.usesVietnamese ? "⚠ Cần căn chỉnh lại" : "⚠ Realignment needed"))
                                .font(.caption)
                                .foregroundColor(model.motion.isMountAligned ? .green : .orange)
                        } else {
                            Text(model.usesVietnamese ? "Chưa lưu góc gắn. Đặt iPhone vào giá, chọn \"Lưu góc gắn hiện tại\"." : "No mount angle saved. Place iPhone in mount, tap \"Save Current Mount Angle\".")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Button {
                            model.motion.saveCurrentMountAngle()
                        } label: {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                Text(model.motion.hasSavedMountProfile ? (model.usesVietnamese ? "Cập nhật góc gắn" : "Update Mount Angle") : (model.usesVietnamese ? "Lưu góc gắn hiện tại" : "Save Current Mount Angle"))
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.motion.isActive)
                        
                        if model.motion.hasSavedMountProfile {
                            Button(role: .destructive) {
                                model.motion.resetMountProfile()
                            } label: {
                                HStack {
                                    Image(systemName: "arrow.counterclockwise")
                                    Text(model.usesVietnamese ? "Xóa góc tham chiếu" : "Reset Mount Profile")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                
                Section(model.usesVietnamese ? "Cảnh báo" : "Alerts") {
                    Toggle(model.usesVietnamese ? "Cảnh báo bằng giọng nói" : "Voice alerts", isOn: $model.voiceAlertsEnabled)
                    Toggle(model.usesVietnamese ? "Nhắc xe trước di chuyển" : "Stop-and-Go Alert", isOn: $model.stopAndGoAlertEnabled)
                    Toggle(model.usesVietnamese ? "Nhận diện biển báo tốc độ" : "Speed Sign Recognition", isOn: $model.enableSpeedSignRecognition)

                    if model.enableSpeedSignRecognition {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(model.usesVietnamese ? "Dung sai vượt giới hạn: \(Int(model.overspeedToleranceKmh)) km/h" : "Overspeed tolerance: \(Int(model.overspeedToleranceKmh)) km/h")
                                .font(.subheadline)
                            Slider(value: $model.overspeedToleranceKmh, in: 0...10, step: 1)
                            Text(model.usesVietnamese ? "Cảnh báo khi vượt quá tốc độ biển báo + dung sai" : "Alert when exceeding sign speed + tolerance")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Section(model.usesVietnamese ? "Phát hiện làn đường" : "Lane Detection") {
                    Toggle(model.usesVietnamese ? "Bật LDWS" : "Enable LDWS", isOn: $model.enableLaneDetection)
                    
                    if model.enableLaneDetection {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(model.usesVietnamese ? "Ngưỡng tốc độ kích hoạt: \(Int(model.ldwsMinSpeedKmh)) km/h" : "LDWS activation threshold: \(Int(model.ldwsMinSpeedKmh)) km/h")
                                .font(.subheadline)
                            Slider(value: $model.ldwsMinSpeedKmh, in: 40...70, step: 5)
                            Text(model.usesVietnamese ? "Chỉ cảnh báo khi tốc độ ≥ ngưỡng" : "Only alert when speed ≥ threshold")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Section(model.usesVietnamese ? "Giao diện" : "Interface") {
                    Picker(model.usesVietnamese ? "Ngôn ngữ" : "Language", selection: $model.usesVietnamese) { Text("Tiếng Việt").tag(true); Text("English").tag(false) }.pickerStyle(.segmented)
                    
                    Picker(model.usesVietnamese ? "Giao diện" : "Display Theme", selection: $model.displayThemeMode) {
                        Text(model.usesVietnamese ? "Tự động" : "Auto").tag(DisplayThemeMode.auto)
                        Text(model.usesVietnamese ? "Ngày" : "Day").tag(DisplayThemeMode.day)
                        Text(model.usesVietnamese ? "Đêm" : "Night").tag(DisplayThemeMode.night)
                    }
                    .pickerStyle(.segmented)
                    
                    Toggle(model.usesVietnamese ? "Phản chiếu kính lái (HUD Mirror)" : "Windshield Mirror Mode", isOn: $model.hudMirrorMode)
                    
                    Toggle(model.usesVietnamese ? "HUD đen tiết kiệm" : "Eco Black HUD", isOn: $model.ecoBlackHUD)
                    Toggle(model.usesVietnamese ? "Hiệu ứng kính" : "Glass effect", isOn: $model.glassHUD)
                    Toggle(model.usesVietnamese ? "Hiển thị đường chân trời" : "Show Horizon Guide", isOn: $model.showHorizonGuide)
                    Toggle(model.usesVietnamese ? "Hiển thị xe ngoài làn" : "Show Out-of-Lane Vehicles", isOn: $model.showOutOfROIVehicles)
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
