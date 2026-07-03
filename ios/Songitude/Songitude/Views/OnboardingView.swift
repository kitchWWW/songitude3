import SwiftUI
import CoreLocation

/// First-run welcome. A single big button fires the iOS location request; the outcome routes
/// the user into the experience or explains how to enable location later.
struct OnboardingView: View {
    @EnvironmentObject var app: AppState
    @State private var requested = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.08, green: 0.09, blue: 0.13),
                                    Color(red: 0.14, green: 0.10, blue: 0.22)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()
                Circle()
                    .fill(AngularGradient(gradient: Gradient(colors: [.red, .orange, .green, .blue, .purple, .red]),
                                          center: .center))
                    .frame(width: 96, height: 96)
                    .shadow(radius: 20)

                Text("Welcome to\nSongitude")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)

                Text("An audio experience that changes with where you stand. Put on headphones, walk, and listen — the music follows the map around you.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Spacer()

                VStack(spacing: 8) {
                    Label("On the next screen, tap “Allow While Using App.”", systemImage: "location.fill")
                        .font(.subheadline.weight(.semibold))
                    Text("That's all we need. The sound keeps playing and updating as you walk — even with your phone locked and in your pocket.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 4)

                Button(action: enable) {
                    Text("Enable location permissions")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 24)

                Text("We only use your location to play the right sounds around you — never to track or share where you are.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 24)
            }
        }
        .onChange(of: app.location.authorization) { status in
            guard requested else { return }
            switch status {
            case .authorizedWhenInUse, .authorizedAlways:
                app.completeOnboarding()   // location starts later, when they hit play
            case .denied, .restricted:
                app.showPermissionDeniedAlert = true
                app.completeOnboarding()   // let them in; they can enable later in Settings
            default:
                break
            }
        }
        .alert("Location is off", isPresented: $app.showPermissionDeniedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("You won't be able to listen to the experience until you enable location. You can turn it on any time from the Settings menu (gear icon).")
        }
        .preferredColorScheme(.dark)   // branded dark splash; the rest of the app follows the system
    }

    private func enable() {
        requested = true
        switch app.location.authorization {
        case .notDetermined:
            app.enableLocation()          // system dialog → .onChange handles the outcome
        case .authorizedWhenInUse, .authorizedAlways:
            app.completeOnboarding()      // already authorized; location starts when they hit play
        case .denied, .restricted:
            app.showPermissionDeniedAlert = true
            app.completeOnboarding()      // let them in; they can enable later in Settings
        @unknown default:
            app.enableLocation()
        }
    }
}
