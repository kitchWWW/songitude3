import SwiftUI

/// The Songitude mark drawn as vectors: a half globe on the left, three outward sound waves on the
/// right. Vector rather than the AppLogo raster so the splash can animate the waves individually —
/// and so the splash logo and the onboarding logo are literally the same view, making the handoff
/// between them seamless.
struct SongitudeMark: View {
    /// Opacity for wave `i` (0 = innermost). Lets the splash run a pulse outward through them.
    var waveOpacity: (Int) -> Double = { _ in 1 }
    var stroke: Color = .white

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let r = s * 0.40
            let lw = s * 0.058

            ZStack {
                globe(c: c, r: r)
                    .stroke(stroke, style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))

                ForEach(0..<3, id: \.self) { i in
                    wave(c: c, r: r, index: i)
                        .stroke(stroke.opacity(waveOpacity(i)),
                                style: StrokeStyle(lineWidth: lw, lineCap: .round))
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    /// Left hemisphere: outer arc, the flat meridian edge, two latitudes and one bulging meridian.
    private func globe(c: CGPoint, r: CGFloat) -> Path {
        var p = Path()
        // Angles run clockwise from +x with y pointing down, so 90°→270° sweeps the left half.
        p.addArc(center: c, radius: r, startAngle: .degrees(90), endAngle: .degrees(270), clockwise: false)

        p.move(to: CGPoint(x: c.x, y: c.y - r))
        p.addLine(to: CGPoint(x: c.x, y: c.y + r))

        for dy in [-0.36 * r, 0.36 * r] {
            let halfWidth = sqrt(max(0, r * r - dy * dy))
            p.move(to: CGPoint(x: c.x - halfWidth, y: c.y + dy))
            p.addLine(to: CGPoint(x: c.x, y: c.y + dy))
        }

        p.move(to: CGPoint(x: c.x, y: c.y - r))
        p.addCurve(to: CGPoint(x: c.x, y: c.y + r),
                   control1: CGPoint(x: c.x - 0.78 * r, y: c.y - 0.52 * r),
                   control2: CGPoint(x: c.x - 0.78 * r, y: c.y + 0.52 * r))
        return p
    }

    /// One of the three concentric waves: wider arcs the further out they sit.
    private func wave(c: CGPoint, r: CGFloat, index: Int) -> Path {
        let radii: [CGFloat] = [0.38, 0.69, 1.0]
        let spans: [Double] = [52, 66, 78]
        var p = Path()
        p.addArc(center: c, radius: r * radii[index],
                 startAngle: .degrees(-spans[index]), endAngle: .degrees(spans[index]),
                 clockwise: false)
        return p
    }
}

/// The app-icon tile: the mark on its black-metal gradient, rounded like the home-screen icon.
struct LogoTile: View {
    var waveOpacity: (Int) -> Double = { _ in 1 }
    /// Fade of the icon tile itself. The splash starts at 0 so the mark floats on its own backdrop
    /// with no hard icon edges, then fades the tile in as it flies to the onboarding logo's slot.
    var tileOpacity: Double = 1
    var cornerFraction: CGFloat = 0.22

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                LinearGradient(colors: [Color(red: 0.23, green: 0.24, blue: 0.27),
                                        Color(red: 0.01, green: 0.01, blue: 0.01)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .opacity(tileOpacity)
                SongitudeMark(waveOpacity: waveOpacity)
                    .frame(width: s * 0.68, height: s * 0.68)
            }
            .frame(width: s, height: s)
            .clipShape(RoundedRectangle(cornerRadius: s * cornerFraction, style: .continuous))
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// Publishes where the onboarding logo sits, so the splash knows exactly where to fly to.
struct LogoFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}
