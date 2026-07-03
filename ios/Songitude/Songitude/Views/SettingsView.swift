import SwiftUI
import CoreLocation

/// The gear-icon settings sheet: permission controls, credits, and a hidden Debug section
/// with map selection + "re-center map over me".
struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                permissionsSection
                creditsSection
                debugSection
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: Permissions

    private var permissionsSection: some View {
        Section("Location") {
            HStack {
                Text("Status")
                Spacer()
                Text(statusText).foregroundStyle(.secondary)
            }
            Button("Re-request location permission") {
                if app.location.authorization == .notDetermined {
                    app.enableLocation()
                } else {
                    // Already decided once — send them to the system Settings app.
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
        }
    }

    private var statusText: String {
        switch app.location.authorization {
        case .authorizedAlways: return "Always"
        case .authorizedWhenInUse: return "While using"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not set"
        @unknown default: return "Unknown"
        }
    }

    // MARK: Debug (hidden away)

    private var debugSection: some View {
        Section {
            DisclosureGroup("Advanced") {
                Button("Re-center map over me") { app.recenterOnMe() }
                    .disabled(app.location.lastKnownLocation == nil)
                if app.offset != .none {
                    Button("Clear re-center", role: .destructive) { app.clearRecenter() }
                }
                Button("Upgrade to “Always” location") { app.location.requestAlways() }
                Button("Reload walk catalog") { app.refreshCatalog() }
            }
        }
    }

    // MARK: Credits

    private var creditsSection: some View {
        Section("Credits") {
            creditRow(name: "Brian Ellis", role: "Creative Coder",
                      url: "http://brianellissound.com")
            creditRow(name: "Chromic Duo", role: "Composer & Creative Director",
                      subtitle: "Lucy Yao & Dorothy Chan",
                      url: "https://www.chromic.space")
        }
    }

    private func creditRow(name: String, role: String, subtitle: String? = nil, url: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(name).font(.headline)
                Spacer()
                if let u = URL(string: url) {
                    Link("Website", destination: u).font(.footnote)
                }
            }
            Text(role).font(.subheadline).foregroundStyle(.secondary)
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.tertiary) }
        }
        .padding(.vertical, 2)
    }
}
