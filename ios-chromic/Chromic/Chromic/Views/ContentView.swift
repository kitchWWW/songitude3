import SwiftUI
import CoreLocation

/// The player screen: a full-bleed map with the sound areas overlaid, a gear (settings) in the
/// top-left, and a big play/pause at the bottom that toggles the whole rendering engine.
struct ContentView: View {
    @EnvironmentObject var app: AppState
    /// The effective scheme (SplashRootView applies the walk's `appearance` above us). The map
    /// supplies its own tiles now, so it has to be told which basemap to draw.
    @Environment(\.colorScheme) private var colorScheme
    @State private var showSettings = false
    @State private var artistRoute: ArtistRoute?
    /// The map is presented over the About → Soundwalks → walk stack (`HomeRoot`); these dismiss
    /// it, landing on the walk's page or on the list. The walk keeps playing either way.
    let onShowWalk: () -> Void
    let onBrowse: () -> Void

    /// One height for every control in the top bar, so the title capsule lines up with the gear
    /// and the layers button instead of being sized by its own text padding.
    private static let topControl: CGFloat = 44

    var body: some View {
        ZStack(alignment: .top) {
            mapLayer.ignoresSafeArea()

            // Top bar: cloud (settings) · walk title (leaves for the walk's page) · home (the list).
            HStack(alignment: .top) {
                Button { showSettings = true } label: {
                    BrandIcon(name: "IconCloud", height: 20)
                        .frame(width: Self.topControl, height: Self.topControl)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("Settings")
                Spacer(minLength: 8)
                // The title leaves the map for the walk's own page (Chromic has no intro card);
                // the layers button leaves it for the list.
                Button(action: onShowWalk) {
                    HStack(spacing: 6) {
                        Text(app.selectedExperience?.displayName ?? Brand.name)
                            .font(.headline).lineLimit(1)
                        BrandIcon(name: "IconBack", height: 11).scaleEffect(x: -1)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: Self.topControl)
                    .background(.ultraThinMaterial, in: Capsule())
                }
                Spacer(minLength: 8)
                Button(action: onBrowse) {
                    BrandIcon(name: "IconHome", height: 22)
                        .frame(width: Self.topControl, height: Self.topControl)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("Soundwalks")
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            VStack {
                Spacer()
                // Play stays dead centre with a skip button either side of it, and "All done?"
                // above rather than beside — so the button you reach for never moves, and nothing
                // lands on top of the skips.
                VStack(spacing: 14) {
                    // Only offered when the walk actually has an outro to play.
                    if app.engine.isRunning && app.engine.canEndSession && app.currentHasOutro {
                        Button { app.engine.endSession() } label: {
                            Text("Play Outro")
                                .font(.headline).foregroundStyle(.primary)
                                .padding(.horizontal, 18).padding(.vertical, 14)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    // Transport is meaningless with nothing loaded — no clip to start, nowhere
                    // to skip to. With no walk selected the map is just a map.
                    if app.selectedExperience != nil {
                        HStack(spacing: 20) {
                            skipButton(by: -RenderEngine.skipInterval)
                            playButton
                            skipButton(by: RenderEngine.skipInterval)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .animation(.easeInOut, value: app.engine.canEndSession)
                .padding(.bottom, 28)
            }
            // Above the intro card *and* its scrim: the same button drives the whole walk, and
            // its colour must not be dimmed by the overlay behind it.
            .zIndex(2)

            if app.showIntroCard, let exp = app.selectedExperience {
                WalkIntroCard(experience: exp,
                              remote: app.currentRemoteWalk,
                              onArtist: { route in app.dismissIntroCard(); artistRoute = route },
                              onDismiss: { app.dismissIntroCard() },
                              onRecenter: { app.recenterPortableWalk() })
                    .zIndex(1)
            }

            // Follows the intro card, never shares the screen with it.
            if app.showFarAwayCard, !app.showIntroCard, let exp = app.selectedExperience {
                FarAwayCard(walkName: exp.displayName,
                            distanceMiles: app.currentWalkDistanceMiles,
                            onBrowse: { app.dismissFarAwayCard(); onBrowse() },
                            onDismiss: { app.dismissFarAwayCard() })
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: app.showIntroCard)
        .animation(.easeInOut(duration: 0.2), value: app.showFarAwayCard)
        .onAppear {
            app.maybeShowIntroCard()
            if app.selectedExperience == nil { app.location.requestOneShotFix() }
        }
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
                           routes: exp.map.drawableRoutes,
                           labels: exp.map.drawableLabels,
                           imagesDirectory: exp.directory.appendingPathComponent("images"),
                           offset: app.offset,
                           soundingIDs: app.engine.soundingShapeIDs,
                           dialogueStates: app.engine.dialogueStates,
                           dialogueColors: exp.map.dialoguePalette,
                           centerOn: exp.map.centerCoord,
                           // Placement is part of the identity: a re-anchored walk has the same id
                           // but different coordinates, and the map keys its rebuild on this.
                           experienceID: "\(exp.id)#\(app.placementVersion)",
                           fuzzy: exp.map.isFuzzy,
                           dark: colorScheme == .dark)
        } else {
            // Nothing chosen yet: show a real map centred on the listener rather than a black slab.
            // The id carries the coordinate so the map re-centres once the first fix lands.
            let here = app.location.lastKnownLocation
            MapOverlayView(shapes: [],
                           routes: [],
                           labels: [],
                           imagesDirectory: nil,
                           offset: .none,
                           soundingIDs: [],
                           dialogueStates: [:],
                           dialogueColors: DialogueColors(),
                           centerOn: here ?? CLLocationCoordinate2D(latitude: 39.5, longitude: -98.35),
                           experienceID: here.map { String(format: "none@%.4f,%.4f", $0.latitude, $0.longitude) }
                                             ?? "none",
                           fuzzy: false,
                           dark: colorScheme == .dark)
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
                        .foregroundStyle(.white)
                        .frame(width: 84, height: 84)
                        // A flat opaque grey, not the translucent .secondary, so the map can't
                        // show through.
                        .background(Circle().fill(downloadingFill).shadow(radius: 12))
                } else {
                    // Dorothy's drawn buttons are the whole control — disc, colour and glyph.
                    BrandIcon(name: app.engine.isRunning ? "IconPause" : "IconPlay", height: 84)
                        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
                }
            }
            .frame(width: 84, height: 84)
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

    /// Back / forward 15 seconds. Smaller than play, and always present rather than appearing with
    /// playback: holding their place either side keeps the play button from moving under the thumb.
    /// With nothing playing they simply go quiet.
    private func skipButton(by delta: TimeInterval) -> some View {
        let back = delta < 0
        let live = app.engine.isRunning
        return Button { app.engine.skip(by: delta) } label: {
            BrandIcon(name: back ? "IconBack15" : "IconForward15", height: 34)
                .frame(width: 56, height: 56)
                .background(.ultraThinMaterial, in: Circle())
        }
        .opacity(live ? 1 : 0.35)
        .allowsHitTesting(live)
        .accessibilityLabel(back ? "Back 15 seconds" : "Forward 15 seconds")
    }

}

/// Fill of the play button while a walk downloads. The progress ring's unfilled track uses the
/// same colour so only the completed arc reads as a ring.
private let downloadingFill = Color(red: 0.36, green: 0.38, blue: 0.42)

/// The download indicator that wraps the play button: a determinate arc showing how much of the
/// walk has arrived, on a slowly spinning track so it reads as active even on a stalled byte.
private struct DownloadHalo: View {
    let progress: Double
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle().stroke(downloadingFill, lineWidth: 6)
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
