import SwiftUI
import CoreLocation

/// The location ask, and the only place we ask for it up front. Drawn by `FirstRunView` as the
/// second step of the first launch — the title and the drifting squiggles are the scene's; this
/// view is the app icon and the block at the bottom.
///
/// App Review 5.1.1(iv) governs this screen: a pre-permission screen may explain what *this app*
/// does with location, but must never name the system dialog's options, steer which one to pick,
/// or dress the advance button up as consent ("Enable", "Allow"). The button stays neutral, there
/// is always a way past without granting, and a refusal is met with silence here — the walk asks
/// again at the one moment it actually needs location.
struct OnboardingView: View {
    @EnvironmentObject var app: AppState
    /// Space the scene's title occupies above us.
    var topInset: CGFloat = 140
    @State private var requested = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: topInset)

            // The icon, as it sits on the home screen: the piano at the corner radius iOS uses.
            Image("IconTile")
                .resizable()
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 27, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
                .accessibilityHidden(true)

            Spacer()

            VStack(spacing: 14) {
                // Why we are about to ask. Describes the app's own behaviour and nothing about the
                // dialog that follows or how to answer it.
                Text("\(Brand.name) needs your location to play the sounds placed around you and follow you as you walk.")
                    .font(Brand.body(16, weight: .semibold))
                    .foregroundStyle(Brand.Palette.bodyText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 4)

                Button("Continue", action: advance)
                    .buttonStyle(BrandPrimaryButtonStyle())
                    .padding(.top, 6)

                // The way in without granting anything. It also means this screen can never strand
                // anyone: if iOS declines to present the dialog at all (a restricted device), the
                // primary button appears to do nothing and this is still a way forward.
                Button("Not now") { app.completeOnboarding() }
                    .font(Brand.body(15, weight: .medium))
                    .foregroundStyle(Brand.Palette.bodyText.opacity(0.75))
                    .padding(.vertical, 6)

                Text("We only use your location to play the right sounds around you, never to track or share where you are.")
                    .font(Brand.body(12))
                    .foregroundStyle(Brand.Palette.bodyText.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
            .padding(.horizontal, Brand.pageInset)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: app.location.authorization) { status in
            // Whatever they chose, the answer is in, so go in. A refusal is deliberately met with
            // nothing here: ContentView owns the single "Location is off" alert, and it fires from
            // togglePlayback — at the moment the listener asks for the thing that needs location.
            guard requested, status != .notDetermined else { return }
            app.completeOnboarding()
        }
    }

    /// The neutral advance button: ask iOS once if we have never asked, otherwise just go in.
    private func advance() {
        requested = true
        if app.location.authorization == .notDetermined {
            app.enableLocation()          // system dialog → .onChange carries the outcome
        } else {
            app.completeOnboarding()      // already decided, one way or the other — nothing to ask
        }
    }
}
