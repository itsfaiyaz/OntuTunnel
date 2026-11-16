import AppKit
import SwiftUI

/// This Mac's ~/.ssh/authorized_keys: the computers allowed to log in over
/// SSH (Remote access) without a password. Each added key is checked with
/// ssh-keygen first; a backup of the old file is kept.
enum AuthorizedKeys {
    static var url: URL {
        if let test = ProcessInfo.processInfo.environment["ONTUTUNNEL_AUTHORIZED_KEYS"] { return URL(fileURLWithPath: test) }   // tests only
        return URL(fileURLWithPath: ("~/.ssh/authorized_keys" as NSString).expandingTildeInPath)
    }

    struct Key: Identifiable, Hashable {
        let line: String
        var id: String { line }
        var type: String { String(line.split(separator: " ").first(where: { $0.hasPrefix("ssh-") || $0.hasPrefix("ecdsa-") || $0.hasPrefix("sk-") }) ?? "key") }
        /// The name at the end of the key ("faiyaz@laptop"), or a short part of the key.
        var label: String {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if let i = parts.firstIndex(where: { $0.hasPrefix("ssh-") || $0.hasPrefix("ecdsa-") || $0.hasPrefix("sk-") }), parts.count > i + 2 {
                return parts[(i + 2)...].joined(separator: " ")
            }
            return parts.count > 1 ? "…" + String(parts[1].suffix(12)) : line
        }
    }

    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
    }

    static func keys() -> [Key] {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { Key(line: $0) }
    }

    /// Fingerprint from ssh-keygen, nil when the text is not a public key.
    static func fingerprint(_ line: String) -> String? {
        let t = Process()
        t.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        t.arguments = ["-l", "-f", "-"]
        let input = Pipe(), output = Pipe()
        t.standardInput = input
        t.standardOutput = output
        t.standardError = FileHandle.nullDevice
        guard (try? t.run()) != nil else { return nil }
        input.fileHandleForWriting.write(Data((line + "\n").utf8))
        try? input.fileHandleForWriting.close()
        t.waitUntilExit()
        guard t.terminationStatus == 0 else { return nil }
        let out = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out.split(separator: " ").dropFirst().first.map(String.init)
    }

    static func add(_ text: String) throws {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.contains("\n") else { throw Failure.message("Paste one key at a time (one line).") }
        guard !line.contains("PRIVATE KEY") else { throw Failure.message("That's a private key — never share it. Paste the .pub file (it starts with ssh-ed25519 or ssh-rsa).") }
        guard let fp = fingerprint(line) else { throw Failure.message("That isn't an SSH public key. It starts with ssh-ed25519 (or ssh-rsa) and comes from a .pub file.") }
        let current = keys()
        guard !current.contains(where: { fingerprint($0.line) == fp }) else { throw Failure.message("This key is already allowed.") }
        try write(current.map(\.line) + [line])
    }

    static func remove(_ key: Key) throws {
        try write(keys().map(\.line).filter { $0 != key.line })
    }

    private static func write(_ lines: [String]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let old = try? String(contentsOf: url, encoding: .utf8), !old.isEmpty {
            try old.write(to: url.deletingLastPathComponent().appendingPathComponent("authorized_keys.ontutunnel-backup"), atomically: true, encoding: .utf8)
        }
        // keep comment lines that were in the file
        let comments = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").components(separatedBy: "\n").filter { $0.hasPrefix("#") }
        try ((comments + lines).joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Remote access → computers that may log in to this Mac without a password.
struct AuthorizedKeysCard: View {
    @EnvironmentObject var model: AppModel
    @State private var keys: [AuthorizedKeys.Key] = []
    @State private var newKey = ""
    @State private var message = ""
    @State private var ok = false
    @State private var confirm: AuthorizedKeys.Key?

    var body: some View {
        Card(title: "Computers allowed without a password", icon: "key.viewfinder") {
            Text("Paste the other computer's **public** key here; it can then log in to this Mac over SSH without a password. File: ~/.ssh/authorized_keys")
                .font(.caption).foregroundStyle(.secondary)
            if keys.isEmpty {
                Text("None yet — logging in asks for this Mac's password.").foregroundStyle(.secondary)
            }
            ForEach(keys) { k in
                HStack(spacing: 10) {
                    Image(systemName: "desktopcomputer").foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(k.label).font(.system(.body, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        Text(k.type.replacingOccurrences(of: "ssh-", with: "").uppercased()).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) { confirm = k } label: { Image(systemName: "trash") }
                }
            }
            HStack {
                TextField("ssh-ed25519 AAAA… name@computer", text: $newKey).textFieldStyle(.roundedBorder)
                Button("Add key") {
                    do { try AuthorizedKeys.add(newKey); newKey = ""; ok = true; message = "Added. That computer can now log in without a password." }
                    catch { ok = false; message = error.localizedDescription }
                    reload()
                }
                .buttonStyle(.borderedProminent)
                .disabled(newKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !message.isEmpty {
                Label(message, systemImage: ok ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(ok ? .green : .red)
            }
            DisclosureGroup("Where do I find the other computer's key?") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mac / Linux: Terminal → `cat ~/.ssh/id_ed25519.pub`")
                    Text("Windows: PowerShell → `type $env:USERPROFILE\\.ssh\\id_ed25519.pub`")
                    Text("No key yet? Create one there with `ssh-keygen -t ed25519` (press Enter for every question), then show it as above.")
                    Text("Copy the whole line (starts with ssh-ed25519) and paste it here. Never paste the file without .pub — that one is private.")
                }
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled).padding(.top, 4)
            }
        }
        .onAppear(perform: reload)
        .confirmationDialog("Remove \(confirm?.label ?? "this key")?", isPresented: Binding(
            get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button("Remove", role: .destructive) {
                if let k = confirm {
                    do { try AuthorizedKeys.remove(k); ok = true; message = "Removed. That computer needs the password again." }
                    catch { ok = false; message = error.localizedDescription }
                }
                reload()
            }
        } message: {
            Text("That computer can then log in only with this Mac's password.")
        }
    }

    private func reload() { keys = AuthorizedKeys.keys() }
}
