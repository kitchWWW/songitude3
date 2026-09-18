import SwiftUI

/// An artist's page: their chosen colour, their markdown bio, and every walk they've published.
/// Reached by tapping a creator's name in the walks list; the navigation bar supplies Back.
struct ArtistPageView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.colorScheme) private var colorScheme

    let artistId: String
    let fallbackName: String          // the walk's creator string, shown until the profile lands
    let onOpenWalk: (RemoteWalk) -> Void

    private var profile: ArtistProfile? { app.artists.profile(artistId) }
    private var name: String { profile?.name?.isEmpty == false ? profile!.name! : fallbackName }
    /// nil when the artist left their page on the app's own colours.
    private var theme: (color: Color, isDark: Bool)? { HexColor.parse(profile?.bgColor) }
    private var walks: [RemoteWalk] { app.catalog.walks.filter { $0.artistId == artistId } }
    @State private var showGeoLocked = true
    @State private var showAnywhere = true

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Text(name).font(.largeTitle.bold())
                    bio
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            if !walks.isEmpty {
                Section {
                    EmptyView()
                } header: {
                    // Reads as a heading in the page's own voice, not a grey system section label.
                    Text("Walks by \(name)")
                        .font(.title3.bold())
                        .foregroundStyle(.primary)
                        .textCase(nil)
                }
                .listRowBackground(Color.clear)

                // Same split as the browser: fixed-in-place walks, then transportable ones.
                artistSection("Geo-Locked", walks.filter { $0.portable != true }, isOpen: $showGeoLocked)
                artistSection("Listen From Anywhere", walks.filter { $0.portable == true }, isOpen: $showAnywhere)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background((theme?.color ?? Color(.systemBackground)).ignoresSafeArea())
        // With an authored backdrop, let every system colour (.secondary, separators, tints) adapt
        // to it; with none, inherit the app's appearance setting.
        .environment(\.colorScheme, theme.map { $0.isDark ? .dark : .light } ?? colorScheme)
        .navigationTitle("Artist Bio")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { app.artists.load(artistId) }
    }

    @ViewBuilder
    private func artistSection(_ title: String, _ list: [RemoteWalk], isOpen: Binding<Bool>) -> some View {
        if !list.isEmpty {
            Section {
                if isOpen.wrappedValue {
                    ForEach(list) { w in
                        // Same row as the browser, minus the artist link — we're already here.
                        WalkRow(walk: w, onOpen: { onOpenWalk(w) })
                            .uninstallSwipeAction(for: w, app: app)
                            .fullWidthSeparator()
                            .stableWalkRow(w, app: app)
                            .listRowBackground(Color.clear)
                    }
                }
            } header: {
                CollapsibleHeader(title: title, isOpen: isOpen)
                    .listRowBackground(Color.clear)
            }
        }
    }

    @ViewBuilder private var bio: some View {
        if let text = profile?.bio, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            MarkdownBody(source: text)
        } else if app.artists.failed.contains(artistId) || profile != nil {
            Text("This artist hasn't written a bio yet.")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            ProgressView()
        }
    }
}

// MARK: - Markdown

/// Small block-level markdown renderer: headings, bullets, numbered items, quotes, rules and
/// paragraphs. Inline styling (bold, italic, links, code) comes from AttributedString, which
/// handles spans but not block structure.
struct MarkdownBody: View {
    let source: String

    private enum Block: Hashable {
        case heading(Int, String), bullet(String), ordered(String, String)
        case quote(String), rule, paragraph(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(parse().enumerated()), id: \.offset) { _, b in view(for: b) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func view(for b: Block) -> some View {
        switch b {
        case let .heading(level, text):
            inline(text)
                .font(level <= 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, 4)
        case let .bullet(text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•"); inline(text)
            }
        case let .ordered(marker, text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker).monospacedDigit(); inline(text)
            }
        case let .quote(text):
            HStack(alignment: .top, spacing: 10) {
                Rectangle().frame(width: 3).opacity(0.3)
                inline(text).italic()
            }
            .fixedSize(horizontal: false, vertical: true)
        case .rule:
            Divider()
        case let .paragraph(text):
            inline(text)
        }
    }

    private func inline(_ s: String) -> Text {
        if let a = try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(a)
        }
        return Text(s)
    }

    /// Group lines into blocks. Consecutive plain lines join into one paragraph (a soft wrap);
    /// a blank line closes it.
    private func parse() -> [Block] {
        var blocks: [Block] = []
        var para: [String] = []
        func flush() {
            if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: " "))); para = [] }
        }
        for raw in source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }) && line.count >= 3 {
                flush(); blocks.append(.rule); continue
            }
            if line.hasPrefix("#") {
                let hashes = line.prefix(while: { $0 == "#" }).count
                flush()
                blocks.append(.heading(hashes, String(line.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                flush(); blocks.append(.bullet(String(line.dropFirst(2)))); continue
            }
            if let dot = line.firstIndex(of: "."), line[line.startIndex..<dot].allSatisfy(\.isNumber),
               line.index(after: dot) < line.endIndex, line[line.index(after: dot)] == " " {
                flush()
                blocks.append(.ordered(String(line[line.startIndex...dot]),
                                       String(line[line.index(dot, offsetBy: 2)...])))
                continue
            }
            if line.hasPrefix("> ") { flush(); blocks.append(.quote(String(line.dropFirst(2)))); continue }
            para.append(line)
        }
        flush()
        return blocks
    }
}

// MARK: - Colour

enum HexColor {
    /// Parse "#rrggbb" and report whether it needs light-on-dark treatment.
    static func parse(_ hex: String?) -> (color: Color, isDark: Bool)? {
        guard var h = hex?.trimmingCharacters(in: .whitespaces), h.hasPrefix("#") else { return nil }
        h.removeFirst()
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        let r = Double((v >> 16) & 0xff) / 255, g = Double((v >> 8) & 0xff) / 255, b = Double(v & 0xff) / 255
        // Perceived luminance (ITU-R BT.601), the usual cheap readability test.
        return (Color(.sRGB, red: r, green: g, blue: b), 0.299 * r + 0.587 * g + 0.114 * b < 0.55)
    }
}
