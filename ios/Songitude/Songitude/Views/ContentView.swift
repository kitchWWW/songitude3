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

    /// One height for every control in the top bar, so the title capsule lines up with the gear
    /// and the layers button instead of being sized by its own text padding.
    private static let topControl: CGFloat = 44

    var body: some View {
        ZStack(alignment: .top) {
            mapLayer.ignoresSafeArea()

            // Top bar: gear · walk title (opens browser) · browse
            HStack(alignment: .top) {
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.title2)
                        .frame(width: Self.topControl, height: Self.topControl)
                        .background(.ultraThinMaterial, in: Circle())
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
                    .padding(.horizontal, 16)
                    .frame(height: Self.topControl)
                    .background(.ultraThinMaterial, in: Capsule())
                }
                Spacer(minLength: 8)
                Button { showBrowser = true } label: {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.title3)
                        .frame(width: Self.topControl, height: Self.topControl)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            VStack {
                Spacer()
                // Play stays dead centre; "All done?" sits beside it rather than pushing it over,
                // so the button you reach for never moves.
                ZStack {
                    playButton
                    // Only offered when the walk actually has an outro to play.
                    if app.engine.isRunning && app.engine.canEndSession && app.currentHasOutro {
                        HStack {
                            Spacer()
                            Button { app.engine.endSession() } label: {
                                Text("Play Outro")
                                    .font(.headline).foregroundStyle(.primary)
                                    .padding(.horizontal, 18).padding(.vertical, 14)
                                    .background(.ultraThinMaterial, in: Capsule())
                            }
                        }
                        .padding(.trailing, 20)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
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
        }
        .animation(.easeInOut(duration: 0.2), value: app.showIntroCard)
        .onAppear {
            app.maybeShowIntroCard()
            // Nothing loaded yet → go straight to the selector. Guarded so closing the browser
            // without picking anything doesn't immediately reopen it.
            // Even if they back out without choosing, we want the map on them.
            if app.selectedExperience == nil { app.location.requestOneShotFix() }
            // …but a QR deep link already names a walk, so don't cover it with the list.
            if app.selectedExperience == nil && !app.isOpeningWalk && !didAutoOpenBrowser {
                didAutoOpenBrowser = true
                // Present it already-there rather than sliding it up: on launch this is the first
                // screen, so an entrance animation reads as the app arriving twice.
                var t = Transaction(); t.disablesAnimations = true
                withTransaction(t) { showBrowser = true }
            }
        }
        .fullScreenCover(isPresented: $showBrowser) {
            WalksBrowserView(onClose: { showBrowser = false }).environmentObject(app)
        }
        // A deep link can resolve after the list has already opened (the URL and onAppear race on a
        // cold launch); get out of its way so the walk's card is what the listener sees.
        .onChange(of: app.current?.id) { id in if id != nil { showBrowser = false } }
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
                           // Placement is part of the identity: a re-anchored walk has the same id
                           // but different coordinates, and the map keys its rebuild on this.
                           experienceID: "\(exp.id)#\(app.placementVersion)")
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
                Circle().fill(downloading ? downloadingFill
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
