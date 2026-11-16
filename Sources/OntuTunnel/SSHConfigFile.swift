import AppKit
import Foundation

/// ~/.ssh/config: short names for servers ("ssh adimyra-vm"). OntuTunnel shows
/// the entries, opens the file for editing, and adds or updates one entry
/// with valid syntax (backup first, checked with `ssh -G`, put back if wrong).
enum SSHConfigFile {
    static var url: URL {
        if let test = ProcessInfo.processInfo.environment["ONTUTUNNEL_SSH_CONFIG"] { return URL(fileURLWithPath: test) }   // self-test only
        return URL(fileURLWithPath: ("~/.ssh/config" as NSString).expandingTildeInPath)
    }

    struct Entry: Identifiable, Hashable {
        let alias: String
        var hostName = "", user = "", port = "", identityFile = ""
        var id: String { alias }
    }

    static func read() -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    /// Host blocks with a single name (wildcards and lists are skipped).
    static func entries() -> [Entry] {
        var out: [Entry] = []
        var cur: Entry?
        for raw in read().components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" }).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased(), value = parts[1].trimmingCharacters(in: .whitespaces)
            if key == "host" || key == "match" {
                if let c = cur { out.append(c) }
                cur = (key == "host" && !value.contains(" ") && !value.contains("*") && !value.contains("?")) ? Entry(alias: value) : nil
                continue
            }
            switch key {
            case "hostname": cur?.hostName = value
            case "user": cur?.user = value
            case "port": cur?.port = value
            case "identityfile": cur?.identityFile = value
            default: break
            }
        }
        if let c = cur { out.append(c) }
        return out
    }

    static func entry(_ alias: String) -> Entry? { entries().first { $0.alias == alias } }

    static func isValidAlias(_ s: String) -> Bool {
        s.range(of: "^[A-Za-z0-9._-]{1,64}$", options: .regularExpression) != nil
    }

    static func block(alias: String, hostName: String, user: String, port: Int, identityFile: String) -> String {
        var b = "Host \(alias)\n    HostName \(hostName)\n"
        if !user.isEmpty { b += "    User \(user)\n" }
        if port != 22 { b += "    Port \(port)\n" }
        if !identityFile.isEmpty { b += "    IdentityFile \(identityFile)\n" }
        return b
    }

    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
    }

    /// Adds `Host alias` or replaces that block; everything else stays as it is.
    static func upsert(alias: String, hostName: String, user: String, port: Int, identityFile: String) throws {
        guard isValidAlias(alias) else { throw Failure.message("Name: letters, numbers, . _ - only (e.g. adimyra-vm).") }
        guard hostName.range(of: "^[A-Za-z0-9.:_-]{1,253}$", options: .regularExpression) != nil else {
            throw Failure.message("\"\(hostName)\" is not a valid server address.")
        }
        guard user.isEmpty || user.range(of: "^[A-Za-z0-9._-]{1,64}$", options: .regularExpression) != nil else {
            throw Failure.message("\"\(user)\" is not a valid user name.")
        }
        let new = block(alias: alias, hostName: hostName, user: user, port: port, identityFile: identityFile)
        let old = read()
        var lines = old.components(separatedBy: "\n")
        // find "Host <alias>" and the end of its block (next Host/Match line)
        func isHeader(_ l: String) -> Bool {
            let t = l.trimmingCharacters(in: .whitespaces).lowercased()
            return t.hasPrefix("host ") || t.hasPrefix("host\t") || t.hasPrefix("match ") || t.hasPrefix("host=")
        }
        if let start = lines.firstIndex(where: {
            let p = $0.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            return p.count == 2 && p[0].lowercased() == "host" && p[1] == alias
        }) {
            var end = start + 1
            while end < lines.count && !isHeader(lines[end]) { end += 1 }
            // keep blank lines that separate blocks
            while end > start + 1 && lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
            // keep the block's other settings (IdentitiesOnly, ProxyJump …)
            let managed: Set<String> = ["hostname", "user", "port", "identityfile"]
            let others = lines[(start + 1)..<end].filter { l in
                let key = l.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" }).first.map { $0.lowercased() } ?? ""
                return !managed.contains(key)
            }
            lines.replaceSubrange(start..<end, with: new.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init) + others)
        } else {
            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
            if !lines.isEmpty { lines.append("") }
            lines.append(contentsOf: new.split(separator: "\n").map(String.init))
        }
        var content = lines.joined(separator: "\n")
        if !content.hasSuffix("\n") { content += "\n" }
        try write(content, previous: old, check: alias)
    }

    /// Writes with a backup, checks the syntax with ssh, puts the old file back if wrong.
    private static func write(_ content: String, previous: String, check alias: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !previous.isEmpty {
            try previous.write(to: url.deletingLastPathComponent().appendingPathComponent("config.ontutunnel-backup"), atomically: true, encoding: .utf8)
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let t = Process()
        t.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        t.arguments = ["-G", "-F", url.path, alias]
        t.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        t.standardError = err
        try t.run()
        t.waitUntilExit()
        if t.terminationStatus != 0 {
            try previous.write(to: url, atomically: true, encoding: .utf8)
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw Failure.message("ssh didn't accept the file, so it was put back: \(msg.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    private static func ensureFile() {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        }
    }

    /// Opens the file in Terminal with nano.
    static func editInTerminal() {
        ensureFile()
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("Edit SSH config.command")
        try? "#!/bin/zsh\nclear\necho 'Editing ~/.ssh/config — save: Ctrl+O, Enter · quit: Ctrl+X'\nsleep 1\nnano ~/.ssh/config\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        NSWorkspace.shared.open(script)
    }

    static func openInTextEdit() {
        ensureFile()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-e", url.path]
        try? p.run()
    }

    static func revealInFinder() {
        ensureFile()
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Short name for this computer ("fz-mac-mini").
    static var thisComputerAlias: String {
        let name = ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: "")
        let clean = name.lowercased().map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" }
        let s = String(clean).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return s.isEmpty ? "my-mac" : s
    }
}
