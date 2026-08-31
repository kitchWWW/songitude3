import SwiftUI

@main
struct SongitudeApp: App {
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup {
            SplashRootView()
                .environmentObject(app)
            // Universal Link (QR / https://songitude.com/w.html?walk=…) → open that walk as default.
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                if let url = activity.webpageURL { app.handleDeepLink(url) }
            }
            .onOpenURL { url in app.handleDeepLink(url) }
        }
    }
}
