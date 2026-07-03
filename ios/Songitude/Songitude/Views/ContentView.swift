import SwiftUI

/// The player screen: a full-bleed map with the sound areas overlaid, a gear (settings) in the
/// top-left, and a big play/pause at the bottom that toggles the whole rendering engine.
struct ContentView: View {
    @EnvironmentObject var app: AppState
    @State private var showSettings = false
    @State private var showBrowser = false

    var body: some View {
        ZStack(alignment: .top) {
            mapLayer.ignoresSafeArea()

            // Top bar: gear · walk title (opens browser) · browse
            HStack(alignment: .top) {
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.title2).padding(12).background(.ultraThinMaterial, in: Circle())
                }
                Spacer(minLength: 8)
                Button { showBrowser = true } label: {
                    HStack(spacing: 6) {
                        Text(app.selectedExperience?.displayName ?? "Choose a walk")
                            .font(.headline).lineLimit(1)
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                }
                Spacer(minLength: 8)
                Button { showBrowser = true } label: {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.title3).padding(12).background(.ultraThinMaterial, in: Circle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            if app.downloadingWalkId != nil { downloadBanner }

            VStack {
                Spacer()
                playButton.padding(.bottom, 28)
            }

            if app.experiences.isEmpty && app.selectedExperience == nil { emptyOverlay }
        }
        .sheet(isPresented: $showBrowser) { WalksBrowserView().environmentObject(app) }
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(app) }
        .alert("Location is off", isPresented: $app.showPermissionDeniedAlert) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            Button("Not now", role: .cancel) {}
        } message: {
            Text("Enable location to hear the experience. You can turn it on in the iOS Settings app, or via the gear menu.")
        }
    }

    @ViewBuilder private var mapLayer: some View {
        if let exp = app.selectedExperience {
            MapOverlayView(shapes: exp.map.shapes,
                           offset: app.offset,
                           soundingIDs: app.engine.soundingShapeIDs,
                           centerOn: exp.map.centerCoord,
                           experienceID: exp.id)
        } else {
            Color.black
        }
    }

    private var playButton: some View {
        Button(action: { app.togglePlayback() }) {
            Image(systemName: app.engine.isRunning ? "pause.fill" : "play.fill")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 84, height: 84)
                .background(
                    Circle().fill(app.engine.isRunning ? Color.red : Color.accentColor)
                        .shadow(radius: 12)
                )
        }
        .accessibilityLabel(app.engine.isRunning ? "Pause" : "Play")
    }

    private var downloadBanner: some View {
        VStack(spacing: 6) {
            Text("Downloading walk… \(Int(app.downloadProgress * 100))%")
                .font(.footnote).foregroundStyle(.secondary)
            ProgressView(value: app.downloadProgress).frame(width: 200)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.top, 72)
    }

    private var emptyOverlay: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.largeTitle).foregroundStyle(.secondary)
            Text("No experiences bundled")
                .font(.headline)
            Text("Export a .zip from the editor, drop it in Experiences/, and rebuild.")
                .font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
