import SwiftUI

@main
struct SongitudeApp: App {
    @StateObject private var app = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if app.hasOnboarded {
                    ContentView()
                } else {
                    OnboardingView()
                }
            }
            .environmentObject(app)
            // Universal Link (QR / https://songitude.com/w.html?walk=…) → open that walk as default.
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                if let url = activity.webpageURL { app.handleDeepLink(url) }
            }
            .onOpenURL { url in app.handleDeepLink(url) }
        }
        .onChange(of: scenePhase) { phase in
            // Coming back to the foreground: reconcile the permission state.
            if phase == .active { app.checkPermissionOutcome() }
        }
    }
}
