// Claude Chat Sync: compare the Claude Code chats of up to three Claude profiles and copy or
// move them between profiles. All file work is done by the claude-chat command; this is the UI.

import AppKit
import SwiftUI

// The command ships inside the app bundle; ~/.local/bin is the fallback for development builds
let toolPath: String = {
    if let p = Bundle.main.path(forResource: "claude-chat", ofType: nil) { return p }
    return NSString(string: "~/.local/bin/claude-chat").expandingTildeInPath
}()

let configFile = NSString(string: "~/.config/claude-chat-sync/config.json").expandingTildeInPath

// MARK: - Palette

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

enum Palette {
    static let window = Color(hex: 0x1C1C1F)
    static let bar = Color(hex: 0x232326)
    static let sidebar = Color(hex: 0x202023)
    static let card = Color(hex: 0x2A2A2E)
    static let cardBorder = Color(hex: 0x36363B)
    static let line = Color(hex: 0x333338)
    static let text = Color(hex: 0xECECEE)
    static let secondary = Color(hex: 0xA1A1A8)
    static let none = Color(hex: 0x8B8B94)
    static let green = Color(hex: 0x5BD17A)
    static let amber = Color(hex: 0xF2B33D)
    static let red = Color(hex: 0xFF7676)
    static let accent = Color(hex: 0x5B5BD6)
    static let selected = Color(hex: 0x2F3550)
    static let profileColors: [Color] = [Color(hex: 0x5AA2FF), Color(hex: 0xF27AA6), Color(hex: 0x4FD1C5)]

    // claude-multiprofile's Dock colours
    static func named(_ name: String?) -> Color? {
        switch name {
        case "orange": return Color(hex: 0xF5A35C)
        case "red": return Color(hex: 0xFF7676)
        case "yellow": return Color(hex: 0xF2D04B)
        case "green": return Color(hex: 0x5BD17A)
        case "teal": return Color(hex: 0x4FD1C5)
        case "blue": return Color(hex: 0x5AA2FF)
        case "purple": return Color(hex: 0xB49CFF)
        case "pink": return Color(hex: 0xF27AA6)
        default: return nil
        }
    }
}

// MARK: - Data from claude-chat

struct ProfileInfo: Decodable, Identifiable, Hashable {
    let key: String
    let name: String
    let color: String?
    let running: Bool
    let account: String?
    let email: String?
    let codeEmail: String?
    let accountMismatch: Bool
    let error: String?
    let appName: String?   // the launcher's name, e.g. "Claude WORK"
    let codeDir: String?   // its Claude Code folder: ~/.claude for the default and Desktop-only profiles
    var id: String { key }

    var app: String { appName ?? (key == "default" ? "Claude" : "Claude \(name)") }
    /// Who the Desktop is signed in as: the e-mail is only known when Claude Code uses the same account
    var signedInAs: String { email ?? account.map { "account \($0.prefix(8))" } ?? "not signed in" }
    var origin: String {
        if key == "default" { return "default Claude" }
        return "claude-multiprofile: \(key)" + (codeDir == "~/.claude" ? " · Desktop only" : "")
    }
}

struct Side: Decodable, Hashable {
    let sessionId: String
    let archived: Bool
    let pending: String?   // "archive" or "remove" queued until the app quits
    let lastActivityAt: Double
    let state: String      // only, same, latest, behind, diverged, missing
}

struct Item: Decodable, Identifiable, Hashable {
    let key: String
    let title: String
    let cwd: String
    let project: String
    let lastActivityAt: Double
    let parent: String?
    let sides: [String: Side]
    var id: String { key }

    var activeSomewhere: Bool { sides.values.contains { !$0.archived } }
    var archivedEverywhere: Bool { sides.values.allSatisfy(\.archived) }

    enum Kind: Equatable { case only(String), inSync, update, conflict }

    var kind: Kind {
        let states = Set(sides.values.map(\.state))
        if sides.count == 1 { return .only(sides.keys.first!) }
        if states.contains("diverged") { return .conflict }
        if states == ["same"] { return .inSync }
        return .update
    }
}

struct Status: Decodable {
    let profiles: [ProfileInfo]
    let chats: [Item]
}

struct SyncReport: Decodable {
    struct Line: Decodable {
        let sessionId: String
        let title: String?
        let to: String?
        let result: String  // copied, updated, waiting, conflict, deleted, moved, parent, mismatch
    }
    let chats: [Line]
    let errors: [String: String]
}

struct SyncRun {
    let report: SyncReport?
    let error: String?
    let at: Date
}

struct TrashEntry: Decodable, Identifiable {
    let id: String
    let profile: String
    let sessionId: String
    let title: String?
    let removedAt: Double
}

struct RunResult {
    let code: Int32
    let out: String
    let err: String
}

let exitAppOpen: Int32 = 3, exitDiverged: Int32 = 4, exitDestAhead: Int32 = 5

func runTool(_ args: [String]) async -> RunResult {
    await withCheckedContinuation { cont in
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = ["-I", toolPath] + args
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            do { try p.run() } catch {
                cont.resume(returning: RunResult(code: -1, out: "", err: error.localizedDescription))
                return
            }
            let o = out.fileHandleForReading.readDataToEndOfFile()
            let e = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            cont.resume(returning: RunResult(code: p.terminationStatus, out: String(decoding: o, as: UTF8.self),
                                             err: String(decoding: e, as: UTF8.self)))
        }
    }
}

func clean(_ s: String) -> String {
    s.replacingOccurrences(of: "ERROR: ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Copy plans

enum Outcome {
    case copy, update, same, skip, conflict, absent

    var label: String {
        switch self {
        case .copy: return "+ will be copied"
        case .update: return "→ will be updated"
        case .same: return "✓ already identical"
        case .skip: return "left alone: newer in destination"
        case .conflict: return "⚠ diverged: you will be asked"
        case .absent: return "not in the source"
        }
    }

    var color: Color {
        switch self {
        case .copy: return Color(hex: 0x5AA2FF)
        case .update: return Palette.amber
        case .same: return Palette.green
        case .conflict: return Palette.red
        default: return Palette.secondary
        }
    }
}

/// What copying chat `i` from profile `s` to profile `t` does
func outcome(_ i: Item, from s: String, to t: String) -> Outcome {
    guard let a = i.sides[s] else { return .absent }
    guard let b = i.sides[t] else { return .copy }
    if a.state == "diverged" || b.state == "diverged" { return .conflict }
    if a.state == b.state { return .same }                 // same/same or latest/latest
    if b.state == "behind" { return .update }
    return .skip                                           // the destination is ahead
}

struct PlanLine: Identifiable {
    let id: String
    let title: String
    let depth: Int
    let outcome: Outcome
}

struct CopyRequest: Identifiable {
    let id = UUID()
    let from: ProfileInfo
    let to: ProfileInfo
    let sourceSessionId: String
    let title: String
    let lines: [PlanLine]
    var move = false
    var archive = false

    var work: Int { lines.filter { [.copy, .update, .conflict].contains($0.outcome) }.count }
    var noun: String { lines.count > 1 ? "group" : "chat" }
}

// MARK: - Tree helpers

func children(of id: String, in items: [Item]) -> [Item] {
    items.filter { $0.parent == id }.sorted { $0.lastActivityAt > $1.lastActivityAt }
}

func subtree(_ root: Item, in items: [Item], depth: Int = 0) -> [(item: Item, depth: Int)] {
    [(root, depth)] + children(of: root.id, in: items).flatMap { subtree($0, in: items, depth: depth + 1) }
}

/// The best profile to copy a group to `target` from: one that has the root, preferring newer copies
func source(for root: Item, group: [Item], target: String, among profiles: [ProfileInfo]) -> ProfileInfo? {
    let candidates = profiles.filter { $0.key != target && root.sides[$0.key] != nil }
    return candidates.max { a, b in
        let score = { (k: String) in group.filter { ["latest", "same", "only"].contains($0.sides[k]?.state ?? "") }.count }
        return score(a.key) < score(b.key)
    }
}

let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")  // the app is in English
    f.dateFormat = "d MMM HH:mm"
    return f
}()

// MARK: - Store

enum Dialog: Identifiable {
    case appOpen(CopyRequest)
    case diverged(CopyRequest, String)
    case message(String, String)

    var id: String {
        switch self {
        case .appOpen(let r): return "open-\(r.id)"
        case .diverged(let r, _): return "div-\(r.id)"
        case .message(let t, let m): return "msg-\(t)-\(m.hashValue)"
        }
    }
}

@MainActor
final class Store: ObservableObject {
    @Published var profiles: [ProfileInfo] = []
    @Published var allProfiles: [ProfileInfo] = []
    @Published var items: [Item] = []
    @Published var trash: [TrashEntry] = []
    @Published var busy = false
    @Published var dialog: Dialog?
    @Published var confirming: CopyRequest?
    @Published var showSettings = false
    @Published var showTrash = false
    @Published var autoSync = false
    @Published var syncing = false
    @Published var lastSync: SyncRun?
    @Published private(set) var refreshing = false

    func color(_ key: String) -> Color {
        let i = profiles.firstIndex { $0.key == key } ?? 0
        return Palette.named(profiles.first { $0.key == key }?.color) ?? Palette.profileColors[i % 3]
    }

    func profile(_ key: String?) -> ProfileInfo? { (allProfiles + profiles).first { $0.key == key } }

    func loadConfig() {
        let cfg = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: configFile)))) as? [String: Any]
        autoSync = cfg?["autoSync"] as? Bool ?? false
    }

    /// Re-reads everything, syncing first when auto-sync is on or `sync` asks for it. Opening the app and
    /// switching back to it both land here, so one run at a time: two syncs must never write at once.
    func refresh(sync: Bool = false) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        loadConfig()
        if (sync || autoSync) && !busy {
            busy = true
            syncing = true
            let r = await runTool(["sync", "--json"])
            if r.code == 0, let rep = try? JSONDecoder().decode(SyncReport.self, from: Data(r.out.utf8)) {
                lastSync = SyncRun(report: rep, error: nil, at: Date())
            } else {
                lastSync = SyncRun(report: nil, error: clean(r.err.isEmpty ? "claude-chat sync failed (\(r.code))" : r.err),
                                   at: Date())
            }
            syncing = false
            busy = false
        }
        await reload()
    }

    /// The last sync in a few lines, each with its colour
    var syncNotes: [(text: String, color: Color)] {
        guard let run = lastSync else { return [] }
        guard let rep = run.report else { return [(run.error ?? "Sync failed", Palette.red)] }
        func byTarget(_ results: Set<String>) -> [(String, Int)] {
            Dictionary(grouping: rep.chats.filter { results.contains($0.result) }) { $0.to ?? "" }
                .map { ($0.key, $0.value.count) }.sorted { $0.0 < $1.0 }
        }
        func chats(_ n: Int) -> String { n == 1 ? "1 chat" : "\(n) chats" }
        var out: [(text: String, color: Color)] = []
        for (to, n) in byTarget(["copied", "updated"]) {
            out.append(("\(chats(n)) synced to \(profile(to)?.name ?? to)", Palette.green))
        }
        for (to, n) in byTarget(["waiting"]) {
            let p = profile(to)
            out.append(("\(chats(n)) to bring into \(p?.name ?? to): quit \(p?.app ?? "Claude") (Cmd+Q)", Palette.amber))
        }
        let conflicts = rep.chats.filter { $0.result == "conflict" }.count
        if conflicts > 0 { out.append(("\(chats(conflicts)) continued in more than one profile: see Conflicts", Palette.red)) }
        let left = rep.chats.filter { ["deleted", "moved", "parent", "mismatch"].contains($0.result) }.count
        if left > 0 { out.append(("\(chats(left)) left out: deleted or moved away in a profile", Palette.secondary)) }
        for (k, e) in rep.errors.sorted(by: { $0.key < $1.key }) { out.append(("\(profile(k)?.name ?? k): \(e)", Palette.red)) }
        return out.isEmpty ? [("Everything is in sync", Palette.green)] : out
    }

    func reload() async {
        let r = await runTool(["status", "--json"])
        if r.code == 0, let st = try? JSONDecoder().decode(Status.self, from: Data(r.out.utf8)) {
            profiles = st.profiles
            items = st.chats
        } else {
            dialog = .message("Can't read the chats", clean(r.err.isEmpty ? "claude-chat failed (\(r.code))" : r.err))
        }
        let p = await runTool(["profiles", "--json"])
        allProfiles = (try? JSONDecoder().decode([ProfileInfo].self, from: Data(p.out.utf8))) ?? profiles
        let t = await runTool(["trash", "list", "--json"])
        trash = (try? JSONDecoder().decode([TrashEntry].self, from: Data(t.out.utf8))) ?? []
    }

    func copy(_ req: CopyRequest, force: Bool = false) async {
        guard !busy else { return }  // a sync is writing
        busy = true
        defer { busy = false }
        var args = ["copy", req.sourceSessionId, "--from", req.from.key, "--to", req.to.key, "--json"]
        if req.move { args.append("--move") } else if req.archive { args.append("--archive-source") }
        if force { args.append("--force") }
        let r = await runTool(args)
        switch r.code {
        case 0:
            dialog = .message("Done", summary(r.out, req))
        case exitAppOpen:
            dialog = .appOpen(req)
        case exitDiverged:
            dialog = .diverged(req, clean(r.err))
        case exitDestAhead:
            dialog = .message("Nothing to copy", "These chats are further along in \(req.to.name). Copy them the other way.")
        default:
            dialog = .message("Error", clean(r.err.isEmpty ? r.out : r.err))
        }
        await reload()
    }

    private func summary(_ out: String, _ req: CopyRequest) -> String {
        struct R: Decodable { struct C: Decodable { let title: String?; let state: String; let after: String? }; let chats: [C] }
        guard let r = try? JSONDecoder().decode(R.self, from: Data(out.utf8)) else { return out }
        let state = ["new": "copied", "newer": "updated", "same": "already identical", "diverged": "replaced (backup kept)",
                     "older": "left alone: newer in \(req.to.name)", "nosource": "skipped: no saved conversation"]
        let after = ["archived": "archived in \(req.from.name)", "removed": "removed from \(req.from.name) (in Trash)",
                     "kept": "kept in \(req.from.name): copies differ",
                     "archive-pending": "archived in \(req.from.name) when \(req.from.app) quits",
                     "remove-pending": "removed from \(req.from.name) when \(req.from.app) quits"]
        let lines = r.chats.map { c in
            "\(c.title ?? "Chat"): \(state[c.state] ?? c.state)" + (c.after.flatMap { after[$0] }.map { ", \($0)" } ?? "")
        }
        return lines.joined(separator: "\n") + "\n\nOpen \(req.to.app) to see the result."
    }

    func cancelPending(_ sessionId: String) async {
        _ = await runTool(["pending", "cancel", sessionId])
        await reload()
    }

    func restore(_ e: TrashEntry) async {
        let r = await runTool(["trash", "restore", e.id])
        if r.code == exitAppOpen {
            let name = allProfiles.first { $0.key == e.profile }?.app ?? "Claude"
            dialog = .message("Quit \(name) first", "Restore writes into that profile, so its app must be closed.")
        } else if r.code != 0 {
            dialog = .message("Can't restore", clean(r.err))
        }
        await reload()
    }

    func saveSettings(show: [String], names: [String: String], autoSync: Bool) async {
        var cfg = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: configFile)))) as? [String: Any] ?? [:]
        cfg["show"] = show
        cfg["names"] = names.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        cfg["autoSync"] = autoSync
        try? FileManager.default.createDirectory(atPath: (configFile as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: configFile))
        }
        await refresh()
    }
}

// MARK: - Filters

enum SyncFilter: Hashable {
    case all, only(String), inSync, update, conflict

    func includes(_ i: Item) -> Bool {
        switch self {
        case .all: return true
        case .only(let k): return i.kind == .only(k)
        case .inSync: return i.kind == .inSync
        case .update: return i.kind == .update
        case .conflict: return i.kind == .conflict
        }
    }
}

enum ArchiveFilter: String, CaseIterable, Identifiable {
    case active = "Active", archived = "Archived", all = "All"
    var id: String { rawValue }

    func includes(_ i: Item) -> Bool {
        switch self {
        case .active: return i.activeSomewhere
        case .archived: return i.archivedEverywhere
        case .all: return true
        }
    }
}

// MARK: - Views

struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.6)
            .foregroundStyle(Palette.secondary).padding(.horizontal, 6)
    }
}

struct ProfileCard: View {
    let p: ProfileInfo
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(p.name).fontWeight(.semibold)
                Spacer()
                Text(p.running ? "● open" : "○ closed").font(.system(size: 12))
                    .foregroundStyle(p.running ? Palette.green : Palette.secondary)
            }
            if let e = p.error {
                Text(e).font(.system(size: 12)).foregroundStyle(Palette.red).fixedSize(horizontal: false, vertical: true)
            } else if p.accountMismatch {
                Label("\(p.app) and Claude Code are signed in with different accounts",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(Palette.amber).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(p.email ?? "\(p.app) · account \(p.account.map { String($0.prefix(8)) } ?? "—")")
                    .font(.system(size: 12)).foregroundStyle(Palette.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.cardBorder))
    }
}

struct SyncCard: View {
    @ObservedObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(store.autoSync ? Palette.green : Palette.secondary)
                Text(store.autoSync ? "Auto-sync on" : "Auto-sync off").fontWeight(.semibold)
                Spacer()
                Button("Sync now") { Task { await store.refresh(sync: true) } }
                    .controlSize(.small).disabled(store.busy || store.refreshing)
            }
            if store.syncing {
                Text("Syncing…").font(.system(size: 12)).foregroundStyle(Palette.secondary)
            } else if let run = store.lastSync {
                ForEach(Array(store.syncNotes.enumerated()), id: \.offset) { _, n in
                    Text(n.text).font(.system(size: 12)).foregroundStyle(n.color).fixedSize(horizontal: false, vertical: true)
                }
                Text("Last sync \(dateFormatter.string(from: run.at))").font(.system(size: 11)).foregroundStyle(Palette.secondary)
            } else {
                Text(store.autoSync ? "Syncs when the app opens and when you switch back to it."
                                    : "Turn it on in Profiles… to sync each time the app opens.")
                    .font(.system(size: 12)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.cardBorder))
    }
}

struct Sidebar: View {
    @ObservedObject var store: Store
    @Binding var syncFilter: SyncFilter
    @Binding var archiveFilter: ArchiveFilter

    var filters: [(SyncFilter, String, String, Color)] {
        [(.all, "All", "•", Palette.secondary)]
            + store.profiles.map { (.only($0.key), "Only in \($0.name)", "●", store.color($0.key)) }
            + [(.inSync, "In sync", "✓", Palette.green), (.update, "Needs update", "⇄", Palette.amber),
               (.conflict, "Conflicts", "!", Palette.red)]
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle(text: "Profiles")
                        ForEach(store.profiles) { ProfileCard(p: $0, color: store.color($0.key)) }
                        SyncCard(store: store)
                        Text("To copy into a profile, quit its Claude app first.")
                            .font(.system(size: 12)).foregroundStyle(Palette.secondary).padding(.horizontal, 6)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        SectionTitle(text: "Sync").padding(.bottom, 6)
                        ForEach(filters, id: \.0) { f, label, glyph, color in
                            let n = store.items.filter { f.includes($0) && archiveFilter.includes($0) }.count
                            Button { syncFilter = f } label: {
                                HStack(spacing: 8) {
                                    Text(glyph).foregroundStyle(color).frame(width: 18)
                                    Text(label).foregroundStyle(Palette.text).lineLimit(1)
                                    Spacer()
                                    Text("\(n)").monospacedDigit().foregroundStyle(Palette.secondary)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 7)
                                .background(syncFilter == f ? Color(hex: 0x34343A) : .clear, in: RoundedRectangle(cornerRadius: 7))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(syncFilter == f ? .isSelected : [])
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle(text: "Archive")
                        Picker("Archive", selection: $archiveFilter) {
                            ForEach(ArchiveFilter.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden()
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 18)
            }
            Divider()
            HStack(spacing: 8) {
                Button { store.showTrash = true } label: {
                    Label(store.trash.isEmpty ? "Trash" : "Trash (\(store.trash.count))", systemImage: "trash")
                }
                Spacer()
                Button { store.showSettings = true } label: { Label("Profiles…", systemImage: "gearshape") }
            }
            .buttonStyle(.borderless).foregroundStyle(Palette.secondary)
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .frame(width: 260)
        .background(Palette.sidebar)
    }
}

let sideWidth: CGFloat = 132

struct ChatRow: View {
    @ObservedObject var store: Store
    let item: Item
    let depth: Int
    let descendants: Int
    let expanded: Bool
    let selected: Bool
    let onToggle: () -> Void
    let onSelect: () -> Void

    func cell(_ key: String) -> (String, Color) {
        guard let s = item.sides[key] else { return ("—", Palette.none) }
        var t: (String, Color)
        switch s.state {
        case "only": t = ("only here", store.color(key))
        case "same": t = ("✓ in sync", Palette.green)
        case "latest": t = ("● latest", Palette.amber)
        case "behind": t = ("○ behind", Palette.secondary)
        case "diverged": t = ("⚠ diverged", Palette.red)
        default: t = ("no transcript", Palette.secondary)
        }
        if let p = s.pending { t.0 += p == "remove" ? " · removing" : " · archiving" }
        else if s.archived { t.0 += " · arch." }
        return t
    }

    var body: some View {
        let pad = CGFloat(44 + depth * 22)
        ZStack(alignment: .leading) {
            Button(action: onSelect) {
                HStack(spacing: 0) {
                    HStack(spacing: 8) {
                        if depth > 0 { Text("└").foregroundStyle(Color(hex: 0x6F6F78)) }
                        Text(item.title).lineLimit(1).truncationMode(.tail)
                            .fontWeight(depth == 0 ? .semibold : .regular)
                            .foregroundStyle(item.archivedEverywhere ? Color(hex: 0xB4B4BB) : Palette.text)
                        if descendants > 0 {
                            Text("+\(descendants)").font(.system(size: 11)).padding(.horizontal, 7).padding(.vertical, 1)
                                .background(Color(hex: 0x3A3355), in: Capsule()).foregroundStyle(Color(hex: 0xC9BFFF))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 16)
                    ForEach(store.profiles) { p in
                        let (t, c) = cell(p.key)
                        Text(t).font(.system(size: 12)).foregroundStyle(c).lineLimit(1)
                            .frame(width: sideWidth, alignment: .leading)
                    }
                    Text(dateFormatter.string(from: Date(timeIntervalSince1970: item.lastActivityAt / 1000)))
                        .monospacedDigit().foregroundStyle(Palette.secondary).frame(width: 104, alignment: .leading)
                }
                .padding(.leading, pad).padding(.trailing, 20).padding(.vertical, 8)
                .frame(minHeight: 40)
                .background(selected ? Palette.selected : .clear)
                .overlay(alignment: .leading) { if selected { Rectangle().fill(Color(hex: 0x7C83F2)).frame(width: 3) } }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .contextMenu {
                ForEach(item.sides.filter { $0.value.pending != nil }.map(\.value.sessionId), id: \.self) { sid in
                    Button("Cancel queued archive/removal") { Task { await store.cancelPending(sid) } }
                }
            }
            if descendants > 0 {
                Button(action: onToggle) {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0)).foregroundStyle(Palette.secondary)
                        .frame(width: 24, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, pad - 26)
                .accessibilityLabel(expanded ? "Hide sub-chats" : "Show sub-chats")
            }
        }
    }
}

struct CompareTable: View {
    @ObservedObject var store: Store
    let syncFilter: SyncFilter
    let archiveFilter: ArchiveFilter
    let search: String
    @Binding var selection: String?
    @State private var closedProjects: Set<String> = []
    @State private var closedChats: Set<String> = []

    struct Group: Identifiable {
        let id: String
        let roots: [Item]
        let count: Int
        var name: String { id.isEmpty ? "No folder" : URL(fileURLWithPath: id).lastPathComponent }
    }

    func matches(_ i: Item) -> Bool {
        syncFilter.includes(i) && archiveFilter.includes(i)
            && (search.isEmpty || i.title.localizedCaseInsensitiveContains(search) || i.cwd.localizedCaseInsensitiveContains(search))
    }

    func maxActivity(_ r: Item) -> Double { subtree(r, in: store.items).map(\.item.lastActivityAt).max() ?? 0 }

    var groups: [Group] {
        let items = store.items
        let roots = items.filter { $0.parent == nil }.filter { subtree($0, in: items).contains { matches($0.item) } }
        return Dictionary(grouping: roots, by: \.project).map { key, rs in
            let sorted = rs.sorted { maxActivity($0) > maxActivity($1) }
            return Group(id: key, roots: sorted, count: sorted.reduce(0) { $0 + subtree($1, in: items).count })
        }
        .sorted { maxActivity($0.roots[0]) > maxActivity($1.roots[0]) }
    }

    func visibleRows(_ root: Item) -> [(item: Item, depth: Int)] {
        var out: [(item: Item, depth: Int)] = []
        func walk(_ i: Item, _ depth: Int) {
            out.append((i, depth))
            if closedChats.contains(i.id) { return }
            for k in children(of: i.id, in: store.items) { walk(k, depth + 1) }
        }
        walk(root, 0)
        return out
    }

    var body: some View {
        let gs = groups
        let shown = gs.reduce(0) { $0 + $1.count }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    if gs.isEmpty {
                        VStack(spacing: 6) {
                            Text(store.items.isEmpty ? "No chats yet" : "No chats match these filters")
                                .font(.system(size: 15)).foregroundStyle(Palette.text)
                            Text(store.items.isEmpty ? "Chats from the Code tab of each profile appear here."
                                                     : "Try “All” under Sync or Archive.")
                                .foregroundStyle(Palette.secondary)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 64)
                    }
                    ForEach(gs) { g in
                        projectHeader(g)
                        if !closedProjects.contains(g.id) {
                            ForEach(g.roots) { r in
                                ForEach(visibleRows(r), id: \.item.id) { row in
                                    ChatRow(store: store, item: row.item, depth: row.depth,
                                            descendants: subtree(row.item, in: store.items).count - 1,
                                            expanded: !closedChats.contains(row.item.id),
                                            selected: selection == row.item.id,
                                            onToggle: { toggle(&closedChats, row.item.id) },
                                            onSelect: { selection = row.item.id })
                                }
                            }
                        }
                    }
                } header: {
                    HStack(spacing: 0) {
                        Text("Chat · \(shown) shown").frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(store.profiles) { p in
                            HStack(spacing: 6) {
                                Circle().fill(store.color(p.key)).frame(width: 7, height: 7)
                                Text(p.name).lineLimit(1)
                            }
                            .frame(width: sideWidth, alignment: .leading)
                        }
                        Text("Last activity").frame(width: 104, alignment: .leading)
                    }
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.secondary).textCase(.uppercase)
                    .padding(.leading, 44).padding(.trailing, 20).padding(.vertical, 10)
                    .background(Palette.window)
                    .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
                }
            }
        }
        .background(Palette.window)
    }

    func projectHeader(_ g: Group) -> some View {
        let open = !closedProjects.contains(g.id)
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { toggle(&closedProjects, g.id) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(open ? 90 : 0)).foregroundStyle(Palette.secondary)
                Text(g.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.text)
                Text("\(g.count)").monospacedDigit().foregroundStyle(Palette.secondary)
                Rectangle().fill(Color(hex: 0x2E2E33)).frame(height: 1).padding(.leading, 8)
            }
            .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(g.id.isEmpty ? "Chats started without choosing a folder" : g.id)
        .accessibilityValue(open ? "expanded" : "collapsed")
    }

    func toggle(_ set: inout Set<String>, _ id: String) {
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
    }
}

struct TargetCard: View {
    @ObservedObject var store: Store
    let target: ProfileInfo
    let request: CopyRequest?
    let recommended: Bool

    var summary: String {
        guard let r = request else { return "Not in any other profile" }
        let count = { (o: Outcome) in r.lines.filter { $0.outcome == o }.count }
        var parts: [String] = []
        if count(.copy) > 0 { parts.append("\(count(.copy)) to copy") }
        if count(.update) > 0 { parts.append("\(count(.update)) to update") }
        if count(.same) > 0 { parts.append("\(count(.same)) identical") }
        if count(.skip) > 0 { parts.append("\(count(.skip)) newer in \(target.name), left alone") }
        if count(.absent) > 0 { parts.append("\(count(.absent)) not in \(r.from.name)") }
        return (parts.isEmpty ? "Nothing to do" : parts.joined(separator: " · ")) + " — from \(r.from.name)"
    }

    var body: some View {
        let work = request?.work ?? 0
        let conflicts = request?.lines.filter { $0.outcome == .conflict }.count ?? 0
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(store.color(target.key)).frame(width: 8, height: 8)
                Text("To \(target.name)").fontWeight(.semibold)
                if recommended {
                    Text("suggested").font(.system(size: 11)).padding(.horizontal, 7).padding(.vertical, 1)
                        .background(Color(hex: 0x23402B), in: Capsule()).foregroundStyle(Color(hex: 0x7EE29A))
                }
            }
            Text(summary).foregroundStyle(Color(hex: 0xC7C7CD)).fixedSize(horizontal: false, vertical: true)
            if conflicts > 0 {
                Text("\(conflicts) continued in both profiles: you will be asked which version to keep.")
                    .foregroundStyle(Palette.red).fixedSize(horizontal: false, vertical: true)
            }
            if let r = request {
                HStack(spacing: 8) {
                    Button(work > 0 ? "Copy" : (r.lines.allSatisfy { $0.outcome == .same } ? "In sync" : "Nothing to copy")) {
                        store.confirming = r
                    }
                    .buttonStyle(.borderedProminent).tint(recommended ? Palette.accent : Color(hex: 0x45454C))
                    .disabled(store.busy || work == 0)
                    Button("Move") { var m = r; m.move = true; store.confirming = m }
                        .disabled(store.busy || r.lines.allSatisfy { $0.outcome == .absent || $0.outcome == .skip })
                        .help("Copy, then remove from \(r.from.name). Removed chats can be restored from the Trash.")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(recommended ? Palette.accent : Palette.cardBorder))
    }
}

struct SelectionPanel: View {
    @ObservedObject var store: Store
    let item: Item

    func request(to t: ProfileInfo, group: [(item: Item, depth: Int)]) -> CopyRequest? {
        guard let s = source(for: item, group: group.map(\.item), target: t.key, among: store.profiles),
              let sid = item.sides[s.key]?.sessionId else { return nil }
        let lines = group.map { PlanLine(id: $0.item.id, title: $0.item.title, depth: $0.depth,
                                         outcome: outcome($0.item, from: s.key, to: t.key)) }
        return CopyRequest(from: s, to: t, sourceSessionId: sid, title: item.title, lines: lines)
    }

    var body: some View {
        let group = subtree(item, in: store.items)
        let reqs = store.profiles.map { ($0, request(to: $0, group: group)) }
        let best = reqs.max { ($0.1?.work ?? 0) < ($1.1?.work ?? 0) }
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(item.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text(group.count > 1 ? "Group of \(group.count) chats: the parent and its \(group.count - 1) sub-chat\(group.count == 2 ? "" : "s") move together"
                                     : "Single chat")
                    .foregroundStyle(Palette.secondary).lineLimit(1)
            }
            HStack(alignment: .top, spacing: 12) {
                ForEach(reqs, id: \.0.key) { t, r in
                    TargetCard(store: store, target: t, request: r,
                               recommended: (r?.work ?? 0) > 0 && best?.0.key == t.key)
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .background(Palette.bar)
        .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
    }
}

struct ConfirmSheet: View {
    @State var request: CopyRequest
    let onCancel: () -> Void
    let onConfirm: (CopyRequest) -> Void

    var body: some View {
        let r = request
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(r.move ? "Move" : "Copy") the \(r.noun) to \(r.to.name)?").font(.system(size: 17, weight: .semibold))
                Picker("Mode", selection: $request.move) {
                    Text("Copy").tag(false)
                    Text("Move").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                Text(r.lines.count > 1 ? "“\(r.title)” and its \(r.lines.count - 1) sub-chat\(r.lines.count == 2 ? "" : "s"), from \(r.from.name). Here is what happens to each:"
                                       : "“\(r.title)”, from \(r.from.name).")
                    .foregroundStyle(Color(hex: 0xC7C7CD)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 14)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(r.lines.enumerated()), id: \.element.id) { idx, l in
                        HStack(spacing: 12) {
                            HStack(spacing: 4) {
                                if l.depth > 0 { Text("└").foregroundStyle(Color(hex: 0x6F6F78)) }
                                Text(l.title).lineLimit(1).fontWeight(l.depth == 0 ? .semibold : .regular)
                            }
                            .padding(.leading, CGFloat(l.depth) * 20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text(l.outcome.label).foregroundStyle(l.outcome.color).frame(width: 230, alignment: .leading)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(idx % 2 == 1 ? Color(hex: 0x2E2E33) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(maxHeight: 300)

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Palette.amber)
                Text(r.move
                     ? "\(r.to.app) must be closed. Copied chats are then removed from \(r.from.name) — if \(r.from.app) is open, when it quits — and kept in the Trash, where you can restore them. A chat continued meanwhile is not removed."
                     : "\(r.to.app) must be closed while copying. Chats that are newer in \(r.to.name) are left alone.")
                    .foregroundStyle(Color(hex: 0xF5D9A8)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(Color(hex: 0x3A2A1A), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: 0x6B4A1E)))
            .padding(.horizontal, 24).padding(.top, 14)

            if !r.move {
                Toggle(isOn: $request.archive) {
                    Text("Then archive in \(r.from.name) ") + Text("(if \(r.from.app) is open, when it quits)").foregroundColor(Palette.secondary)
                }
                .toggleStyle(.checkbox).padding(.horizontal, 24).padding(.top, 14)
            }

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button(r.move ? "Move to \(r.to.name)" : (r.work > 0 ? "Copy \(r.work) to \(r.to.name)" : "Archive")) { onConfirm(request) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent).tint(Palette.accent)
                    .disabled(!r.move && r.work == 0 && !r.archive)
            }
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 22)
        }
        .frame(width: 620)
        .background(Color(hex: 0x262629))
    }
}

struct SettingsSheet: View {
    @ObservedObject var store: Store
    @State var show: [String]
    @State var names: [String: String]
    @State var autoSync: Bool
    let onDone: () -> Void

    init(store: Store, onDone: @escaping () -> Void) {
        self.store = store
        self.onDone = onDone
        _show = State(initialValue: store.profiles.map(\.key))
        _names = State(initialValue: Dictionary(uniqueKeysWithValues: store.allProfiles.map { ($0.key, $0.name) }))
        _autoSync = State(initialValue: store.autoSync)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Profiles").font(.system(size: 17, weight: .semibold))
            Text("Profiles come from claude-multiprofile, plus your default Claude. Pick up to three to compare, and give them names you recognise.")
                .foregroundStyle(Color(hex: 0xC7C7CD)).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(store.allProfiles) { p in
                    HStack(spacing: 12) {
                        Toggle("", isOn: Binding(
                            get: { show.contains(p.key) },
                            set: { on in if on { if show.count < 3 { show.append(p.key) } } else { show.removeAll { $0 == p.key } } }
                        ))
                        .toggleStyle(.checkbox).labelsHidden()
                        .disabled(!show.contains(p.key) && show.count >= 3)
                        TextField(p.key, text: Binding(get: { names[p.key] ?? "" }, set: { names[p.key] = $0 }))
                            .textFieldStyle(.roundedBorder).frame(width: 160)
                        Text(p.origin)
                            .foregroundStyle(Palette.secondary).frame(width: 190, alignment: .leading)
                            .help("Claude Code folder: \(p.codeDir ?? "?")")
                        Text(p.signedInAs).foregroundStyle(Palette.secondary).lineLimit(1).truncationMode(.middle)
                            .help(p.accountMismatch ? "Claude Code in the terminal is signed in as \(p.codeEmail ?? "another account")" : "")
                    }
                }
            }
            if store.allProfiles.count < 2 {
                Text("Only one profile found. Create another with claude-multiprofile, sign in, then come back.")
                    .foregroundStyle(Palette.amber).fixedSize(horizontal: false, vertical: true)
            }
            Toggle(isOn: $autoSync) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sync automatically when the app opens and when you switch back to it")
                    Text("Chats missing from a selected profile are copied there, and older copies brought up to date, in every direction. Chats continued in two profiles, deleted or moved away are left alone, and nothing is written into a profile while its Claude app is open.")
                        .foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)
            HStack {
                Text("\(show.count) of 3 selected").foregroundStyle(Palette.secondary)
                Spacer()
                Button("Cancel", action: onDone).keyboardShortcut(.cancelAction)
                Button("Save") {
                    Task { await store.saveSettings(show: show, names: names, autoSync: autoSync); onDone() }
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(Palette.accent)
                .disabled(show.count < 2)
            }
        }
        .padding(24)
        .frame(width: 720)
        .background(Color(hex: 0x262629))
    }
}

struct TrashSheet: View {
    @ObservedObject var store: Store
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Trash").font(.system(size: 17, weight: .semibold))
            Text("Chats removed by Move. Restoring puts a chat back in its profile, whose Claude app must be closed. Files stay in ~/.local/share/claude-chat-sync/trash until you delete them.")
                .foregroundStyle(Color(hex: 0xC7C7CD)).fixedSize(horizontal: false, vertical: true)
            if store.trash.isEmpty {
                Text("The Trash is empty.").foregroundStyle(Palette.secondary).padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(store.trash) { e in
                            HStack(spacing: 12) {
                                Circle().fill(store.color(e.profile)).frame(width: 8, height: 8)
                                Text(e.title ?? e.sessionId).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                Text(store.allProfiles.first { $0.key == e.profile }?.name ?? e.profile).foregroundStyle(Palette.secondary)
                                Text(dateFormatter.string(from: Date(timeIntervalSince1970: e.removedAt / 1000)))
                                    .monospacedDigit().foregroundStyle(Palette.secondary)
                                Button("Restore") { Task { await store.restore(e) } }.disabled(store.busy)
                            }
                            .padding(.vertical, 8)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
            HStack {
                Button("Show in Finder") {
                    let dir = NSString(string: "~/.local/share/claude-chat-sync/trash").expandingTildeInPath
                    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(URL(fileURLWithPath: dir))
                }
                Spacer()
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 640)
        .background(Color(hex: 0x262629))
    }
}

struct ContentView: View {
    @StateObject var store = Store()
    @State var search = ""
    @State var selection: String? = UserDefaults.standard.string(forKey: "select")  // `--args -select <key>` for testing
    @State var syncFilter: SyncFilter = .all
    @AppStorage("archiveFilter") var archiveFilter: ArchiveFilter = .active

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(store: store, syncFilter: $syncFilter, archiveFilter: $archiveFilter)
            Rectangle().fill(Palette.line).frame(width: 1)
            VStack(spacing: 0) {
                CompareTable(store: store, syncFilter: syncFilter, archiveFilter: archiveFilter,
                             search: search, selection: $selection)
                if let it = store.items.first(where: { $0.id == selection }) {
                    SelectionPanel(store: store, item: it)
                } else {
                    Text("Select a chat to see what copying or moving it would do. Sub-chats always travel with their parent.")
                        .foregroundStyle(Palette.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20).padding(.vertical, 16)
                        .background(Palette.bar)
                        .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
                }
            }
        }
        .foregroundStyle(Palette.text)
        .font(.system(size: 13))
        .background(Palette.window)
        .preferredColorScheme(.dark)
        .frame(minWidth: 1180, minHeight: 680)
        .searchable(text: $search, placement: .toolbar, prompt: "Search title or folder")
        .toolbar {
            ToolbarItem {
                Button { Task { await store.refresh(sync: true) } } label: {
                    Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                }
                .help("Sync now: copy missing and older chats between the profiles")
                .disabled(store.busy || store.refreshing)
            }
            ToolbarItem {
                Button { Task { await store.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Refresh")
            }
        }
        .task { await store.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await store.refresh() }
        }
        .sheet(item: $store.confirming) { req in
            ConfirmSheet(request: req, onCancel: { store.confirming = nil },
                         onConfirm: { r in store.confirming = nil; Task { await store.copy(r) } })
        }
        .sheet(isPresented: $store.showSettings) { SettingsSheet(store: store) { store.showSettings = false } }
        .sheet(isPresented: $store.showTrash) { TrashSheet(store: store) { store.showTrash = false } }
        .alert(item: $store.dialog) { d in alert(for: d) }
    }

    func alert(for d: Dialog) -> Alert {
        switch d {
        case .appOpen(let r):
            return Alert(title: Text("Quit \(r.to.app) first"),
                         message: Text("\(r.to.app) is open. Quit it (Cmd+Q in its window), then press Try Again."),
                         primaryButton: .default(Text("Try Again")) { Task { await store.copy(r) } },
                         secondaryButton: .cancel())
        case .diverged(let r, let detail):
            return Alert(title: Text("Some chats were continued in both profiles"),
                         message: Text("\(detail.components(separatedBy: ". With --force").first ?? detail).\n\n"
                                       + "Replace the \(r.to.name) versions with the \(r.from.name) ones? "
                                       + "The current \(r.to.name) versions are kept as backups. "
                                       + "Until you confirm, nothing in the group is touched."),
                         primaryButton: .destructive(Text("Replace")) { Task { await store.copy(r, force: true) } },
                         secondaryButton: .cancel())
        case .message(let t, let m):
            return Alert(title: Text(t), message: Text(m), dismissButton: .default(Text("OK")))
        }
    }
}

@main
struct ClaudeChatSyncApp: App {
    var body: some Scene {
        WindowGroup("Claude Chat Sync") {
            ContentView()
        }
        .defaultSize(width: 1240, height: 880)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
    }
}
