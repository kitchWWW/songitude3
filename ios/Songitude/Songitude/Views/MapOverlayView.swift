import SwiftUI
import MapKit

/// MapKit map that renders the experience's shapes as colored overlays (matching the editor),
/// applies the re-center offset, shows the user, and highlights areas that are sounding.
struct MapOverlayView: UIViewRepresentable {
    let shapes: [SoundShape]
    let offset: CoordinateOffset
    let soundingIDs: Set<String>
    let dialogueStates: [String: DialogueState]
    let dialogueColors: DialogueColors
    let centerOn: CLLocationCoordinate2D
    let experienceID: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.pointOfInterestFilter = .excludingAll
        rebuild(map, context: context)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let c = context.coordinator
        let sig = experienceID + "|" + String(format: "%.6f,%.6f", offset.dLat, offset.dLng)
        if sig != c.signature {
            c.signature = sig
            rebuild(map, context: context)
            let region = MKCoordinateRegion(center: offset.apply(centerOn),
                                            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))
            map.setRegion(region, animated: true)
        }
        c.soundingIDs = soundingIDs
        c.dialogueStates = dialogueStates
        c.dialogueColors = dialogueColors
        c.applySounding()
    }

    private func rebuild(_ map: MKMapView, context: Context) {
        let c = context.coordinator
        map.removeOverlays(map.overlays)
        c.overlayToShape.removeAll()
        c.renderers.removeAll()
        for shape in shapes {
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
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var signature = ""
        var soundingIDs: Set<String> = []
        var dialogueStates: [String: DialogueState] = [:]
        var dialogueColors = DialogueColors()
        var overlayToShape: [ObjectIdentifier: SoundShape] = [:]
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
            guard let shape = overlayToShape[ObjectIdentifier(overlay)] else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let r: MKOverlayPathRenderer
            if let circle = overlay as? MKCircle { r = MKCircleRenderer(circle: circle) }
            else if let poly = overlay as? MKPolygon { r = MKPolygonRenderer(polygon: poly) }
            else { return MKOverlayRenderer(overlay: overlay) }
            let (color, alpha, width) = style(for: shape)
            r.strokeColor = color
            r.lineWidth = width
            r.fillColor = color.withAlphaComponent(alpha)
            renderers[ObjectIdentifier(overlay)] = r
            return r
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
