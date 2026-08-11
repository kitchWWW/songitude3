import SwiftUI

/// Full-screen list of published walks (nearest-first). Downloads on demand; pull down to refresh
/// the catalog; swipe a downloaded walk to uninstall it; tap a creator to open their artist page.
struct WalksBrowserView: View {
    @EnvironmentObject var app: AppState
    /// Closing is driven by the parent's binding rather than @Environment(\.dismiss): inside a
    /// NavigationStack, dismiss() pops the stack when anything is pushed instead of closing the
    /// cover, which made the back button need several taps.
    let onClose: () -> Void

    /// Pushed artist ids. Programmatic rather than NavigationLink so the creator name stays an
    /// inline tap target inside the row instead of taking over the whole row.
    @State private var path: [ArtistRoute] = []
    @State private var showGeoLocked = true
    @State private var showAnywhere = true

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let e = app.catalogError {
                    Text(e).font(.footnote).foregroundStyle(.red)
                }

                if app.catalog.loading && app.catalog.walks.isEmpty {
                    HStack { ProgressView(); Text("Loading walks…").foregroundStyle(.secondary) }
                } else if let err = app.catalog.error, app.catalog.walks.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Couldn't load walks").font(.headline)
                        Text(err).font(.caption).foregroundStyle(.secondary)
                    }
                } else if app.catalog.walks.isEmpty {
                    // There is always something published, so an empty catalog means we couldn't
                    // reach it — not that no walks exist.
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No connection").font(.headline)
                        Text("Songitude needs the internet to find soundwalks. Pull down to try again.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    walkSection("Geo-Locked", app.catalog.walks.filter { $0.portable != true },
                                isOpen: $showGeoLocked)
                    walkSection("Listen From Anywhere", app.catalog.walks.filter { $0.portable == true },
                                isOpen: $showAnywhere)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Soundwalks")
            .navigationBarTitleDisplayMode(.inline)   // sits beside the back chevron, not below it
            .refreshable { await app.refreshCatalogAsync() }
            .onAppear {
                // Order by distance every time the list opens; the fix lands asynchronously and
                // AppState re-sorts the catalog when it does.
                app.location.requestOneShotFix()
                app.catalog.resort(near: app.location.lastKnownLocation)
            }
            .navigationDestination(for: ArtistRoute.self) { route in
                ArtistPageView(artistId: route.id, fallbackName: route.name, onOpenWalk: open)
            }
            .toolbar {
                // Not a "Done" button — the only way back to the map when you don't pick a walk.
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: close) { Image(systemName: "chevron.left") }
                        .accessibilityLabel("Back to the map")
                }
            }
        }
    }

    /// One titled, collapsible group of walks. Hidden entirely when it has nothing in it.
    @ViewBuilder
    private func walkSection(_ title: String, _ walks: [RemoteWalk], isOpen: Binding<Bool>) -> some View {
        if !walks.isEmpty {
            Section {
                if isOpen.wrappedValue {
                    ForEach(walks) { walk in
                        WalkRow(walk: walk,
                                onOpen: { open(walk) },
                                onArtist: { path.append(ArtistRoute(id: $0, name: walk.creatorText)) })
                            .uninstallSwipeAction(for: walk, app: app)
                            .fullWidthSeparator()
                            .stableWalkRow(walk, app: app)
                    }
                }
            } header: {
                CollapsibleHeader(title: title, isOpen: isOpen)
            }
        }
    }

    private func open(_ walk: RemoteWalk) {
        app.openRemote(walk)
        close()     // a download keeps running behind the map's progress banner
    }

    private func close() {
        path.removeAll()   // reopening should start on the list, not a pushed artist page
        onClose()
    }
}

/// Navigation target for an artist page. Carries the walk's creator string so the title reads
/// correctly while the profile is still loading.
struct ArtistRoute: Hashable, Identifiable {
    let id: String
    let name: String
}
