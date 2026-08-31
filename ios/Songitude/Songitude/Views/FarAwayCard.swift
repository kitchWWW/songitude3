import SwiftUI

/// Shown after the walk's own intro card when the listener is a long way from a geo-locked walk.
///
/// Purely advisory. A walk's sounds live at fixed real-world coordinates, so from hundreds of miles
/// away the map looks perfectly normal and pressing play produces silence — which reads as a broken
/// app rather than as "you aren't there yet". This says so plainly and points at the two things that
/// would actually work, while never getting in the way of looking around.
struct FarAwayCard: View {
    let walkName: String
    let distanceMiles: Double?
    let onBrowse: () -> Void
    let onDismiss: () -> Void

    private var distanceText: String {
        guard let m = distanceMiles else { return "a long way away" }
        let rounded = m >= 1000 ? (m / 100).rounded() * 100 : m.rounded()
        return "about \(Int(rounded)) miles away"
    }

    var body: some View {
        ZStack {
            // Catches taps outside the card without dimming the map behind it, matching the
            // intro card's behaviour so the two feel like one sequence.
            Color.clear.contentShape(Rectangle()).ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

            GeometryReader { geo in
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 12) {
                        Text("You look pretty far away!")
                            .font(.title2.bold())
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
                    .padding(.bottom, 12)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("“\(walkName)” is \(distanceText). Its sounds are pinned to real places, "
                             + "so nothing will play until you are nearby.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Label("Browse the list for a walk near you.",
                              systemImage: "list.bullet")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Label("Or open one marked Listen From Anywhere — those move themselves to "
                              + "wherever you're standing.",
                              systemImage: "location.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(spacing: 8) {
                        Button(action: onBrowse) {
                            Text("Find a walk near me")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                        }
                        .buttonStyle(.borderedProminent)

                        // Never a dead end: looking around a walk you can't hear is allowed.
                        Button(action: onDismiss) {
                            Text("Look around anyway")
                                .font(.subheadline.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.top, 18)
                }
                .padding(20)
                .background(Color(.systemBackground),
                            in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(.primary.opacity(0.08)))
                .shadow(radius: 30, y: 10)
                .frame(maxWidth: 420)
                .frame(width: geo.size.width, height: geo.size.height)   // centre it in the space
            }
            .padding(.horizontal, 24)
            .padding(.top, 74)
            .padding(.bottom, 150)   // leave the map's play button uncovered, as the intro card does
        }
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }
}
