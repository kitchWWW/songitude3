import SwiftUI
import CoreLocation

/// The player screen: a full-bleed map with the sound areas overlaid, a gear (settings) in the
/// top-left, and a big play/pause at the bottom that toggles the whole rendering engine.
struct ContentView: View {
    @EnvironmentObject var app: AppState
    @State private var showSettings = false
    @State private var showBrowser = false
    @State private var artistRoute: ArtistRoute?
    @State private var didAutoOpenBrowser = false

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
                // With a walk loaded the title reopens its card; with none it falls back to the
                // app name and opens the browser, same as the layers button.
                Button {
                    if app.selectedExperience != nil { app.presentIntroCard() } else { showBrowser = true }
                } label: {
                    HStack(spacing: 6) {
                        Text(app.selectedExperience?.displayName ?? "Songitude")
                            .font(.headline).lineLimit(1)
                        Image(systemName: app.selectedExperience != nil ? "info.circle" : "chevron.down")
                            .font(.caption2)
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

            VStack {
                Spacer()
                HStack(spacing: 16) {
                    playButton
                    if app.engine.isRunning && app.engine.canEndSession {
                        Button { app.engine.endSession() } label: {
                            Text("All done?")
                                .font(.headline).foregroundStyle(.primary)
                                .padding(.horizontal, 20).padding(.vertical, 16)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut, value: app.engine.canEndSession)
                .padding(.bottom, 28)
            }
            // Above the intro card *and* its scrim: the same button drives the whole walk, and
            // its colour must not be dimmed by the overlay behind it.
            .zIndex(2)

            if app.experiences.isEmpty && app.selectedExperience == nil { emptyOverlay }

            if app.showIntroCard, let exp = app.selectedExperience {
                WalkIntroCard(experience: exp,
                              remote: app.currentRemoteWalk,
                              onArtist: { route in app.dismissIntroCard(); artistRoute = route },
                              onDismiss: { app.dismissIntroCard() })
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: app.showIntroCard)
        .onAppear {
            app.maybeShowIntroCard()
            // Nothing loaded yet → go straight to the selector. Guarded so closing the browser
            // without picking anything doesn't immediately reopen it.
            // Even if they back out without choosing, we want the map on them.
            if app.selectedExperience == nil { app.location.requestOneShotFix() }
            if app.selectedExperience == nil && !didAutoOpenBrowser {
                didAutoOpenBrowser = true
                showBrowser = true
            }
        }
        .fullScreenCover(isPresented: $showBrowser) { WalksBrowserView().environmentObject(app) }
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(app) }
        .sheet(item: $artistRoute) { route in
            NavigationStack {
                ArtistPageView(artistId: route.id, fallbackName: route.name,
                               onOpenWalk: { w in artistRoute = nil; app.openRemote(w) })
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { artistRoute = nil }
                        }
                    }
            }
            .environmentObject(app)
        }
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
                           dialogueStates: app.engine.dialogueStates,
                           dialogueColors: exp.map.dialoguePalette,
                           centerOn: exp.map.centerCoord,
                           experienceID: exp.id)
        } else {
            // Nothing chosen yet: show a real map centred on the listener rather than a black slab.
            // The id carries the coordinate so the map re-centres once the first fix lands.
            let here = app.location.lastKnownLocation
            MapOverlayView(shapes: [],
                           offset: .none,
                           soundingIDs: [],
                           dialogueStates: [:],
                           dialogueColors: DialogueColors(),
                           centerOn: here ?? CLLocationCoordinate2D(latitude: 39.5, longitude: -98.35),
                           experienceID: here.map { String(format: "none@%.4f,%.4f", $0.latitude, $0.longitude) }
                                             ?? "none")
        }
    }

    private var playButton: some View {
        let downloading = app.downloadingWalkId != nil
        return Button(action: {
            if app.showIntroCard { app.dismissIntroCard() }   // starting the walk closes its card
            app.togglePlayback()
        }) {
            Group {
                if downloading {
                    Text("Downloading")
                        .font(.system(size: 13, weight: .regular))
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .padding(.horizontal, 8)
                } else {
                    Image(systemName: app.engine.isRunning ? "pause.fill" : "play.fill")
                        .font(.system(size: 34, weight: .bold))
                }
            }
            .foregroundStyle(.white)
            .frame(width: 84, height: 84)
            .background(
                // A flat opaque grey, not the translucent .secondary, so the map can't show through.
                Circle().fill(downloading ? Color(red: 0.36, green: 0.38, blue: 0.42)
                              : (app.engine.isRunning ? Color.red : Color.accentColor))
                    .shadow(radius: 12)
            )
            .overlay {
                // Progress lives on the button itself: nothing to play until it completes.
                if downloading { DownloadHalo(progress: app.downloadProgress) }
            }
        }
        // Not .disabled(): that dims the whole button. Swallowing the tap keeps it fully opaque.
        .allowsHitTesting(!downloading)
        .accessibilityLabel(downloading
                            ? "Downloading, \(Int(app.downloadProgress * 100)) percent"
                            : (app.engine.isRunning ? "Pause" : "Play"))
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

/// The download indicator that wraps the play button: a determinate arc showing how much of the
/// walk has arrived, on a slowly spinning track so it reads as active even on a stalled byte.
private struct DownloadHalo: View {
    let progress: Double
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.55), lineWidth: 6)
            Circle()
                .trim(from: 0, to: max(0.04, min(progress, 1)))
                .stroke(.white, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .animation(.easeInOut(duration: 0.25), value: progress)
                .rotationEffect(.degrees(spin ? 360 : 0))
                .animation(.linear(duration: 2.4).repeatForever(autoreverses: false), value: spin)
        }
        .frame(width: 100, height: 100)
        .onAppear { spin = true }
    }
}
