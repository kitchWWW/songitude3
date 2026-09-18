import SwiftUI

@main
struct ChromicApp: App {
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup {
            SplashRootView()
                .environmentObject(app)
            // Universal Link (QR / https://songitude.com/w.html?walk=…) → open that walk as default.
            // This app is not in songitude.com's AASA yet, so only custom-scheme URLs reach it today.
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                if let url = activity.webpageURL { app.handleDeepLink(url) }
            }
            .onOpenURL { url in app.handleDeepLink(url) }
        }
    }
}
