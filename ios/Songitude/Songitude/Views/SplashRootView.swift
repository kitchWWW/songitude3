import SwiftUI

/// App root. Runs the launch animation over the real UI, then hands the logo off to the
/// onboarding screen: the waves pulse outward, then the tile flies up and shrinks into the exact
/// spot where the onboarding logo lives.
struct SplashRootView: View {
    @EnvironmentObject var app: AppState

    private enum Phase { case waves, flying, done }

    /// Shown once, on the very first launch — the same moment the onboarding screen appears.
    /// Read straight from UserDefaults so a returning launch never flashes a frame of splash.
    private static let seenKey = "splash.seen.v1"
    @State private var phase: Phase =
        UserDefaults.standard.bool(forKey: SplashRootView.seenKey) ? .done : .waves
    @State private var pulse: Int = -1          // which wave the pulse is passing through
    @State private var logoTarget: CGRect = .zero

    private let splashTileSize: CGFloat = 200

    /// Everything after the opening hold runs this many times faster than its written timings.
    private static let pace: Double = 1.5
    private static func beat(_ seconds: Double) -> UInt64 { UInt64(seconds / pace * 1_000_000_000) }

    var body: some View {
        ZStack {
            Group {
                if app.hasOnboarded {
                    ContentView()
                } else {
                    OnboardingView(hidesLogo: phase != .done)
                }
            }
            .onPreferenceChange(LogoFrameKey.self) { logoTarget = $0 }

            if phase != .done { splash }
        }
        .preferredColorScheme(app.appearance.colorScheme)
        // Keyed on the reset token so "Reset app" replays the whole launch sequence, not just the
        // first screen.
        .task(id: app.resetToken) {
            if app.resetToken > 0 {
                logoTarget = .zero      // the onboarding logo is about to re-lay-out
                pulse = -1
                phase = .waves
            }
            await runIntro()
        }
    }

    // MARK: Splash layer

    private var splash: some View {
        // The reader ignores the safe area so its local coordinates are the window's — the same
        // space LogoFrameKey measures in. Without that the tile landed one status-bar height off.
        GeometryReader { geo in
            ZStack {
                // Darkest where the mark sits, lifting toward the edges — the mark pops against
                // the centre and the tile's own edges are invisible until it flies away.
                RadialGradient(colors: [.black,
                                        Color(red: 0.07, green: 0.075, blue: 0.09),
                                        Color(red: 0.30, green: 0.32, blue: 0.36)],
                               center: .center,
                               startRadius: 0,
                               endRadius: max(geo.size.width, geo.size.height) * 0.62)
                    .opacity(phase == .flying ? 0 : 1)

                LogoTile(waveOpacity: waveOpacity, tileOpacity: phase == .waves ? 0 : 1)
                    .frame(width: splashTileSize, height: splashTileSize)
                    // Scale rather than an animated frame: resizing the frame re-lays-out the
                    // vector mark every tick, which is what made the flight stutter. scaleEffect
                    // is a render-time transform, so it stays smooth.
                    .scaleEffect(tileScale)
                    .position(tileCenter(in: geo))
                    .shadow(radius: phase == .flying ? 20 : 0)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var hasTarget: Bool { logoTarget != .zero }

    private var tileScale: CGFloat {
        phase == .flying && hasTarget ? logoTarget.width / splashTileSize : 1
    }

    private func tileCenter(in geo: GeometryProxy) -> CGPoint {
        guard phase == .flying, hasTarget else {
            return CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        return CGPoint(x: logoTarget.midX, y: logoTarget.midY)
    }

    /// The pulse dims one wave at a time from the inside out, with a soft trail behind it.
    private func waveOpacity(_ i: Int) -> Double {
        guard pulse >= 0 else { return 1 }
        if i == pulse { return 0.45 }
        if i == pulse - 1 { return 0.75 }
        return 1
    }

    // MARK: Timeline

    private func runIntro() async {
        guard phase == .waves else { return }

        try? await Task.sleep(nanoseconds: 1_000_000_000)   // hold on the logo before it stirs

        // The outward pulse: three beats plus a beat to settle, all scaled by `pace`.
        for step in 0..<3 {
            withAnimation(.easeInOut(duration: 0.6 / Self.pace)) { pulse = step }
            try? await Task.sleep(nanoseconds: Self.beat(0.7))
        }
        withAnimation(.easeInOut(duration: 0.6 / Self.pace)) { pulse = -1 }
        try? await Task.sleep(nanoseconds: Self.beat(0.9))

        // The onboarding logo publishes its frame as soon as it lays out, but don't fly until it
        // has — otherwise the tile animates to screen-centre and then snaps into place.
        for _ in 0..<20 where !hasTarget {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        // Fully damped: overshooting the landing spot reads as a bounce, not a hand-off.
        withAnimation(.spring(response: 0.85 / Self.pace, dampingFraction: 1.0)) { phase = .flying }
        try? await Task.sleep(nanoseconds: Self.beat(0.95))
        phase = .done
        UserDefaults.standard.set(true, forKey: Self.seenKey)
    }
}
