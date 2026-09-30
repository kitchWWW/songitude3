import SwiftUI

/// The welcome, as one scene in two steps (Figma "App Loading", `72:154`):
///
/// 1. **Landing** — CHROMIC in the display face across the middle of the wash, white squiggles,
///    stars and dots drifting over it. Tap anywhere to go on.
/// 2. **Permission** — the title lifts to the top, the app icon and the location ask fade in
///    beneath it, the squiggles keep drifting. `OnboardingView` owns that ask. Skipped when
///    location is already granted: the landing goes straight on.
///
/// Replaces Songitude's splash animation and its logo hand-off. Shown on every cold start and after
/// a long absence (`SplashRootView`), not only the first launch; `onDone` hands over to Soundwalks.
struct FirstRunView: View {
    @EnvironmentObject var app: AppState
    /// The welcome is over: go home.
    var onDone: () -> Void = {}
    @State private var step: Step = .landing

    private enum Step { case landing, permission }

    /// Title placement as a fraction of the screen height (mock: text centre at 331/812 on the
    /// landing; the permission step lifts it to sit below the status bar).
    private static let landingTitleY: CGFloat = 0.41
    private static let permissionTitleY: CGFloat = 0.14
    /// 64pt on the landing (the mock's), scaled rather than re-set on the permission step so the
    /// move is one continuous animation instead of a font swap.
    private static let titleSize: CGFloat = 64
    private static let permissionTitleScale: CGFloat = 0.7

    var body: some View {
        GeometryReader { geo in
            ZStack {
                LivingBackdrop()
                // On the permission step the field thins out towards the bottom, so nothing
                // drifts through the copy and the buttons.
                SquiggleField()
                    .mask(
                        LinearGradient(stops: [.init(color: .black, location: 0),
                                               .init(color: .black, location: step == .landing ? 1 : 0.55),
                                               .init(color: .black.opacity(step == .landing ? 1 : 0), location: step == .landing ? 1 : 0.72)],
                                       startPoint: .top, endPoint: .bottom)
                    )

                if step == .permission {
                    OnboardingView(topInset: geo.size.height * Self.permissionTitleY + 60, onDone: finish)
                        .transition(.opacity)
                }

                Text("chromic")
                    .font(Brand.display(Self.titleSize))
                    .tracking(-0.64)
                    .foregroundStyle(Brand.Palette.onBackdrop)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 24)
                    .scaleEffect(step == .landing ? 1 : Self.permissionTitleScale)
                    .position(x: geo.size.width / 2,
                              y: geo.size.height * (step == .landing ? Self.landingTitleY : Self.permissionTitleY))
                    .allowsHitTesting(false)

                if step == .landing {
                    // The whole screen is the button. The hint sits where the mock keeps its
                    // "tag line?" placeholder; swap it for the real tagline when there is one.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(perform: begin)
                        .accessibilityElement()
                        .accessibilityLabel("\(Brand.name). Tap to begin")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction(named: "Begin", begin)
                    Text("Tap to begin")
                        .font(Brand.body(16, weight: .semibold))
                        .foregroundStyle(Brand.Palette.onBackdrop.opacity(0.6))
                        .position(x: geo.size.width / 2, y: geo.size.height * 0.87)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.55), value: step)
    }

    /// Past the landing: ask for location only if it isn't granted yet. A refusal ("Denied") still
    /// gets the page — it explains why, and "Not now" is always there — but a grant needs no
    /// second pitch on every launch.
    private func begin() {
        if app.location.isAuthorized { finish() } else { step = .permission }
    }

    /// Onboarding is recorded (it still gates deep links, and a reset clears it), then home.
    private func finish() {
        app.completeOnboarding()
        onDone()
    }
}
