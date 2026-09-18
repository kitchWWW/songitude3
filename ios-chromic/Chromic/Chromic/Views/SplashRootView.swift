import SwiftUI

/// App root: the first-run scene until onboarding is done, then home. Songitude runs its splash
/// animation here and lands on the map; Chromic's landing *is* the first screen, and home is About.
struct SplashRootView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        Group {
            if app.hasOnboarded {
                HomeRoot()
            } else {
                FirstRunView()
            }
        }
        .preferredColorScheme(app.appearance.colorScheme)
        // Keyed on the reset token so "Reset app" starts the first-run scene over from the landing.
        .id(app.resetToken)
    }
}

/// Home: the About → Soundwalks → walk stack, with the map presented over it. Songitude is the
/// other way up — map at the root, list as a cover — but here the map is where Start takes you,
/// and leaving it returns you to the page you started from, walk still playing.
private struct HomeRoot: View {
    @EnvironmentObject var app: AppState
    @State private var path: [BrowserRoute] = []
    @State private var showMap = false

    var body: some View {
        WalksBrowserView(path: $path, onOpenMap: { showMap = true })
            .fullScreenCover(isPresented: $showMap) {
                ContentView(onShowWalk: { leaveMap(to: walkPath) },
                            onBrowse: { leaveMap(to: [.walks]) })
                    .environmentObject(app)
            }
            // A QR deep link names a walk: the moment it is current, the map is what to show. Start
            // goes through here too, which is harmless.
            .onChange(of: app.current?.id) { id in if id != nil { showMap = true } }
            .onAppear { if app.current != nil { showMap = true } }
    }

    /// The current walk's page, when the catalog knows it; otherwise the list.
    private var walkPath: [BrowserRoute] {
        app.currentRemoteWalk.map { [.walks, .walk($0)] } ?? [.walks]
    }

    private func leaveMap(to routes: [BrowserRoute]) {
        path = routes
        showMap = false
    }
}
