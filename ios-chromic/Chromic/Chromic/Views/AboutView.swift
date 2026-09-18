import SwiftUI

/// About Chromic (Figma "About", `24:2062`, titled with the name rather than "about"): their photo edge to edge, the bio from
/// their published profile, and link icons. The app's home — the root of the browser stack — and
/// where the artist's name on every walk leads back to. "Soundwalks", under the photo, is the way
/// in to the list.
///
/// The bio is the live profile (`artists/<id>.json`, edited from the Songitude editor) so a rewrite
/// reaches the app without a release. The photo ships in the app: the profile format has no image.
struct AboutView: View {
    @EnvironmentObject var app: AppState
    let onSoundwalks: () -> Void
    /// nil at the root of the stack, where there is nothing to go back to.
    var onBack: (() -> Void)? = nil

    private var profile: ArtistProfile? { app.artists.profile(Brand.artistID) }

    var body: some View {
        ZStack {
            Backdrop()
            ScrollView {
                VStack(spacing: 0) {
                    ScreenHeader(title: "chromic", onBack: onBack)
                    ArtworkBox(aspect: Brand.pageMediaAspect) { Image("ArtistPhoto").resizable().scaledToFill() }
                        .overlay(alignment: .top) { Brand.Palette.cardStroke.frame(height: 1) }
                        .overlay(alignment: .bottom) { Brand.Palette.cardStroke.frame(height: 1) }
                        .padding(.top, 41)
                    Button("Soundwalks", action: onSoundwalks)
                        .buttonStyle(BrandPrimaryButtonStyle())
                        .padding(.horizontal, Brand.pageInset)
                        .padding(.top, 24)
                    bio
                        .padding(.horizontal, Brand.pageInset)
                        .padding(.top, 24)
                    links
                        .padding(.horizontal, Brand.pageInset - 4)
                        .padding(.top, 40)
                        .padding(.bottom, 48)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .onAppear { app.artists.load(Brand.artistID) }
    }

    @ViewBuilder private var bio: some View {
        if let text = profile?.bio, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            MarkdownBody(source: text)
                .font(Brand.body(16))
                .lineSpacing(4)
                .foregroundStyle(Brand.Palette.bodyText)
        } else if app.artists.failed.contains(Brand.artistID) || profile != nil {
            Text("\(Brand.name) hasn't written a bio yet.")
                .font(Brand.body(16))
                .foregroundStyle(Brand.Palette.subtitle)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ProgressView().frame(maxWidth: .infinity)
        }
    }

    /// Instagram, then the website — stacked, as the mock has them. Each shows only once its URL
    /// is known (`Brand.instagramURL` / `Brand.websiteURL`).
    @ViewBuilder private var links: some View {
        VStack(alignment: .leading, spacing: 15) {
            if let url = Brand.instagramURL {
                Link(destination: url) {
                    InstagramGlyph().frame(width: 24, height: 24)
                }
                .accessibilityLabel("\(Brand.name) on Instagram")
            }
            if let url = Brand.websiteURL {
                Link(destination: url) {
                    Image(systemName: "globe")
                        .font(.system(size: 20, weight: .regular))
                        .frame(width: 24, height: 24)
                }
                .accessibilityLabel("\(Brand.name)'s website")
            }
        }
        .foregroundStyle(Brand.Palette.onBackdrop)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The Instagram mark as line art, to sit beside SF Symbols' `globe` at the same weight: a rounded
/// square, the lens, and the flash dot.
private struct InstagramGlyph: View {
    var body: some View {
        GeometryReader { g in
            let s = min(g.size.width, g.size.height)
            let w = s * 0.085
            ZStack {
                RoundedRectangle(cornerRadius: s * 0.28, style: .continuous)
                    .strokeBorder(lineWidth: w)
                Circle()
                    .strokeBorder(lineWidth: w)
                    .frame(width: s * 0.46, height: s * 0.46)
                Circle()
                    .frame(width: w * 1.4, height: w * 1.4)
                    .offset(x: s * 0.24, y: -s * 0.24)
            }
            .frame(width: s, height: s)
        }
    }
}
