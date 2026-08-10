import SwiftUI

/// Full-screen list of published walks (nearest-first). Downloads on demand; pull down to refresh
/// the catalog; swipe a downloaded walk to uninstall it; tap a creator to open their artist page.
struct WalksBrowserView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    /// Pushed artist ids. Programmatic rather than NavigationLink so the creator name stays an
    /// inline tap target inside the row instead of taking over the whole row.
    @State private var path: [ArtistRoute] = []

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
                    Text("No published walks yet. Publish one from the editor at songitude.com.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    ForEach(app.catalog.walks) { walk in
                        WalkRow(walk: walk,
                                onOpen: { open(walk) },
                                onArtist: { path.append(ArtistRoute(id: $0, name: walk.creatorText)) })
                            .uninstallSwipeAction(for: walk, app: app)
                            .fullWidthSeparator()
                            .stableWalkRow(walk, app: app)
                    }
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
                    Button { dismiss() } label: { Image(systemName: "chevron.left") }
                        .accessibilityLabel("Back to the map")
                }
            }
        }
    }

    private func open(_ walk: RemoteWalk) {
        app.openRemote(walk)
        dismiss()   // a download keeps running behind the map's progress banner
    }
}

/// Navigation target for an artist page. Carries the walk's creator string so the title reads
/// correctly while the profile is still loading.
struct ArtistRoute: Hashable, Identifiable {
    let id: String
    let name: String
}
