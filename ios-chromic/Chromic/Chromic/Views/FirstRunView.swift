import SwiftUI

/// The first launch, as one scene in two steps (Figma "App Loading", `72:154`):
///
/// 1. **Landing** — CHROMIC in the display face across the middle of the wash, white squiggles,
///    stars and dots drifting over it. Tap anywhere to go on.
/// 2. **Permission** — the title lifts to the top, the app icon and the location ask fade in
///    beneath it, the squiggles keep drifting. `OnboardingView` owns that ask.
///
/// Replaces Songitude's splash animation and its logo hand-off. Shown only until onboarding is
/// complete; after that the app opens on the map.
struct FirstRunView: View {
    @EnvironmentObject var app: AppState
    @State private var step: Step = .landing

    private enum Step { case landing, permission }

    /// Title placement as a fraction of the screen height (mock: text centre at 331/812 on the
    /// landing; the permission step lifts it to sit below the status bar).
    private static let landingTitleY: CGFloat = 0.41
    private static let permissionTitleY: CGFloat = 0.14
    /// 64pt on the landing (the mock's), scaled rather than re-set on the permission step so the
    /// move is one continuous animation instead of a font swap.
    private static let titleSize: CGFloat = 64
    private static let permissionTitleScale: CGFloat = 0.7

    var body: some View {
        GeometryReader { geo in
            ZStack {
                LivingBackdrop()
                // On the permission step the field thins out towards the bottom, so nothing
                // drifts through the copy and the buttons.
                SquiggleField()
                    .mask(
                        LinearGradient(stops: [.init(color: .black, location: 0),
                                               .init(color: .black, location: step == .landing ? 1 : 0.55),
                                               .init(color: .black.opacity(step == .landing ? 1 : 0), location: step == .landing ? 1 : 0.72)],
                                       startPoint: .top, endPoint: .bottom)
                    )

                if step == .permission {
                    OnboardingView(topInset: geo.size.height * Self.permissionTitleY + 60)
                        .transition(.opacity)
                }

                Text("chromic")
                    .font(Brand.display(Self.titleSize))
                    .tracking(-0.64)
                    .foregroundStyle(Brand.Palette.onBackdrop)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 24)
                    .scaleEffect(step == .landing ? 1 : Self.permissionTitleScale)
                    .position(x: geo.size.width / 2,
                              y: geo.size.height * (step == .landing ? Self.landingTitleY : Self.permissionTitleY))
                    .allowsHitTesting(false)

                if step == .landing {
                    // The whole screen is the button. The hint sits where the mock keeps its
                    // "tag line?" placeholder; swap it for the real tagline when there is one.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(perform: begin)
                        .accessibilityElement()
                        .accessibilityLabel("\(Brand.name). Tap to begin")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction(named: "Begin", begin)
                    Text("Tap to begin")
                        .font(Brand.body(16, weight: .semibold))
                        .foregroundStyle(Brand.Palette.onBackdrop.opacity(0.6))
                        .position(x: geo.size.width / 2, y: geo.size.height * 0.87)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.55), value: step)
    }

    private func begin() { step = .permission }
}

// MARK: - Drifting squiggles

/// The welcome-screen decorations (Drive "Welcome Screen Squiggles", trimmed to `Squiggle1–3`,
/// `Star1–3`, `Dot1–3`) drifting slowly across the screen, each on its own heading with a gentle
/// sway and a slow turn, wrapping round when it leaves. One `Canvas` under a `TimelineView`, so
/// it is a single draw per frame however many sprites there are. Reduce Motion freezes it.
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
