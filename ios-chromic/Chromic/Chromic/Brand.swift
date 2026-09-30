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

    /// Where the About page's link icons go (confirmed by Brian, 2026-09-30). Optional so a
    /// missing one simply hides its icon.
    static let instagramURL: URL? = URL(string: "https://www.instagram.com/chromic_duo/")
    static let websiteURL: URL? = URL(string: "https://chromic.space")

    /// Songitude on the App Store (App Store Connect id 6787213575) — the "Powered by Songitude"
    /// credit under the list of walks links here.
    static let songitudeAppStoreURL = URL(string: "https://apps.apple.com/app/id6787213575")!

    /// Songitude greets a freshly opened walk with an "about" card over the map. Here that
    /// information lives on the walk's own page, and Start goes straight to the map — so the card
    /// never shows. `AppState.maybeShowIntroCard`/`presentIntroCard` check this.
    static let showsIntroCard = false

    // MARK: Flow

    /// How long the app can sit in the background and still come back exactly where it was left.
    /// Longer than this, and with no walk under way, reopening starts over at the welcome page and
    /// lands on Soundwalks — the listener has most likely put the phone away and is coming back to
    /// choose a walk, not to finish reading a page they no longer remember opening. Five minutes
    /// covers answering a message or checking a map in another app. A walk in progress (playing,
    /// or its map on screen) is never reset, however long the phone was pocketed.
    /// Twin: `Brand.RESUME_WINDOW_MS` on Android.
    static let resumeWindow: TimeInterval = 5 * 60

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

    // MARK: Icons

    /// Soundwalks' way back to About. It borrows the cloud the map's settings button wears, as a
    /// matched pair, until Dorothy's gear arrives — then only the settings button changes (its
    /// asset is named in `ContentView`), and this stays the cloud. Size and chip match that button.
    enum AboutButton {
        static let icon = "IconCloud"
        static let iconHeight: CGFloat = 20
        static let size: CGFloat = 44
    }
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

// MARK: - Drifting squiggles

/// The welcome-screen decorations (Drive "Welcome Screen Squiggles", trimmed to `Squiggle1–3`,
/// `Star1–3`, `Dot1–3`) drifting slowly across the screen, each on its own heading with a gentle
/// sway and a slow turn, wrapping round when it leaves. One `Canvas` under a `TimelineView`, so
/// it is a single draw per frame however many sprites there are. Reduce Motion freezes it.
///
/// Over the first-run scene (masked there to thin out behind the permission copy) and over the
/// Soundwalks list, where it sits between the wash and the cards. It never takes a touch.
struct SquiggleField: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sprites = Sprite.scatter()
    @State private var start = Date()

    private struct Sprite {
        let name: String
        var origin: CGPoint      // unit square
        let heading: CGVector    // unit lengths per second
        let scale: CGFloat
        let spin: Double         // radians per second
        let swayPhase: Double
        let swayPeriod: Double   // seconds
        let opacity: Double

        /// A fresh, random arrangement: enough pieces to read as a field, none big enough to
        /// crowd the title. Roughly the mock's mix — more dots than stars, more stars than squiggles.
        static func scatter() -> [Sprite] {
            let kinds = ["Squiggle1", "Squiggle2", "Squiggle3", "Squiggle2",
                         "Star1", "Star2", "Star3", "Star1", "Star3",
                         "Dot1", "Dot2", "Dot3", "Dot1", "Dot2", "Dot3", "Dot2", "Dot1", "Dot3"]
            return kinds.map { name in
                // Mostly upward, a little sideways: the squiggles read as rising through the wash.
                let angle = Double.random(in: -Double.pi * 0.35 ... Double.pi * 0.35) - Double.pi / 2
                let speed = Double.random(in: 0.010 ... 0.022)   // 60–120 s to cross the screen
                return Sprite(name: name,
                              // Spelled out: `.random` here resolves to CGPoint's Int initialiser,
                              // which pins every sprite to a corner.
                              origin: CGPoint(x: CGFloat.random(in: 0...1), y: CGFloat.random(in: 0...1)),
                              heading: CGVector(dx: cos(angle) * speed, dy: sin(angle) * speed),
                              scale: name.hasPrefix("Dot") ? .random(in: 0.8...1.2) : .random(in: 0.8...1.3),
                              spin: .random(in: -0.12 ... 0.12),
                              swayPhase: .random(in: 0 ... 2 * .pi),
                              swayPeriod: .random(in: 6 ... 11),
                              opacity: .random(in: 0.8 ... 1.0))
            }
        }
    }

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSince(start)
                // Margin so a sprite finishes leaving before it re-enters on the other side.
                let m: CGFloat = 0.12
                for s in sprites {
                    guard let image = context.resolve(Image(s.name)) as GraphicsContext.ResolvedImage? else { continue }
                    var x = (s.origin.x + s.heading.dx * t + m).truncatingRemainder(dividingBy: 1 + 2 * m)
                    var y = (s.origin.y + s.heading.dy * t + m).truncatingRemainder(dividingBy: 1 + 2 * m)
                    if x < 0 { x += 1 + 2 * m }
                    if y < 0 { y += 1 + 2 * m }
                    x -= m; y -= m
                    let sway = sin(t * 2 * .pi / s.swayPeriod + s.swayPhase) * 10
                    let at = CGPoint(x: x * size.width + sway, y: y * size.height)

                    context.drawLayer { layer in
                        layer.opacity = s.opacity
                        layer.translateBy(x: at.x, y: at.y)
                        layer.rotate(by: .radians(s.spin * t))
                        layer.scaleBy(x: s.scale, y: s.scale)
                        let sz = image.size
                        layer.draw(image, in: CGRect(x: -sz.width / 2, y: -sz.height / 2,
                                                     width: sz.width, height: sz.height))
                    }
                }
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

// MARK: Creator name

extension Brand {
    /// The artist was "Chromic Duo" and is now just "Chromic". Walks already published under the old
    /// name carry it in their map.json and catalog entry, and those can't be re-published from the
    /// back end — so the app renames them for display instead. Every reader of a walk's creator or
    /// an artist's name goes through here (`RemoteWalk.creatorText`, `SoundMap.creatorText`,
    /// `ArtistProfile.displayName`); the stored and fetched data are never rewritten. Any other
    /// creator passes through untouched. Chromic-only — see `../SYNC.md`.
    /// Twin: `Brand.displayCreator` on Android.
    static func displayCreator(_ name: String?) -> String {
        guard let name else { return "" }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.caseInsensitiveCompare("Chromic Duo") == .orderedSame ? Brand.name : name
    }
}
