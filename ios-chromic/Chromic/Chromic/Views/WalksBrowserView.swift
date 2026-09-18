import SwiftUI
import CoreLocation
import os

/// Everything that is not the map, as one navigation stack rooted on About:
///
///     About  →  Soundwalks  →  a walk's page  →  (Start) the map
///
/// About is the app's home. The list is one step in, a walk one more, and Start presents the map
/// over the lot; leaving the map lands back here, on whatever page the path says.
///
/// The path is the *parent's* state, handed in as a binding, so the map's buttons can set where to
/// land before dismissing. Earlier versions kept it private and set it after the fact, and both
/// misbehaved: applying an initial route in the root list's `onAppear` re-pushed the walk every
/// time the list was popped back to (a root view appears again on every pop — back from Emerald
/// Futures landed on Emerald Futures), and setting it in the stack's own first `onAppear` was
/// silently ignored.
struct WalksBrowserView: View {
    @EnvironmentObject var app: AppState
    @Binding var path: [BrowserRoute]
    /// Present the map (the walk is loaded, or loading, by the time this is called).
    let onOpenMap: () -> Void

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Chromic", category: "nav")

    var body: some View {
        NavigationStack(path: $path) {
            AboutView(onSoundwalks: { path.append(.walks) }, onBack: nil)
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: BrowserRoute.self) { route in
                    switch route {
                    case .walks:
                        SoundwalksList(onOpen: { path.append(.walk($0)) },
                                       onArtist: goHome,
                                       onBack: { path.removeLast() })
                    case .walk(let walk):
                        WalkDetailView(walk: walk,
                                       onStart: { start(walk) },
                                       onArtist: goHome,
                                       onBack: { path.removeLast() })
                    }
                }
        }
        .onAppear { Self.log.info("browser opened at \(describe(path), privacy: .public)") }
        .onChange(of: path) { new in Self.log.info("path → \(describe(new), privacy: .public)") }
    }

    /// The artist's name, anywhere, goes home to About rather than pushing a second copy of it.
    private func goHome() { path.removeAll() }

    private func start(_ walk: RemoteWalk) {
        Self.log.info("start \(walk.id, privacy: .public) (current: \(app.current?.id ?? "none", privacy: .public))")
        // Already loaded: reloading would stop playback, so just return to its map.
        if app.current?.id != walk.id { app.openRemote(walk) }
        onOpenMap()     // a download keeps running behind the map's progress ring
    }

    private func describe(_ p: [BrowserRoute]) -> String {
        "About" + p.map { r -> String in
            switch r { case .walks: return " > Soundwalks"; case .walk(let w): return " > \(w.id)" }
        }.joined()
    }
}

/// One step of the browser stack. `Hashable` by the walk's id, so the same walk re-fetched with a
/// newer `updatedAt` is still the same page.
enum BrowserRoute: Hashable {
    case walks
    case walk(RemoteWalk)
}

// MARK: - Soundwalks

/// The list of Chromic's soundwalks as a column of cards over the wash, nearest first (Figma
/// "Home", `23:142`). Tapping a card opens its page; the artist's name goes home to About. Pull
/// down to refresh the catalog; long-press an installed card to remove its download.
///
/// Differs from Songitude's list on purpose: one flat list rather than geo-locked / anywhere
/// sections — the card says which — a custom title in the display face instead of a navigation
/// bar, and no download state on the card, because downloading starts from the walk's page and
/// shows on the map's play button.
private struct SoundwalksList: View {
    @EnvironmentObject var app: AppState
    let onOpen: (RemoteWalk) -> Void
    let onArtist: () -> Void
    let onBack: () -> Void

    var body: some View {
        ZStack {
            LivingBackdrop()
            ScrollView {
                VStack(spacing: 0) {
                    ScreenHeader(title: "soundwalks", onBack: onBack)
                    content
                        .padding(.top, 25)
                    credit
                        .padding(.top, 36)
                        .padding(.bottom, 40)
                }
            }
            .refreshable { await app.refreshCatalogAsync() }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .onAppear {
            // Order by distance every time the list opens; the fix lands asynchronously and
            // AppState re-sorts the catalog when it does.
            app.location.requestOneShotFix()
            app.catalog.resort(near: app.location.lastKnownLocation)
        }
    }

    /// The engine's credit, at the foot of the list. Opens Songitude's App Store page.
    private var credit: some View {
        Link(destination: Brand.songitudeAppStoreURL) {
            Text("Powered by Songitude")
                .font(Brand.body(13, weight: .medium))
                .foregroundStyle(Brand.Palette.onBackdrop.opacity(0.7))
                .underline()
        }
        .accessibilityLabel("Powered by Songitude. Opens the App Store.")
    }

    @ViewBuilder private var content: some View {
        if let e = app.catalogError {
            Notice(title: "Something went wrong", detail: e)
        }
        if app.catalog.loading && app.catalog.walks.isEmpty {
            HStack(spacing: 10) { ProgressView(); Text("Loading walks…") }
                .font(Brand.body(15)).foregroundStyle(Brand.Palette.subtitle)
                .padding(.top, 40)
        } else if let err = app.catalog.error, app.catalog.walks.isEmpty {
            Notice(title: "Couldn't load walks", detail: err)
        } else if app.catalog.walks.isEmpty {
            // There is always something published, so an empty catalog means we couldn't reach
            // it — not that no walks exist.
            Notice(title: "No connection",
                   detail: "\(Brand.name) needs the internet to find soundwalks. Pull down to try again.")
        } else {
            // 39pt between cards in the mock (173 → 476 with a 264pt card).
            VStack(spacing: 39) {
                ForEach(app.catalog.walks) { walk in
                    WalkCard(walk: walk, onOpen: { onOpen(walk) }, onArtist: onArtist)
                        .contextMenu {
                            if app.isDownloaded(walk.id) && app.downloadingWalkId != walk.id {
                                Button(role: .destructive) { app.deleteDownloaded(walk.id) } label: {
                                    Label("Remove download", systemImage: "xmark")
                                }
                            }
                        }
                }
            }
        }
    }
}

/// Screen title in the display face with an optional back chevron over its left edge — the header
/// every catalog screen shares (Figma: title 40pt centred at y≈88; chevron 46×43 at x=16).
struct ScreenHeader: View {
    let title: String
    var onBack: (() -> Void)? = nil

    var body: some View {
        ZStack {
            Text(title)
                .font(Brand.display(Brand.titleSize))
                .tracking(Brand.titleTracking)
                .foregroundStyle(Brand.Palette.onBackdrop)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 62)   // clear of the chevron on both sides, so it stays centred
                .frame(maxWidth: .infinity)
            if let onBack {
                HStack {
                    Button(action: onBack) {
                        BrandIcon(name: "IconBack", height: 24)
                            .frame(width: 46, height: 43)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Back")
                    Spacer()
                }
                .padding(.leading, 16)
            }
        }
        .padding(.top, 36)
        .frame(minHeight: 96, alignment: .center)
    }
}

/// One walk in the list: artwork on top, title and a one-line subtitle beneath, on a pale card.
/// (Figma "Stacked card": 360×264, r12, #FEF7FF on a #CAC4D0 hairline; media 188pt; text 16/14.)
/// The subtitle is the artist's name — a link to About — with the distance at the trailing edge.
private struct WalkCard: View {
    @EnvironmentObject var app: AppState
    let walk: RemoteWalk
    let onOpen: () -> Void
    let onArtist: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Brand.cardRadius, style: .continuous)
        VStack(spacing: 0) {
            ArtworkBox(url: walk.artUrl, aspect: Brand.cardMediaAspect)
            VStack(alignment: .leading, spacing: 2) {
                Text(walk.name)
                    .font(Brand.body(16))
                    .foregroundStyle(Brand.Palette.title)
                    .lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    ArtistLink(name: walk.creatorText, action: onArtist)
                    Spacer(minLength: 8)
                    if let place = whereabouts {
                        Text(place)
                            .font(Brand.body(13))
                            .foregroundStyle(Brand.Palette.subtitle)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .background(Brand.Palette.card)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Brand.Palette.cardStroke, lineWidth: 1))
        .padding(.horizontal, Brand.cardInset)
        .contentShape(Rectangle())
        // The card is the tap target for the walk; the artist button inside it takes precedence
        // over this gesture, so the name goes to About and everywhere else goes to the walk.
        .onTapGesture(perform: onOpen)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Open walk", onOpen)
    }

    /// Where the walk is, from here; a portable walk says so instead. nil without a fix.
    private var whereabouts: String? {
        if walk.portable == true { return "Listen from anywhere" }
        if let m = distanceMeters { return distanceText(m) }
        return nil
    }

    private var distanceMeters: Double? {
        guard let here = app.location.lastKnownLocation, let c = walk.centerCoord else { return nil }
        return CLLocation(latitude: here.latitude, longitude: here.longitude)
            .distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
    }
    /// Same thresholds as Songitude's row: feet up close, tenths of a mile, then whole miles.
    private func distanceText(_ m: Double) -> String {
        let miles = m / 1609.344
        if miles < 0.1 { return "\(Int((m * 3.28084 / 10).rounded() * 10)) ft away" }
        if miles < 10 { return String(format: "%.1f miles away", miles) }
        return "\(Int(miles.rounded())) miles away"
    }
}

/// The artist's name as a link to About — the same line on the card and on the walk's page.
struct ArtistLink: View {
    let name: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(name.isEmpty ? Brand.name : name)
                // The back chevron, turned round: the set has no forward one.
                BrandIcon(name: "IconBack", height: 10).scaleEffect(x: -1)
            }
            .font(Brand.body(14))
            .foregroundStyle(Brand.Palette.title)
            .lineLimit(1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("About \(name.isEmpty ? Brand.name : name)")
    }
}

/// Artwork filling a box of fixed aspect ratio at whatever width it is given. The image is framed
/// to the measured box before it is clipped, so a `scaledToFill` image can never widen the layout.
struct ArtworkBox<Content: View>: View {
    let aspect: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { g in
            content()
                .frame(width: g.size.width, height: g.size.height)
                .clipped()
        }
        .background(Brand.Palette.mediaFill)
        .aspectRatio(aspect, contentMode: .fit)
    }
}

extension ArtworkBox where Content == WalkArtwork {
    /// A walk's catalog artwork.
    init(url: String?, aspect: CGFloat) { self.init(aspect: aspect) { WalkArtwork(url: url) } }
}

/// Loading / error / offline copy, set on a card so it reads over the wash.
private struct Notice: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Brand.body(16, weight: .semibold)).foregroundStyle(Brand.Palette.title)
            Text(detail).font(Brand.body(14)).foregroundStyle(Brand.Palette.subtitle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Brand.Palette.card, in: RoundedRectangle(cornerRadius: Brand.cardRadius, style: .continuous))
        .padding(.horizontal, Brand.cardInset)
    }
}

/// Navigation target for an artist page. Kept for `ArtistPageView`, which Chromic no longer
/// reaches (About is the one artist page) but still compiles in step with Songitude.
struct ArtistRoute: Hashable, Identifiable {
    let id: String
    let name: String
}
