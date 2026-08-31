import SwiftUI
import UIKit

/// What a report is about. The subject line is filled in from whatever walk is loaded.
enum ReportKind: String, Identifiable {
    case walk, artist, issue
    var id: String { rawValue }

    func buttonTitle(walk: String?, artist: String?) -> String {
        switch self {
        case .walk:   return "Report \(walk ?? "this soundwalk")"
        case .artist: return "Report \(artist ?? "this artist")"
        case .issue:  return "Report an issue"
        }
    }
    var formTitle: String {
        switch self {
        case .walk:   return "Report a soundwalk"
        case .artist: return "Report an artist"
        case .issue:  return "Report an issue"
        }
    }
    var prompt: String {
        switch self {
        case .walk:   return "What's wrong with this walk? Tell us as much as you can — if it's a rights or copyright problem, say whose work it is."
        case .artist: return "What's the problem with this artist's page or their walks?"
        case .issue:  return "What went wrong? What were you doing at the time?"
        }
    }
}

/// The form itself: what it's about across the top, a free-text box, and send.
struct ReportView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    let kind: ReportKind
    @State private var message = ""
    @State private var sending = false
    @State private var failure: String?
    @State private var sent = false

    private var walkName: String? { app.selectedExperience?.displayName }
    private var artistName: String? {
        let c = app.currentRemoteWalk?.creatorText ?? app.selectedExperience?.map.creator ?? ""
        return c.isEmpty ? nil : c
    }
    private var subjectName: String? {
        switch kind {
        case .walk:   return walkName
        case .artist: return artistName
        case .issue:  return nil
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let subjectName {
                        LabeledContent(kind == .artist ? "Artist" : "Soundwalk", value: subjectName)
                    }
                    if kind == .walk, let artistName {
                        LabeledContent("By", value: artistName)
                    }
                    if kind != .issue, subjectName == nil {
                        Text("No soundwalk is loaded, so this will be sent without one attached.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text(kind.formTitle)
                }

                Section {
                    TextEditor(text: $message)
                        .frame(minHeight: 160)
                } header: {
                    Text("What should we know?")
                } footer: {
                    Text(kind.prompt)
                }

                if let failure {
                    Text(failure).foregroundStyle(.red).font(.footnote)
                }

                Section {
                    Button(action: send) {
                        HStack {
                            if sending { ProgressView().padding(.trailing, 6) }
                            Text(sending ? "Sending…" : "Submit report")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(sending || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } footer: {
                    Text("Reports go straight to Songitude's team. Nothing about you is attached — "
                         + "only what you write and which walk it concerns.")
                }
            }
            .navigationTitle("Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .alert("Thank you", isPresented: $sent) {
                Button("OK") { dismiss() }
            } message: {
                Text("Your report has been sent. We read every one.")
            }
        }
    }

    private func send() {
        sending = true
        failure = nil
        ReportService.send(kind: kind,
                           subjectName: subjectName,
                           walkId: app.selectedExperience?.id,
                           artist: artistName,
                           message: message) { result in
            sending = false
            switch result {
            case .success: sent = true
            case .failure(let e): failure = "Couldn't send that: \(e.localizedDescription)"
            }
        }
    }
}

/// Posts a report to the reporting endpoint. Deliberately carries no identifier — just the text,
/// which walk it is about, and enough build detail to make a bug report actionable.
enum ReportService {
    static let endpoint = URL(string: "https://omzhe5l8f5.execute-api.us-east-1.amazonaws.com")!

    static func send(kind: ReportKind, subjectName: String?, walkId: String?, artist: String?,
                     message: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let body: [String: Any] = [
            "kind": kind.rawValue,
            "subjectName": subjectName ?? "",
            "walkId": walkId ?? "",
            "artist": artist ?? "",
            "message": message,
            "appVersion": "\(version) (\(build))",
            "device": "\(UIDevice.current.model), iOS \(UIDevice.current.systemVersion)",
        ]
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 20

        URLSession.shared.dataTask(with: req) { _, response, error in
            DispatchQueue.main.async {
                if let error = error { return completion(.failure(error)) }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(code) else {
                    return completion(.failure(NSError(domain: "Songitude", code: code, userInfo: [
                        NSLocalizedDescriptionKey: "the server refused it (HTTP \(code))"])))
                }
                completion(.success(()))
            }
        }.resume()
    }
}
