import SwiftUI

/// Everything that makes this build Chromic's app rather than Songitude.
///
/// This target is a fork of `ios/` — same engine, same flows, same bundle format — and the two are
/// kept in step by hand (see `../SYNC.md`). Everything brand-specific is gathered here so that a
/// diff against `ios/` shows engine and flow changes, not a scattering of renamed strings.
///
/// Values come from the "CD App design" Figma (Home `23:142`, Project Page `1:1352`).
enum Brand {
    /// The name the listener sees: onboarding, the lock screen, error copy.
    static let name = "Chromic"

    /// The one artist whose walks this app lists. Everything else in the public catalog is
    /// filtered out in `RemoteCatalog.refresh` — the catalog itself is shared with Songitude.
    static let artistID = "80cda9dee7513416"

    /// Where the About page's link icons go. Neither is known yet (nothing in the profile, the
    /// Drive docs or DNS), so both icons stay hidden until these are filled in.
    static let instagramURL: URL? = nil
    static let websiteURL: URL? = nil

    /// Songitude on the App Store (App Store Connect id 6787213575) — the "Powered by Songitude"
    /// credit under the list of walks links here.
    static let songitudeAppStoreURL = URL(string: "https://apps.apple.com/app/id6787213575")!

    /// Songitude greets a freshly opened walk with an "about" card over the map. Here that
    /// information lives on the walk's own page, and Start goes straight to the map — so the card
    /// never shows. `AppState.maybeShowIntroCard`/`presentIntroCard` check this.
    static let showsIntroCard = false

    // MARK: Type

    /// Julius Sans One (OFL, bundled in `Fonts/`): the design's display face for screen titles.
    /// It has capitals only, so "soundwalks" sets as SOUNDWALKS whatever the string's case.
    static func display(_ size: CGFloat) -> Font { .custom("JuliusSansOne-Regular", size: size) }

    /// Body copy is Roboto/Inter in the mock; the system font is the same idea on iOS and needs no
    /// licence. Kept as a function so a body face can be swapped in later in one place.
    static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    // MARK: Colour

    /// Material-3 card colours the mock was built from, plus the Start button's amber.
    enum Palette {
        static let card        = Color(hex: 0xFEF7FF)
        static let cardStroke  = Color(hex: 0xCAC4D0)
        static let mediaFill   = Color(hex: 0xECE6F0)
        static let title       = Color(hex: 0x1D1B20)
        static let subtitle    = Color(hex: 0x49454F)
        static let bodyText    = Color(hex: 0x1E1E1E)
        static let start       = Color(hex: 0xE5A000)
        static let startLabel  = Color(hex: 0x2C2C2C)
        /// Screen titles and the back chevron sit directly on the watercolor.
        static let onBackdrop  = Color.black
    }

    // MARK: Metrics

    /// Screen titles: 40pt Julius, −0.4 tracking, centred (Figma "soundwalks", "garden of memories").
    static let titleSize: CGFloat = 40
    static let titleTracking: CGFloat = -0.4
    /// Walk cards on Home: 8pt from the screen edge, 12pt corners, image 360×188 → 1.915:1.
    static let cardInset: CGFloat = 8
    static let cardRadius: CGFloat = 12
    static let cardMediaAspect: CGFloat = 360.0 / 188.0
    /// Project page: 50pt side margins for the copy and the Start button; the image runs edge to edge
    /// at 376×261 → 1.44:1.
    static let pageInset: CGFloat = 50
    static let pageMediaAspect: CGFloat = 376.0 / 261.0
}

/// The watercolor wash behind every catalog screen (Drive "Background/Combined Background.png",
/// the fill the Figma frames use), scaled to fill the screen.
///
/// Sized by `Color.clear`, with the image as an overlay: a `scaledToFill` image placed directly in a
/// ZStack reports its *filled* size, and the ZStack — and every screen laid out inside it — grew to
/// 655pt wide on a 402pt phone.
struct Backdrop: View {
    var body: some View {
        Color.clear
            .overlay(Image("Backdrop").resizable().scaledToFill())
            .clipped()
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}

/// One of Dorothy's hand-drawn icons (`Icon*` imagesets), sized by height so its own proportions
/// hold. These replace SF Symbols wherever the set has a counterpart: back, close, play, pause,
/// ±15 s, and the cloud that stands in for the settings gear.
struct BrandIcon: View {
    let name: String
    let height: CGFloat
    var body: some View {
        Image(name).resizable().scaledToFit().frame(height: height)
    }
}

/// The mock's one button: 50pt, r8, amber, dark semibold label (Figma "Button" on the Project
/// Page). Used for Start and for Continue on the permission screen.
struct BrandPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Brand.body(16, weight: .semibold))
            .foregroundStyle(Brand.Palette.startLabel)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(Brand.Palette.start, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// The wash, alive: Dorothy's five paint layers (`TrBk - Layer 1–5` → `Wash1–5`), each zoomed a
/// little and swaying on its own slow x and y periods, over the static wash so a band drifting
/// aside can never open a gap. Used behind Home and the first-run scene; screens that are mostly
/// reading (the walk page, About) keep the still `Backdrop`.
///
/// Travel is ±5% of the screen; the 1.12× zoom leaves 6% each side, so at the peak of any layer's
/// swing there is still no edge on screen. Periods were written as 3–10 s and then slowed to a fifth
/// (`pace`) — 15–50 s a swing — after the first cut read as restless; they stay mutually irrational
/// enough that the composite never visibly repeats. Reduce Motion holds it still.
struct LivingBackdrop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    private struct Layer { let name: String; let xPeriod: Double; let yPeriod: Double; let phase: Double }
    private static let layers: [Layer] = [
        Layer(name: "Wash1", xPeriod: 9.7, yPeriod: 6.1, phase: 0.0),
        Layer(name: "Wash2", xPeriod: 4.3, yPeriod: 8.9, phase: 1.3),
        Layer(name: "Wash3", xPeriod: 7.4, yPeriod: 3.7, phase: 2.6),
        Layer(name: "Wash4", xPeriod: 3.1, yPeriod: 9.9, phase: 3.9),
        Layer(name: "Wash5", xPeriod: 6.6, yPeriod: 5.2, phase: 5.2),
    ]
    private static let zoom: CGFloat = 1.12
    private static let travel: CGFloat = 0.05
    private static let pace: Double = 0.2

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            TimelineView(.animation(paused: reduceMotion)) { timeline in
                let t = timeline.date.timeIntervalSince(start) * Self.pace
                ZStack {
                    Image("Backdrop").resizable().scaledToFill()
                        .frame(width: size.width * Self.zoom, height: size.height * Self.zoom)
                        .position(x: size.width / 2, y: size.height / 2)
                    ForEach(Self.layers, id: \.name) { layer in
                        let dx = sin(t * 2 * .pi / layer.xPeriod + layer.phase) * Self.travel * size.width
                        let dy = sin(t * 2 * .pi / layer.yPeriod + layer.phase * 0.7) * Self.travel * size.height
                        Image(layer.name).resizable().scaledToFill()
                            .frame(width: size.width * Self.zoom, height: size.height * Self.zoom)
                            .position(x: size.width / 2 + dx, y: size.height / 2 + dy)
                    }
                }
                .frame(width: size.width, height: size.height)
                .clipped()
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

extension Color {
    /// `Color(hex: 0xRRGGBB)` — the mock's colours are all opaque sRGB hex.
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}
