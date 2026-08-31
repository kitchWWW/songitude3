import SwiftUI
import CoreLocation

/// The gear-icon settings sheet: permission controls, credits, and a hidden Debug section
/// with map selection + "re-center map over me".
struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var confirmReset = false
    @State private var reporting: ReportKind?

    var body: some View {
        NavigationView {
            Form {
                permissionsSection
                appearanceSection
                reportSection
                creditsSection
                debugSection
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $reporting) { kind in
                ReportView(kind: kind).environmentObject(app)
            }
            .alert("Reset App?", isPresented: $confirmReset) {
                Button("Reset", role: .destructive) { app.resetEverything(); dismiss() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Clears preferences, downloaded walks and your progress, and returns to the "
                     + "welcome screen. The location permission itself can only be reset from the "
                     + "iOS Settings app.")
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

    /// Reporting lives right above Credits: one row per thing a listener might need to flag, with
    /// the loaded walk and its artist filled in so they don't have to describe which one they mean.
    private var reportSection: some View {
        Section("Report") {
            let walk = app.selectedExperience?.displayName
            let artist: String? = {
                let c = app.currentRemoteWalk?.creatorText ?? app.selectedExperience?.map.creator ?? ""
                return c.isEmpty ? nil : c
            }()
            Button(ReportKind.walk.buttonTitle(walk: walk, artist: artist)) { reporting = .walk }
                .disabled(walk == nil)
            Button(ReportKind.artist.buttonTitle(walk: walk, artist: artist)) { reporting = .artist }
                .disabled(artist == nil)
            Button(ReportKind.issue.buttonTitle(walk: walk, artist: artist)) { reporting = .issue }
            if let mail = URL(string: "mailto:brian.e2014@gmail.com") {
                Link("Email brian.e2014@gmail.com", destination: mail).font(.footnote)
            }
        }
    }

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Theme", selection: $app.appearance) {
                ForEach(AppAppearance.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
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
                Button("Reset App", role: .destructive) { confirmReset = true }
            }
        }
    }

    // MARK: Credits

    private var creditsSection: some View {
        Section("Credits") {
            creditRow(name: "Brian Ellis", role: "Creative Coder",
                      url: "http://brianellissound.com")
        }
    }

    /// Name on the left, role on the right, and the whole row is the link.
    @ViewBuilder
    private func creditRow(name: String, role: String, url: String) -> some View {
        // No explicit foregrounds: both halves inherit the Link's tint, so the row reads as one link.
        let row = HStack {
            Text(name)
            Spacer(minLength: 12)
            Text(role)
        }
        .contentShape(Rectangle())

        if let u = URL(string: url) {
            Link(destination: u) { row }
        } else {
            row
        }
    }
}
