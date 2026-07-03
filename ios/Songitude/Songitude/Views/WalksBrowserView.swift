import SwiftUI
import CoreLocation

/// Browse published walks (nearest-first) and bundled demos, and load one. Downloads on demand.
struct WalksBrowserView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section {
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
                        ForEach(app.catalog.walks) { walk in remoteRow(walk) }
                    }
                } header: { Text("Published walks") } footer: {
                    if let e = app.catalogError { Text(e).foregroundStyle(.red) }
                }

                Section("Bundled demos") {
                    ForEach(Array(app.experiences.enumerated()), id: \.offset) { idx, exp in
                        Button { app.selectBundled(idx); dismiss() } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(exp.displayName)
                                    Text("\(exp.map.shapes.count) areas").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if app.current?.id == exp.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                            }
                        }.tint(.primary)
                    }
                }
            }
            .navigationTitle("Sound walks")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { app.refreshCatalog() } label: { Image(systemName: "arrow.clockwise") }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    @ViewBuilder private func remoteRow(_ walk: RemoteWalk) -> some View {
        let downloading = app.downloadingWalkId == walk.id
        let cached = WalkDownloader.isDownloaded(walk.id)
        Button {
            app.openRemote(walk)
            if cached { dismiss() }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(walk.name).font(.headline)
                    if !walk.creatorText.isEmpty {
                        Text("by \(walk.creatorText)").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 10) {
                        if let d = distanceText(walk) { Label(d, systemImage: "location.fill") }
                        if let s = walk.sizeBytes { Text(sizeText(s)) }
                        if cached { Text("Downloaded").foregroundStyle(.green) }
                    }.font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if downloading {
                    ProgressView(value: app.downloadProgress).frame(width: 64)
                } else if app.current?.id == walk.id {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Image(systemName: cached ? "play.circle" : "arrow.down.circle").imageScale(.large).foregroundStyle(.tint)
                }
            }
        }.tint(.primary)
    }

    private func distanceText(_ w: RemoteWalk) -> String? {
        guard let here = app.location.lastKnownLocation, let c = w.centerCoord else { return nil }
        let m = CLLocation(latitude: here.latitude, longitude: here.longitude)
            .distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
        return m < 1000 ? "\(Int(m)) m away" : String(format: "%.1f km away", m / 1000)
    }
    private func sizeText(_ b: Int) -> String {
        b >= 1_000_000 ? String(format: "%.1f MB", Double(b) / 1e6) : "\(b / 1000) KB"
    }
}
