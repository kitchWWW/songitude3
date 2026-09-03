import SwiftUI
import MapKit
import CoreImage

/// MapKit map that renders the experience's shapes as colored overlays (matching the editor),
/// applies the re-center offset, shows the user, and highlights areas that are sounding.
struct MapOverlayView: UIViewRepresentable {
    let shapes: [SoundShape]
    let routes: [SuggestedRoute]
    /// Free-standing markings drawn over the map. Purely visual, like routes.
    let labels: [MapLabel]
    /// Where a label's artwork lives (the unpacked bundle's images/ folder). nil ⇒ text only.
    let imagesDirectory: URL?
    let offset: CoordinateOffset
    let soundingIDs: Set<String>
    let dialogueStates: [String: DialogueState]
    let dialogueColors: DialogueColors
    let centerOn: CLLocationCoordinate2D
    let experienceID: String
    /// The walk's authored look: outlined areas, or feathered ones with no outline at all.
    let fuzzy: Bool
    /// Which basemap to draw. MapKit used to follow the system appearance for us; now that we
    /// supply the tiles, the walk's theme has to be handed in.
    let dark: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.pointOfInterestFilter = .excludingAll
        // Imagery, not Standard: the CARTO tiles have to sit *below* the sound areas (see
        // `applyBasemap`), and at that level MapKit still paints its own street and place labels
        // over them — every name doubled, Apple's bold over CARTO's. The imagery configuration
        // has no labels at all, and the opaque tiles hide the satellite pixels completely, so
        // this leaves CARTO's cartography as the only thing drawn.
        map.preferredConfiguration = MKImageryMapConfiguration()
        applyBasemap(map, context: context)   // also seeds coordinator.dark, so the first
                                              // updateUIView doesn't rebuild it for nothing
        addAttribution(to: map)
        rebuild(map, context: context)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let c = context.coordinator
        if c.dark != dark {
            c.dark = dark
            applyBasemap(map, context: context)
        }
        let sig = experienceID + "|" + String(format: "%.6f,%.6f", offset.dLat, offset.dLng)
                + (fuzzy ? "|fuzzy" : "|classic")
        if sig != c.signature {
            c.signature = sig
            rebuild(map, context: context)
            map.setRegion(map.regionThatFits(openingRegion()), animated: true)
        }
        c.soundingIDs = soundingIDs
        c.dialogueStates = dialogueStates
        c.dialogueColors = dialogueColors
        c.applySounding()
    }

    /// Frame the whole walk on open. The bundle's `zoom` is the author's editing view and was
    /// never carried into the app; a fixed span would crop a large walk and over-zoom a small one.
    /// Swap MapKit's own basemap for the grey CARTO tiles. Separate from `rebuild` because it
    /// tracks the colour scheme, not the walk.
    private func applyBasemap(_ map: MKMapView, context: Context) {
        let c = context.coordinator
        if let old = c.basemap { map.removeOverlay(old) }
        let tiles = GrayTileOverlay(dark: dark)
        c.basemap = tiles
        c.dark = dark
        // The basemap MUST sit in a lower *level* than the sound areas, not merely earlier in the
        // same level. MapKit draws every `.aboveRoads` overlay beneath every `.aboveLabels` one, and
        // that separation is absolute; ordering inside a single level is not enough — an opaque
        // tile overlay sharing `.aboveLabels` with the areas covers them regardless of index.
        // Apple draws no map of its own here (`canReplaceMapContent`), so nothing shows through.
        map.insertOverlay(tiles, at: 0, level: .aboveRoads)
    }

    /// OSM + CARTO credit. Required the moment we draw their tiles, and MapKit's own attribution
    /// goes away along with its basemap.
    private func addAttribution(to map: MKMapView) {
        let label = PaddedLabel()
        label.text = "© OpenStreetMap © CARTO"
        label.font = .systemFont(ofSize: 10)
        label.textColor = .secondaryLabel
        label.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.55)
        label.layer.cornerRadius = 3
        label.clipsToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        map.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: map.safeAreaLayoutGuide.leadingAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: map.safeAreaLayoutGuide.bottomAnchor, constant: -4),
        ])
    }

    private func openingRegion() -> MKCoordinateRegion {
        let fallback = MKCoordinateRegion(center: offset.apply(centerOn),
                                          span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))
        var minLat = Double.infinity, maxLat = -Double.infinity
        var minLng = Double.infinity, maxLng = -Double.infinity

        func include(_ lat: Double, _ lng: Double) {
            minLat = min(minLat, lat); maxLat = max(maxLat, lat)
            minLng = min(minLng, lng); maxLng = max(maxLng, lng)
        }
        for shape in shapes {
            if let c = shape.center, c.count == 2 {
                // Grow a circle to its edges: one degree of latitude is ~111 km everywhere, and
                // longitude shrinks with the cosine of the latitude.
                let r = shape.radius ?? 0
                let dLat = r / 111_000
                let dLng = r / (111_000 * max(0.2, cos(c[0] * .pi / 180)))
                include(c[0] - dLat, c[1] - dLng)
                include(c[0] + dLat, c[1] + dLng)
            }
            for p in shape.points ?? [] where p.count == 2 { include(p[0], p[1]) }
        }
        // Routes are drawn, so they have to be framed: a suggested path that leads away from the
        // sound areas is the ordinary case, and cropping it hides exactly the hint it exists to give.
        for route in routes {
            for p in route.points where p.count == 2 { include(p[0], p[1]) }
        }
        // Labels are drawn too, so they are framed for the same reason routes are.
        for label in labels where label.point.count == 2 { include(label.point[0], label.point[1]) }
        guard minLat <= maxLat, minLng <= maxLng else { return fallback }

        let center = offset.apply(CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                                         longitude: (minLng + maxLng) / 2))
        return MKCoordinateRegion(center: center,
                                  span: MKCoordinateSpan(
                                    latitudeDelta: max((maxLat - minLat) * 1.35, 0.004),
                                    longitudeDelta: max((maxLng - minLng) * 1.35, 0.004)))
    }

    private func rebuild(_ map: MKMapView, context: Context) {
        let c = context.coordinator
        c.fuzzy = fuzzy          // renderers are built lazily, so this has to be set before the adds
        // Everything except the basemap: that one is owned by `applyBasemap` and outlives rebuilds.
        map.removeOverlays(map.overlays.filter { !($0 is MKTileOverlay) })
        c.overlayToShape.removeAll()
        c.overlayToRoute.removeAll()
        c.renderers.removeAll()
        // Routes go on first so the sound areas draw over them: the path is a hint underneath the
        // walk, not a thing competing with it. The user-location annotation is left alone.
        map.removeAnnotations(map.annotations.filter { $0 is RouteEndAnnotation || $0 is MapLabelAnnotation })
        for route in routes {
            let coords = route.coords.map { offset.apply($0) }
            guard coords.count >= 2 else { continue }
            let line = MKPolyline(coordinates: coords, count: coords.count)
            c.overlayToRoute[ObjectIdentifier(line)] = route
            map.addOverlay(line)
            let tint = UIColor(hexString: route.color)
            let w = CGFloat(route.width)
            map.addAnnotation(RouteEndAnnotation(coordinate: coords[0], tint: tint, isStart: true, width: w))
            map.addAnnotation(RouteEndAnnotation(coordinate: coords[coords.count - 1],
                                                 tint: tint, isStart: false, width: w))
        }
        // Hidden areas sound but are never drawn. They still count toward openingRegion, so a walk
        // built entirely from hidden areas is still framed correctly on open.
        for shape in shapes where !shape.hidden {
            let overlay: MKOverlay
            switch shape.type {
            case .circle:
                guard let ctr = shape.centerCoord, let r = shape.radius else { continue }
                overlay = MKCircle(center: offset.apply(ctr), radius: r)
            case .polygon:
                let ring = shape.ringCoords.map { offset.apply($0) }
                guard ring.count >= 3 else { continue }
                overlay = MKPolygon(coordinates: ring, count: ring.count)
            }
            c.overlayToShape[ObjectIdentifier(overlay)] = shape
            map.addOverlay(overlay)
        }
        // Markings go on last: a caption has to sit above the fills, never under one.
        for label in labels {
            guard let coord = label.coord else { continue }
            let art = label.image.flatMap { artwork($0, c) }
            // An image the bundle doesn't carry falls back to the text; with neither, nothing is
            // drawn rather than an empty plate (FORMAT.md).
            guard art != nil || !label.text.isEmpty else { continue }
            map.addAnnotation(MapLabelAnnotation(coordinate: offset.apply(coord), label: label, artwork: art))
        }
    }

    /// Decoded label artwork, cached on the coordinator so panning doesn't re-read the file.
    private func artwork(_ file: String, _ c: Coordinator) -> UIImage? {
        if let hit = c.artworkCache[file] { return hit }
        guard let dir = imagesDirectory,
              let img = UIImage(contentsOfFile: dir.appendingPathComponent(file).path) else { return nil }
        c.artworkCache[file] = img
        return img
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var signature = ""
        var fuzzy = false
        var dark: Bool?
        var basemap: GrayTileOverlay?
        var soundingIDs: Set<String> = []
        var dialogueStates: [String: DialogueState] = [:]
        var dialogueColors = DialogueColors()
        var overlayToShape: [ObjectIdentifier: SoundShape] = [:]
        var overlayToRoute: [ObjectIdentifier: SuggestedRoute] = [:]
        var artworkCache: [String: UIImage] = [:]
        var renderers: [ObjectIdentifier: MKOverlayPathRenderer] = [:]

        /// Stroke color, fill alpha, and line width for a shape given its current state. Dialogue
        /// shapes are colored by playback state; everything else by its own color + sounding highlight.
        private func style(for shape: SoundShape) -> (UIColor, CGFloat, CGFloat) {
            if shape.mode == .dialogue {
                let st = dialogueStates[shape.id] ?? .unplayed
                return (UIColor(hexString: dialogueColors.hex(for: st)), st.fillOpacity, st == .playing ? 3 : 2)
            }
            let color = UIColor(hexString: shape.color)
            let sounding = soundingIDs.contains(shape.id)
            return (color, sounding ? 0.55 : 0.25, sounding ? 3 : 2)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            // The basemap itself. Everything below draws over it in full colour.
            if let tiles = overlay as? GrayTileOverlay {
                let r = GrayTileRenderer(overlay: tiles)
                tiles.renderer = r
                return r
            }
            // A suggested route: a plain stroke, no fill. Round cap and join are what keep the
            // bends smooth instead of mitred and blocky.
            if let route = overlayToRoute[ObjectIdentifier(overlay)], let line = overlay as? MKPolyline {
                let r = MKPolylineRenderer(polyline: line)
                r.strokeColor = UIColor(hexString: route.color).withAlphaComponent(0.9)
                r.lineWidth = CGFloat(route.width)
                r.lineCap = .round
                r.lineJoin = .round
                return r
            }
            guard let shape = overlayToShape[ObjectIdentifier(overlay)] else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let r: MKOverlayPathRenderer
            if let circle = overlay as? MKCircle {
                r = fuzzy ? FuzzyCircleRenderer(circle: circle) : MKCircleRenderer(circle: circle)
            } else if let poly = overlay as? MKPolygon {
                r = fuzzy ? FuzzyPolygonRenderer(polygon: poly) : MKPolygonRenderer(polygon: poly)
            } else { return MKOverlayRenderer(overlay: overlay) }
            let (color, alpha, width) = style(for: shape)
            r.strokeColor = color
            r.lineWidth = width
            r.fillColor = color.withAlphaComponent(alpha)
            renderers[ObjectIdentifier(overlay)] = r
            return r
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let marking = annotation as? MapLabelAnnotation {
                let id = "mapLabel"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: id)
                    ?? MKAnnotationView(annotation: marking, reuseIdentifier: id)
                view.annotation = marking
                view.canShowCallout = false
                view.isEnabled = false          // a marking must never take a tap
                view.image = marking.markerImage()
                view.centerOffset = .zero       // a label is centred on its point, unlike a route end
                return view
            }
            guard let end = annotation as? RouteEndAnnotation else { return nil }   // nil ⇒ system blue dot
            let id = "routeEnd"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: id)
                ?? MKAnnotationView(annotation: end, reuseIdentifier: id)
            view.annotation = end
            view.canShowCallout = false
            view.image = end.markerImage()
            // The dot sits at the left of the rendered image; nudge the view so the dot — not the
            // image's centre — lands on the coordinate.
            view.centerOffset = CGPoint(x: (view.image?.size.width ?? end.dotSize) / 2 - end.dotSize / 2, y: 0)
            return view
        }

        func applySounding() {
            for (oid, r) in renderers {
                guard let shape = overlayToShape[oid] else { continue }
                let (color, alpha, width) = style(for: shape)
                r.strokeColor = color
                r.fillColor = color.withAlphaComponent(alpha)
                r.lineWidth = width
                r.setNeedsDisplay()
            }
        }
    }
}

/// A free-standing map marking: the author's caption on a plate, or a small image. Purely visual —
/// no audio, no containment test, never tappable.
final class MapLabelAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let label: MapLabel
    let artwork: UIImage?

    init(coordinate: CLLocationCoordinate2D, label: MapLabel, artwork: UIImage?) {
        self.coordinate = coordinate
        self.label = label
        self.artwork = artwork
    }

    /// Rendered as one image rather than assembled subviews, for the reason RouteEndAnnotation does
    /// the same: an image-backed annotation view needs no layout pass, so the marking can't drift
    /// off its point while the map moves. Artwork wins over the text when the bundle carries it,
    /// drawn at the authored width with its aspect ratio and alpha kept.
    func markerImage() -> UIImage? {
        if let art = artwork {
            let w = max(1, CGFloat(label.size))
            let h = max(1, w * art.size.height / max(art.size.width, 1))
            let fmt = UIGraphicsImageRendererFormat.default()
            fmt.opaque = false                        // PNG transparency survives
            return UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: fmt).image { _ in
                art.draw(in: CGRect(x: 0, y: 0, width: w, height: h))
            }
        }
        let text = label.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let font = UIFont.systemFont(ofSize: max(1, CGFloat(label.textSize)), weight: .semibold)
        let padH: CGFloat = 7, padV: CGFloat = 3
        let m = (text as NSString).size(withAttributes: [.font: font])
        let size = CGSize(width: ceil(m.width) + padH * 2, height: ceil(m.height) + padV * 2)
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.opaque = false
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            if label.hasPlate {
                UIColor(hexString: label.bgColor).setFill()
                UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 6).fill()
            } else {
                // No plate: a soft shadow is what keeps bare text legible over a busy basemap.
                ctx.cgContext.setShadow(offset: .zero, blur: 3, color: UIColor.black.withAlphaComponent(0.55).cgColor)
            }
            (text as NSString).draw(at: CGPoint(x: padH, y: padV),
                                    withAttributes: [.font: font,
                                                     .foregroundColor: UIColor(hexString: label.textColor)])
        }
    }
}

/// An endpoint of a suggested route: a dot. A caption near a route is a `MapLabel` now.
final class RouteEndAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let tint: UIColor
    let isStart: Bool
    /// Matches the route's stroke, clamped so a hairline route still shows an endpoint and a thick
    /// one doesn't sprout a blob.
    let dotSize: CGFloat

    init(coordinate: CLLocationCoordinate2D, tint: UIColor, isStart: Bool, width: CGFloat) {
        self.coordinate = coordinate
        self.tint = tint
        self.isStart = isStart
        self.dotSize = min(max(width, 6), 14)
    }

    /// Drawn as one image rather than assembled subviews — an MKAnnotationView with an image needs
    /// no layout pass, so the dot can't drift off its point while the map moves. A solid dot in the
    /// route's own colour, sized off the line width so it reads as the end of the stroke instead of
    /// a badge sitting on top of it.
    func markerImage() -> UIImage {
        let dot = dotSize
        let size = CGSize(width: dot, height: dot)
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.opaque = false
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            ctx.cgContext.setFillColor(tint.cgColor)
            ctx.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
        }
    }
}

extension UIColor {
    convenience init(hexString: String) {
        let s = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        if s.count == 6 {
            self.init(red: CGFloat((v >> 16) & 0xff) / 255,
                      green: CGFloat((v >> 8) & 0xff) / 255,
                      blue: CGFloat(v & 0xff) / 255, alpha: 1)
        } else {
            self.init(red: 0.36, green: 0.55, blue: 1, alpha: 1)
        }
    }
}

// MARK: - Fuzzy display style

/// The "fuzzy" look: no outline at all, and an edge that fades out across a band this fraction of
/// the shape's own size. Polygons take their rounded, blobby corners from the round joins the
/// feather is drawn with, so the two halves of the style come from one pass.
///
/// Both renderers subclass `MKOverlayPathRenderer` so they keep the `fillColor` / `strokeColor`
/// properties the sounding + dialogue-state updates already drive; they simply draw the fill
/// themselves instead of letting MapKit stroke and fill a path.
enum FuzzyStyle {
    static let spread: CGFloat = 0.08   // feather band, as a fraction of the shape's size
    static let steps = 12               // bands the polygon feather is built from
}

/// A circle feathers with a radial gradient — solid to the inner edge of the band, transparent at
/// the rim — which is exact and costs one draw call.
final class FuzzyCircleRenderer: MKOverlayPathRenderer {
    private let circle: MKCircle
    init(circle: MKCircle) { self.circle = circle; super.init(overlay: circle) }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in ctx: CGContext) {
        guard let base = fillColor else { return }
        let box = rect(for: circle.boundingMapRect)
        let radius = box.width / 2
        guard radius > 0 else { return }
        let inner = 1 - FuzzyStyle.spread
        let colors = [base.cgColor, base.withAlphaComponent(0).cgColor] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: colors, locations: [inner, 1]) else { return }
        let centre = CGPoint(x: box.midX, y: box.midY)
        ctx.drawRadialGradient(gradient, startCenter: centre, startRadius: radius * inner,
                               endCenter: centre, endRadius: radius, options: [.drawsBeforeStartLocation])
    }
}

/// A polygon has no centre to run a gradient from, so its feather is built from concentric
/// round-jointed strokes, widest and faintest on the outside. Clipping to everything *outside* the
/// area is what keeps the interior flat: without it the strokes would pile up into a bright rim
/// just inside the edge.
final class FuzzyPolygonRenderer: MKOverlayPathRenderer {
    private let polygon: MKPolygon
    init(polygon: MKPolygon) { self.polygon = polygon; super.init(overlay: polygon) }

    private func buildPath() -> CGPath? {
        guard polygon.pointCount >= 3 else { return nil }
        let pts = polygon.points()
        let path = CGMutablePath()
        path.move(to: point(for: pts[0]))
        for i in 1..<polygon.pointCount { path.addLine(to: point(for: pts[i])) }
        path.closeSubpath()
        return path
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in ctx: CGContext) {
        guard let base = fillColor, let path = buildPath() else { return }
        let box = path.boundingBox
        let spread = min(box.width, box.height) * FuzzyStyle.spread
        // Zoomed far enough out that the feather would be sub-pixel: just fill it.
        guard spread > 0.5 else { ctx.addPath(path); ctx.setFillColor(base.cgColor); ctx.fillPath(); return }

        let step = base.cgColor.alpha / CGFloat(FuzzyStyle.steps)
        ctx.saveGState()
        ctx.addRect(box.insetBy(dx: -spread * 2, dy: -spread * 2))
        ctx.addPath(path)
        ctx.clip(using: .evenOdd)                 // everything but the area's own interior
        ctx.setLineJoin(.round); ctx.setLineCap(.round)
        for i in stride(from: FuzzyStyle.steps, through: 1, by: -1) {
            ctx.setStrokeColor(base.withAlphaComponent(step).cgColor)
            ctx.setLineWidth(spread * 2 * CGFloat(i) / CGFloat(FuzzyStyle.steps))
            ctx.addPath(path)
            ctx.strokePath()
        }
        ctx.restoreGState()

        ctx.addPath(path)
        ctx.setFillColor(base.cgColor)
        ctx.fillPath()
    }
}


// MARK: - Grey basemap

/// A label with a little breathing room, for the map credit.
private final class PaddedLabel: UILabel {
    private let inset = UIEdgeInsets(top: 1, left: 4, bottom: 1, right: 4)
    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: inset)) }
    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + inset.left + inset.right, height: s.height + inset.top + inset.bottom)
    }
}

/// CARTO Positron / Dark Matter tiles, colour stripped as they load, standing in for MapKit's own
/// basemap so the authored areas are the only colour on the screen.
///
/// Draining the colour has to happen per-tile rather than as a filter over the map view: a
/// view-level filter would take the sound areas with it.
///
/// The web reaches the same look from the same tiles by a different route — a CSS `grayscale(1)`
/// on `.leaflet-tile-pane`, since Leaflet can filter a whole pane and MapKit cannot. Keep the style
/// names and the key in step with `editor/editor.js` and `web/listen/player.js`.
///
/// Note this is an `MKTileOverlay` only for its URL template and world-sized bounds — `loadTile` is
/// never used, because `MKTileOverlayRenderer` is what caused the flashing (see `GrayTileRenderer`).
final class GrayTileOverlay: MKTileOverlay {
    /// Public by nature — it rides in every tile URL. Keep in step with the web's `CARTO_KEY`.
    static let apiKey = "cb1_2log_1_19551f9fb4c0fbe576aadb40"

    private let dark: Bool
    private let session: URLSession
    private let ci = CIContext(options: [.useSoftwareRenderer: false])
    private let cache = TileCache(limit: 1500)
    private let inflight = InflightSet()
    weak var renderer: GrayTileRenderer?

    init(dark: Bool) {
        // MKTileOverlay templates understand only {x}/{y}/{z} — no Leaflet-style {s} or {r} — so
        // @2x is baked in. The key became mandatory in Aug 2026; without it CARTO stamps
        // "API KEY REQUIRED" across every tile. It ships inside the app binary and is readable by
        // anyone who unpacks it, so treat it as public and restrict it by domain/bundle in the
        // CARTO dashboard rather than as a secret.
        self.dark = dark
        let style = dark ? "dark_all" : "light_all"
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 256 << 20, diskPath: "carto-tiles")
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: cfg)
        super.init(urlTemplate:
            "https://basemaps.cartocdn.com/rastertiles/\(style)/{z}/{x}/{y}@2x.png?key=" + Self.apiKey)
        canReplaceMapContent = true      // opaque: MapKit skips drawing its own map underneath
        maximumZ = 20
    }

    static func key(_ p: MKTileOverlayPath) -> String { "\(p.z)/\(p.x)/\(p.y)" }

    /// Decoded tile if we hold it. Never blocks and never fetches — the renderer calls this while
    /// drawing, so it has to answer instantly.
    func cachedImage(for path: MKTileOverlayPath) -> UIImage? { cache.get(Self.key(path)) }

    /// Fetch a tile unless it is already held or already in flight. On arrival the renderer is asked
    /// to repaint just that tile's square.
    func ensure(_ path: MKTileOverlayPath) {
        let key = Self.key(path)
        if cache.get(key) != nil { return }
        guard inflight.begin(key) else { return }
        fetch(path) { [weak self] image in
            guard let self else { return }
            self.inflight.end(key)
            guard let image else { return }
            self.cache.set(key, image)
            self.warmAncestors(of: path)
            DispatchQueue.main.async { self.renderer?.tileArrived(path) }
        }
    }

    /// Keep the three levels above every tile we load resident. A parent costs a quarter of the
    /// tiles it covers and a grandparent a sixteenth, so this is a modest amount of extra traffic
    /// for a coarse floor that is always ready to be drawn under a level still loading.
    private func warmAncestors(of path: MKTileOverlayPath) {
        for d in 1...3 {
            let z = path.z - d
            if z < 1 { return }
            ensureQuietly(MKTileOverlayPath(x: path.x >> d, y: path.y >> d, z: z, contentScaleFactor: 2))
        }
    }

    /// Like `ensure`, but does not recurse into warming and does not force a repaint.
    private func ensureQuietly(_ path: MKTileOverlayPath) {
        let key = Self.key(path)
        if cache.get(key) != nil { return }
        guard inflight.begin(key) else { return }
        fetch(path) { [weak self] image in
            guard let self else { return }
            self.inflight.end(key)
            guard let image else { return }
            self.cache.set(key, image)
            DispatchQueue.main.async { self.renderer?.tileArrived(path) }
        }
    }

    private func fetch(_ path: MKTileOverlayPath, done: @escaping (UIImage?) -> Void) {
        session.dataTask(with: url(forTilePath: path)) { [weak self] data, _, _ in
            guard let self, let data else { return done(nil) }
            done(self.desaturate(data) ?? UIImage(data: data))
        }.resume()
    }

    /// Saturation to zero, and then opposite corrections for the two themes.
    ///
    /// Light (Positron) is pale to begin with, so a touch of extra contrast stops full desaturation
    /// reading as mush — the same nudge the web applies in `.leaflet-tile-pane`.
    ///
    /// Dark (Dark Matter) is the other way round: it is already close to black, so draining its
    /// colour *and* adding contrast crushed it into an unreadable slab — measured mean luminance 0.7
    /// out of 255. It gets a gamma lift instead (see below), which brought that to 40 with three
    /// times the detail variance: still a dark map, but a readable one.
    private func desaturate(_ data: Data) -> UIImage? {
        guard let src = CIImage(data: data) else { return nil }
        var out = src.applyingFilter("CIColorControls", parameters: dark
            ? [kCIInputSaturationKey: 0.0]
            : [kCIInputSaturationKey: 0.0, kCIInputContrastKey: 1.06])
        if dark {
            // Gamma rather than a brightness offset. Adding brightness raises every pixel equally,
            // which lifts the near-black land but flattens it against the roads and labels — legible
            // but washed out. A gamma below 1 lifts the shadows hardest and leaves the highlights
            // alone, so the land stays dark while roads and labels separate from it.
            out = out.applyingFilter("CIGammaAdjust", parameters: ["inputPower": 0.7])
        }
        guard let cg = ci.createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// Draws the basemap itself, instead of handing the job to `MKTileOverlayRenderer`.
///
/// This exists for one reason. `MKTileOverlayRenderer` clears itself while the map's scale is
/// changing and paints nothing until the new level's tiles arrive — measurably, it blanked even
/// when every tile was already in memory and returned instantly, which is the grey flashing on
/// every zoom. No amount of caching fixes that, because the renderer is not asking.
///
/// Drawing it ourselves means every frame paints *something*. Coarse levels go down first as a
/// floor — they are few, and `warmAncestors` keeps them resident — then the target level paints
/// over them. A tile that has not arrived reveals the blurrier level beneath rather than a hole,
/// which is exactly what Leaflet does on the web.
final class GrayTileRenderer: MKOverlayRenderer {
    private var tiles: GrayTileOverlay? { overlay as? GrayTileOverlay }

    /// Always true: a rect with no sharp tile yet is precisely the one we want to fill with a
    /// coarse stand-in, so declining to draw would reintroduce the blank.
    override func canDraw(_ mapRect: MKMapRect, zoomScale: MKZoomScale) -> Bool { true }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let tiles else { return }
        let z = targetZ(for: zoomScale, max: tiles.maximumZ)
        context.interpolationQuality = .low      // these are stand-ins; speed matters more than edges
        // Coarse to fine, so each level paints over the blurrier one beneath it.
        for level in stride(from: Swift.max(1, z - 4), through: z, by: 1) {
            draw(level: level, in: mapRect, context: context, requestMissing: level == z, tiles: tiles)
        }
    }

    /// Tile level whose 256-point squares match the current scale.
    /// A tile at `z` spans `world / 2^z` map points; on screen that is that times `zoomScale`, and
    /// setting it equal to 256 gives `z = 20 + log2(zoomScale)`.
    private func targetZ(for zoomScale: MKZoomScale, max maxZ: Int) -> Int {
        let z = Int((log2(Double(zoomScale)) + 20).rounded())
        return Swift.min(Swift.max(z, 1), maxZ)
    }

    private func draw(level z: Int, in mapRect: MKMapRect, context: CGContext,
                      requestMissing: Bool, tiles: GrayTileOverlay) {
        let side = MKMapSize.world.width / pow(2, Double(z))
        let last = Int(pow(2, Double(z))) - 1
        let x0 = Swift.max(0, Int(floor(mapRect.minX / side)))
        let x1 = Swift.min(last, Int(floor((mapRect.maxX - 1) / side)))
        let y0 = Swift.max(0, Int(floor(mapRect.minY / side)))
        let y1 = Swift.min(last, Int(floor((mapRect.maxY - 1) / side)))
        guard x0 <= x1, y0 <= y1 else { return }

        for x in x0...x1 {
            for y in y0...y1 {
                let path = MKTileOverlayPath(x: x, y: y, z: z, contentScaleFactor: 2)
                guard let image = tiles.cachedImage(for: path) else {
                    if requestMissing { tiles.ensure(path) }
                    continue
                }
                let square = MKMapRect(x: Double(x) * side, y: Double(y) * side,
                                       width: side, height: side)
                UIGraphicsPushContext(context)
                image.draw(in: rect(for: square))
                UIGraphicsPopContext()
            }
        }
    }

    /// Repaint just the square a newly arrived tile covers.
    func tileArrived(_ path: MKTileOverlayPath) {
        let side = MKMapSize.world.width / pow(2, Double(path.z))
        setNeedsDisplay(MKMapRect(x: Double(path.x) * side, y: Double(path.y) * side,
                                  width: side, height: side))
    }
}

/// Tracks which fetches are already in the air, so a tile is never requested twice.
private final class InflightSet {
    private let lock = NSLock()
    private var set = Set<String>()
    func begin(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return set.insert(key).inserted }
    func end(_ key: String) { lock.lock(); defer { lock.unlock() }; set.remove(key) }
}

/// Deterministic LRU of decoded tiles.
///
/// `NSCache` looked like the obvious fit and was the wrong one: it evicts on its own schedule, and
/// the tile it drops is often exactly the coarse level the renderer is using as its floor. Losing
/// those brings the blank back. This holds a fixed number, least-recently-used out first.
/// Images are stored decoded — the renderer reads this on every draw, so decoding here would show.
private final class TileCache {
    private let lock = NSLock()
    private var store: [String: (image: UIImage, seq: Int)] = [:]
    private var seq = 0
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    func get(_ key: String) -> UIImage? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = store[key] else { return nil }
        seq += 1
        store[key] = (entry.image, seq)          // touch, so it ages from now
        return entry.image
    }

    func set(_ key: String, _ image: UIImage) {
        lock.lock(); defer { lock.unlock() }
        seq += 1
        store[key] = (image, seq)
        guard store.count > limit else { return }
        let excess = store.count - limit + limit / 10   // trim with headroom, not one per insert
        for (k, _) in store.sorted(by: { $0.value.seq < $1.value.seq }).prefix(excess) {
            store.removeValue(forKey: k)
        }
    }
}
