import SwiftUI
import CoreLocation

/// First-run welcome, and the only place we ask for location up front.
///
/// App Review 5.1.1(iv) governs this screen: a pre-permission screen may explain what *this app*
/// does with location, but must never name the system dialog's options, steer which one to pick,
/// or dress the advance button up as consent ("Enable", "Allow"). The button stays neutral, there
/// is always a way past without granting, and a refusal is met with silence here — the walk asks
/// again at the one moment it actually needs location.
struct OnboardingView: View {
    @EnvironmentObject var app: AppState
    /// True while the splash still owns the logo; this view reserves the space but draws nothing,
    /// so the incoming tile lands on an empty slot.
    var hidesLogo = false
    @State private var requested = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            // Branded wash, but in whichever direction the app's appearance setting points.
            LinearGradient(colors: scheme == .dark
                           ? [Color(red: 0.08, green: 0.09, blue: 0.13), Color(red: 0.14, green: 0.10, blue: 0.22)]
                           : [Color(red: 0.97, green: 0.97, blue: 0.99), Color(red: 0.92, green: 0.90, blue: 0.97)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()
                LogoTile()
                    .frame(width: 100, height: 100)
                    .shadow(radius: 20)
                    .opacity(hidesLogo ? 0 : 1)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: LogoFrameKey.self, value: g.frame(in: .global))
                    })

                Text("Songitude")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)

                Text("Put on headphones,\nwalk, and listen —\nthe music follows you.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Spacer()

                // Why we are about to ask. Describes the app's own behaviour and nothing about the
                // dialog that follows or how to answer it.
                Text("Songitude needs your location to play the sounds placed around you and follow you as you walk.")
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 4)

                Button(action: advance) {
                    Text("Continue")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 24)

                // The way in without granting anything. It also means this screen can never strand
                // anyone: if iOS declines to present the dialog at all (a restricted device), the
                // primary button appears to do nothing and this is still a way forward.
                Button("Not now") { app.completeOnboarding() }
                    .font(.subheadline)
                    .padding(.top, 2)

                Text("We only use your location to play the right sounds around you, never to track or share where you are.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 24)
            }
        }
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
