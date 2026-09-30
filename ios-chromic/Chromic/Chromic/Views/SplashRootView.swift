import SwiftUI

/// App root: the welcome scene, then home. Songitude runs its splash animation here and lands on
/// the map; Chromic opens on its welcome page and lands on Soundwalks.
///
///     Welcome  →  (location, only if not yet granted)  →  Soundwalks
///
/// The welcome is shown on **every cold start**, not just the first — it is the app's front door,
/// and a launch from nothing (including after the listener swiped the app away) walks through it.
/// Coming back from the background is different: after a short absence nothing moves; after one
/// longer than `Brand.resumeWindow` the app starts over at the welcome — unless a walk is under
/// way, which is never interrupted. See `returnedFromBackground`.
///
/// The navigation state (`path`, `showMap`) lives here rather than in `HomeRoot`, so the welcome can
/// replace home without forgetting it, and starting over can put it back to Soundwalks explicitly.
struct SplashRootView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.scenePhase) private var scenePhase

    /// True from launch until the welcome (and the location step, if shown) is passed. Plain view
    /// state on purpose: a new process starts it at `true`, which is exactly "every cold start".
    @State private var welcoming = true
    /// About is the root of the stack and Soundwalks sits on it, so a fresh home lands on the list
    /// and its cloud pops back to About.
    @State private var path: [BrowserRoute] = HomeRoot.landing
    @State private var showMap = false

    // MARK: Background timing

    /// When the scene last went to the background; nil while in the foreground.
    @State private var backgroundedAt: Date?
    /// Whether a walk was under way at that moment. Sampled on the way out as well as on the way
    /// back: the engine's own foreground handler can settle a torn-down session into "paused" at
    /// the same moment we are deciding, and a walk that was playing when the phone was pocketed
    /// must count as under way whatever it reads on return.
    @State private var walkActiveWhenBackgrounded = false

    var body: some View {
        Group {
            if welcoming || !app.hasOnboarded {
                FirstRunView(onDone: { welcoming = false })
            } else {
                HomeRoot(path: $path, showMap: $showMap)
            }
        }
        .preferredColorScheme(app.appearance.colorScheme)
        // Keyed on the reset token so "Reset app" starts the first-run scene over from the landing.
        .id(app.resetToken)
        .onChange(of: app.resetToken) { _ in startOver() }
        // A QR deep link names a walk: the moment it is current, the map is what to show. Watched
        // here, not in `HomeRoot`, so a link that lands during the welcome still opens its map the
        // moment home appears. Start goes through here too, which is harmless.
        .onChange(of: app.current?.id) { id in if id != nil { showMap = true } }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .background:
                backgroundedAt = Date()
                walkActiveWhenBackgrounded = walkUnderWay
            case .active:
                returnedFromBackground()
            default:
                // `.inactive` alone is the notification shade, Control Center, an incoming-call
                // banner: never an absence worth acting on.
                break
            }
        }
    }

    /// A walk is under way while it plays — in the background too — or while its map is on screen,
    /// playing or paused. Either way the listener is coming back to the walk, not to the app.
    private var walkUnderWay: Bool { app.engine.isRunning || showMap }

    private func returnedFromBackground() {
        guard let since = backgroundedAt else { return }
        backgroundedAt = nil
        let away = Date().timeIntervalSince(since)
        guard away > Brand.resumeWindow, !walkActiveWhenBackgrounded, !walkUnderWay, !welcoming else { return }
        startOver()
    }

    /// Back to the welcome, with home reset to land on Soundwalks. A loaded-but-idle walk stays
    /// loaded (Start on its page returns to it without reloading); only the navigation starts over.
    private func startOver() {
        welcoming = true
        path = HomeRoot.landing
        showMap = false
    }
}

/// Home: the About → Soundwalks → walk stack, with the map presented over it. Songitude is the
/// other way up — map at the root, list as a cover — but here the map is where Start takes you,
/// and leaving it returns you to the page you started from, walk still playing.
///
/// Opens on Soundwalks with About underneath it, rather than pushing About from the list: the cloud
/// is then an ordinary pop, About's "Soundwalks" button the way back, and the artist's name
/// anywhere still "goes home" to About by clearing the path.
private struct HomeRoot: View {
    @EnvironmentObject var app: AppState
    @Binding var path: [BrowserRoute]
    @Binding var showMap: Bool

    /// Where home opens: Soundwalks, on top of About.
    static let landing: [BrowserRoute] = [.walks]

    var body: some View {
        WalksBrowserView(path: $path, onOpenMap: { showMap = true })
            .fullScreenCover(isPresented: $showMap) {
                ContentView(onShowWalk: { leaveMap(to: walkPath) },
                            onBrowse: { leaveMap(to: [.walks]) })
                    .environmentObject(app)
            }
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
