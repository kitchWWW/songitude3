import SwiftUI

/// The "about this walk" card that greets a listener when they open a walk: title, artist (linked
/// to their page) and the walk's description, over the walk's own backdrop colour.
///
/// Dismissed by the ✕ in its top-left, by tapping outside it, or by the map's own play button —
/// which stays visible and interactive above this card, so one button controls the whole walk.
struct WalkIntroCard: View {
    @EnvironmentObject var app: AppState
    @Environment(\.colorScheme) private var colorScheme
    @State private var contentHeight: CGFloat = 0

    let experience: Experience
    let remote: RemoteWalk?               // catalog entry, when the walk came from the server
    let onArtist: (ArtistRoute) -> Void
    let onDismiss: () -> Void
    let onRecenter: () -> Void

    /// Resolves the walk's authored backdrop. "artist" follows the artist's page colour so a
    /// rename of their palette reaches every walk of theirs; nil (or an artist with no colour of
    /// their own) leaves the card looking like the rest of the app.
    private var theme: (color: Color, isDark: Bool)? {
        guard let raw = experience.map.introColor else { return nil }
        if raw == Self.followArtist {
            guard let id = remote?.artistId else { return nil }
            return HexColor.parse(app.artists.profile(id)?.bgColor)
        }
        return HexColor.parse(raw)
    }
    static let followArtist = "artist"
    private var creator: String {
        let fromCatalog = remote?.creatorText ?? ""
        return fromCatalog.isEmpty ? (experience.map.creator ?? "") : fromCatalog
    }
    private var about: String { (remote?.about?.isEmpty == false ? remote?.about : experience.map.about) ?? "" }

    var body: some View {
        ZStack {
            // No dimming behind the card — the map stays at full brightness. This layer exists
            // only to catch taps outside the card.
            Color.clear.contentShape(Rectangle()).ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

            // A GeometryReader gives the real space available, so the scrolling variant can be
            // bounded to it. Without that the content could out-grow the card and spill past its
            // backdrop — which is what left the title and ✕ sitting outside the rectangle.
            GeometryReader { geo in
                VStack(alignment: .leading, spacing: 0) {
                    // Title and close share a row, so the ✕ sits at the title's level on the right
                    // and stays put while the copy below it scrolls.
                    HStack(alignment: .top, spacing: 12) {
                        Text(experience.displayName)
                            .font(.title.bold())
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button(action: onDismiss) {
                            Image(systemName: "xmark")
                                .font(.system(size: 13, weight: .bold))
                                .padding(8)
                                .background(.thinMaterial, in: Circle())
                        }
                        .accessibilityLabel("Close")
                    }
                    .padding(.bottom, 10)

                    // Measure the text and give the scroll view exactly that height, capped by the
                    // space available. ViewThatFits couldn't do this: whenever it fell back to the
                    // scrolling variant that variant took its full fixed height, leaving a slab of
                    // empty card under short text.
                    ScrollView {
                        details.background(GeometryReader { g in
                            Color.clear.preference(key: CardContentHeightKey.self, value: g.size.height)
                        })
                    }
                    .frame(height: min(max(contentHeight, 1), max(120, geo.size.height - 110)))
                    .onPreferenceChange(CardContentHeightKey.self) { contentHeight = $0 }
                }
                .padding(20)
                // .background sizes itself to the view, so the card stays tight around its text —
                // unlike a RoundedRectangle in a ZStack, which is greedy and fills the space.
                .background(theme?.color ?? Color(.systemBackground),
                            in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(.primary.opacity(0.08)))
                .shadow(radius: 30, y: 10)
                // With an authored backdrop, flip every system colour to suit it; otherwise inherit.
                .environment(\.colorScheme, theme.map { $0.isDark ? .dark : .light } ?? colorScheme)
                .frame(maxWidth: 420)
                .frame(width: geo.size.width, height: geo.size.height)   // centre it in the space
            }
            .padding(.horizontal, 24)
            .padding(.top, 74)   // sit well clear of the status bar and the top controls
            .padding(.bottom, 150)   // leave the map's play button uncovered
        }
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
        .onAppear {
            // Following the artist needs their profile, which lives outside the bundle.
            if experience.map.introColor == Self.followArtist, let id = remote?.artistId {
                app.artists.load(id)
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !creator.isEmpty { artistLine }

            if !about.isEmpty {
                // Same markdown treatment as an artist bio: headings, lists, quotes, links.
                MarkdownBody(source: about)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            // Only transportable walks can be re-placed, and only once the listener has seen the
            // card before — the first read should just be the walk's own words.
            if experience.map.startAnchor != nil && app.introShowings > 1 {
                Button(action: onRecenter) {
                    Label("Recenter here", systemImage: "location.circle")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var artistLine: some View {
        if let id = remote?.artistId, !id.isEmpty {
            Button { onArtist(ArtistRoute(id: id, name: creator)) } label: {
                HStack(spacing: 0) {
                    Text("by ").foregroundStyle(.secondary)
                    Text(creator).foregroundStyle(.tint)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tint)
                        .padding(.leading, 4)
                }
                .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.plain)
        } else {
            Text("by \(creator)").font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

/// Natural height of the card's text, so the scroll view can hug it instead of stretching.
private struct CardContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
