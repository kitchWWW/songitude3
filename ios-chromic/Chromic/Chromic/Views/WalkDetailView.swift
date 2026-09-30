import SwiftUI

/// A walk's own page (Figma "Project Page", `1:1352`): its title in the display face, the artwork
/// edge to edge, one amber Start button, the artist, and the description. Opening the page starts
/// the walk's download; Start loads the walk and goes straight to the map — this page is where Songitude's intro card used to do its reading, so the
/// card itself is switched off (`Brand.showsIntroCard`).
struct WalkDetailView: View {
    @EnvironmentObject var app: AppState
    let walk: RemoteWalk
    let onStart: () -> Void
    let onArtist: () -> Void
    let onBack: () -> Void

    var body: some View {
        ZStack {
            Backdrop()
            ScrollView {
                VStack(spacing: 0) {
                    ScreenHeader(title: walk.name, onBack: onBack)
                    media
                        .padding(.top, 41)   // title block ends ≈157, media starts 198
                    // Start sits straight under the photo, above the copy: the mock had it after
                    // the text, which put it below the fold on a walk with a real description.
                    startButton
                        .padding(.horizontal, Brand.pageInset)
                        .padding(.top, 24)
                    // "by chromic duo ›" — so the artist is a tap away from every walk. Sits
                    // where the copy's left edge is.
                    HStack(spacing: 4) {
                        Text("by").font(Brand.body(14)).foregroundStyle(Brand.Palette.subtitle)
                        ArtistLink(name: walk.creatorText, action: onArtist)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Brand.pageInset)
                    .padding(.top, 22)
                    if !about.isEmpty {
                        // Same markdown treatment as everywhere else the description appears.
                        MarkdownBody(source: about)
                            .font(Brand.body(16))
                            .lineSpacing(4)          // 22pt line height on 16pt type
                            .foregroundStyle(Brand.Palette.bodyText)
                            .padding(.horizontal, Brand.pageInset)
                            .padding(.top, 14)
                    }
                    Spacer().frame(height: 48)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        // Start downloading while they read, so Start has little or nothing left to wait for.
        // Start joins this download (see `AppState.prefetch`); a cached walk costs nothing.
        .onAppear { app.prefetch(walk) }
    }

    /// The catalog's copy first — it reflects an edit without republishing the bundle — then the
    /// bundle's own `about`, for a walk that predates the catalog carrying one.
    private var about: String {
        if let a = walk.about, !a.isEmpty { return a }
        if app.current?.id == walk.id, let a = app.current?.map.about { return a }
        return ""
    }

    /// Full-bleed artwork at the mock's 376×261, on the card's media fill while it loads, with the
    /// hairline top and bottom that separates it from the wash.
    private var media: some View {
        ArtworkBox(url: walk.artUrl, aspect: Brand.pageMediaAspect)
            .overlay(alignment: .top) { Brand.Palette.cardStroke.frame(height: 1) }
            .overlay(alignment: .bottom) { Brand.Palette.cardStroke.frame(height: 1) }
    }

    /// Always reads "Start". For a walk that is already loaded it doesn't reload (that would stop
    /// playback) — `WalksBrowserView.start` just returns to its map, where the walk is as they left it.
    private var startButton: some View {
        Button("Start", action: onStart)
            .buttonStyle(BrandPrimaryButtonStyle())
            .accessibilityLabel("Start \(walk.name)")
    }
}

/// Lets a `RemoteWalk` be a navigation value. Identity is the catalog id: the same walk re-fetched
/// with a newer `updatedAt` is still the same page.
extension RemoteWalk: Hashable {
    static func == (a: RemoteWalk, b: RemoteWalk) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
