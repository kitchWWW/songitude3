import SwiftUI
import CoreLocation

/// One walk in a list. Shared by the walks browser and the artist page so both look and behave
/// identically — same status glyph, same tap-to-open, same swipe-to-uninstall (applied by the
/// enclosing List).
struct WalkRow: View {
    @EnvironmentObject var app: AppState

    let walk: RemoteWalk
    let onOpen: () -> Void
    /// Tapping the creator opens that artist's page. nil (e.g. on the artist's own page) makes the
    /// name plain text.
    var onArtist: ((String) -> Void)?

    var body: some View {
        let downloading = app.downloadingWalkId == walk.id

        HStack(spacing: 12) {
            artThumbnail
            VStack(alignment: .leading, spacing: 3) {
                Text(walk.name).font(.headline)
                creatorLine
                // Only facts that never change while downloading live here, so the row's text
                // can't reflow mid-download — state is carried entirely by the status glyph.
                HStack(spacing: 10) {
                    if let m = distanceMeters {
                        Text(distanceText(m))
                            .foregroundStyle(m < Self.nearbyMeters ? Color.green : Color.secondary)
                    }
                    if let s = walk.sizeBytes { Text(sizeText(s)) }
                }.font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            status(downloading: downloading, isCurrent: app.current?.id == walk.id)
                .frame(width: 30, height: 30)   // fixed box: every state occupies the same space
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { if !downloading { onOpen() } }
    }

    /// Square album art at the leading edge, spanning the title/artist/distance block.
    private var artThumbnail: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        return Group {
            if let s = walk.artUrl, let url = URL(string: s) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() }
                    else { placeholderArt }        // loading, or the fetch failed
                }
            } else {
                placeholderArt
            }
        }
        .frame(width: 54, height: 54)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.primary.opacity(0.08)))
    }

    private var placeholderArt: some View {
        ZStack {
            Color.secondary.opacity(0.15)
            Image(systemName: "waveform").font(.title3).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var creatorLine: some View {
        if !walk.creatorText.isEmpty {
            if let artistId = walk.artistId, let onArtist {
                // Only the name reads as the link — "by" stays ordinary caption text.
                Button { onArtist(artistId) } label: {
                    HStack(spacing: 0) {
                        Text("by ").foregroundStyle(.secondary)
                        Text(walk.creatorText).foregroundStyle(.tint)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tint)
                            .padding(.leading, 3)
                    }
                    .font(.caption)
                }
                .buttonStyle(.plain)
            } else {
                Text("by \(walk.creatorText)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func status(downloading: Bool, isCurrent: Bool) -> some View {
        if downloading {
            DownloadRing(progress: app.downloadProgress)
        } else if isCurrent {
            Image(systemName: "checkmark.circle.fill").imageScale(.large).foregroundStyle(.green)
        } else {
            // Always "play": downloading is an implementation detail the listener shouldn't have to
            // think about — tapping either plays straight away or fetches and then plays.
            Image(systemName: "play.circle")
                .imageScale(.large).foregroundStyle(.tint)
        }
    }

    /// Walks within this range read as "close enough to go and hear right now".
    private static let nearbyMeters: Double = 2 * 1609.344   // two miles

    private var distanceMeters: Double? {
        guard let here = app.location.lastKnownLocation, let c = walk.centerCoord else { return nil }
        return CLLocation(latitude: here.latitude, longitude: here.longitude)
            .distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
    }
    /// Feet up close, miles beyond a tenth of a mile, whole miles once precision stops mattering.
    private func distanceText(_ m: Double) -> String {
        let miles = m / 1609.344
        if miles < 0.1 {
            let feet = Int((m * 3.28084 / 10).rounded() * 10)   // nearest 10 ft
            return "\(feet) ft away"
        }
        if miles < 10 { return String(format: "%.1f miles away", miles) }
        return "\(Int(miles.rounded())) miles away"
    }
    private func sizeText(_ b: Int) -> String {
        b >= 1_000_000 ? String(format: "%.1f MB", Double(b) / 1e6) : "\(b / 1000) KB"
    }
}

/// Determinate progress ring. Same footprint as the row's other status glyphs, so a download
/// starting never resizes anything around it.
struct DownloadRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 3)
            Circle()
                .trim(from: 0, to: max(0.03, min(progress, 1)))   // always show a sliver, even at 0%
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.2), value: progress)
        }
        .frame(width: 22, height: 22)
        .accessibilityLabel("Downloading, \(Int(progress * 100)) percent")
    }
}

/// Pin a walk row so state changes can't animate it out and back in. Deleting a download changes
/// several published properties at once; without this the List treats the row as new and flashes it.
extension View {
    func stableWalkRow(_ walk: RemoteWalk, app: AppState) -> some View {
        self.id(walk.id)
            .transition(.identity)
            .animation(nil, value: app.downloadedIds)
            .animation(nil, value: app.current?.id)
    }
}

/// Row separators run edge to edge instead of stopping short at the default text inset.
extension View {
    func fullWidthSeparator() -> some View {
        alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            .alignmentGuide(.listRowSeparatorTrailing) { $0[.trailing] }
    }
}

/// Swipe-to-uninstall, applied identically wherever a walk row appears in a List.
extension View {
    func uninstallSwipeAction(for walk: RemoteWalk, app: AppState) -> some View {
        swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if app.isDownloaded(walk.id) && app.downloadingWalkId != walk.id {
                Button(role: .destructive) { app.deleteDownloaded(walk.id) } label: {
                    Label("Uninstall", systemImage: "xmark")
                }
            }
        }
    }
}
