import SwiftUI
import UIKit

@main
struct DriveAssistantApp: App {
    @StateObject private var model = DriveAssistantModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        UIApplication.shared.isIdleTimerDisabled = true
    }

    var body: some Scene {
        WindowGroup { ContentView(model: model) }
            .onChange(of: scenePhase) { _ in
                UIApplication.shared.isIdleTimerDisabled = true
            }
    }
}
