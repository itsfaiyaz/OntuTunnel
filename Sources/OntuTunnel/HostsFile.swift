import Foundation

/// This Mac's /etc/hosts: list, add, change and delete entries, plus the
/// block OntuTunnel keeps for "My static IP" (sites → 127.0.0.1, because
/// many routers can't reach their own public IP from inside). Writing needs
/// admin rights: macOS asks for the password once per save.
enum HostsFile {
    static let path = "/etc/hosts"
    static let begin = "# BEGIN OntuTunnel (added automatically, do not edit)"
    static let end = "# END OntuTunnel"
    private static let systemNames: Set<String> = ["localhost", "broadcasthost", "ip6-localhost", "ip6-loopback"]

    struct Entry: Identifiable, Hashable {
        enum Source: String { case you, ontutunnel, system }
        let line: Int          // index in the file; -1 inside OntuTunnel's block
        let ip: String
        let names: String
        let source: Source
        let raw: String
        var id: String { "\(line)|\(raw)" }
    }

    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
    }

    static func read() -> String {
        ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").replacingOccurrences(of: "\r\n", with: "\n")
    }

    static func isIP(_ s: String) -> Bool {
        var a4 = in_addr(), a6 = in6_addr()
        return inet_pton(AF_INET, s, &a4) == 1 || inet_pton(AF_INET6, s, &a6) == 1
    }

    static func isDomain(_ s: String) -> Bool {
        s.range(of: #"^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$"#, options: .regularExpression) != nil
    }

    static func entries() -> [Entry] {
        var out: [Entry] = []
        var inBlock = false
        for (i, line) in read().components(separatedBy: "\n").enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == begin { inBlock = true; continue }
            if t == end { inBlock = false; continue }
            let body = t.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let f = body.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard f.count >= 2, isIP(f[0]) else { continue }
            let source: Entry.Source = inBlock ? .ontutunnel : systemNames.contains(f[1].lowercased()) ? .system : .you
            out.append(Entry(line: inBlock ? -1 : i, ip: f[0], names: f.dropFirst().joined(separator: " "), source: source, raw: line))
        }
        return out
    }

    /// The file without OntuTunnel's block, and the domains in that block.
    static func split(_ content: String) -> (rest: String, ours: [String]) {
        var keep: [String] = [], ours: [String] = []
        var inBlock = false
        for line in content.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == begin { inBlock = true; continue }
            if t == end { inBlock = false; continue }
            if inBlock {
                let f = t.split(whereSeparator: { $0 == " " || $0 == "\t" })
                if f.count >= 2 { ours.append(String(f[1])) }
            } else {
                keep.append(line)
            }
        }
        var rest = keep.joined(separator: "\n")
        while rest.hasSuffix("\n") { rest.removeLast() }
        return (rest + "\n", ours)
    }

    static func build(rest: String, domains: [String]) -> String {
        guard !domains.isEmpty else { return rest }
        return rest + "\n" + begin + "\n" + domains.map { "127.0.0.1\t\($0)" }.joined(separator: "\n") + "\n" + end + "\n"
    }

    static func validate(_ content: String) throws {
        for (n, line) in content.components(separatedBy: "\n").enumerated() {
            let body = (line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "")
                .trimmingCharacters(in: .whitespaces)
            if body.isEmpty { continue }
            let f = body.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if f.count < 2 || !isIP(f[0]) { throw Failure.message("Line \(n + 1) is not \"IP name\": \(line)") }
        }
    }

    enum Edit { case add, update(Entry), delete(Entry) }

    /// The new file after one change.
    static func applying(_ edit: Edit, ip: String, names: String) throws -> String {
        var lines = read().components(separatedBy: "\n")
        var newLine = ""
        if case .delete = edit {} else {
            let ip = ip.trimmingCharacters(in: .whitespaces)
            guard isIP(ip) else { throw Failure.message("\"\(ip)\" is not an IP address.") }
            let list = names.lowercased().split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
            guard !list.isEmpty else { throw Failure.message("Enter a domain.") }
            for n in list where !isDomain(n) && n != "localhost" { throw Failure.message("\"\(n)\" is not a valid domain.") }
            newLine = ip + "\t" + list.joined(separator: " ")
        }
        switch edit {
        case .add:
            var at = lines.count
            while at > 0 && lines[at - 1].trimmingCharacters(in: .whitespaces).isEmpty { at -= 1 }
            if let b = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == begin }) { at = b }
            lines.insert(newLine, at: at)
        case .update(let e), .delete(let e):
            guard e.line >= 0, e.line < lines.count, lines[e.line] == e.raw else {
                throw Failure.message("The hosts file changed meanwhile — look again and retry.")
            }
            if case .update = edit { lines[e.line] = newLine } else { lines.remove(at: e.line) }
        }
        var content = lines.joined(separator: "\n")
        if !content.hasSuffix("\n") { content += "\n" }
        return content
    }

    /// Writes the whole file with admin rights (macOS asks for the password)
    /// and clears the DNS cache.
    static func writeAsAdmin(_ content: String) throws {
        try validate(content)
        let dir = ConfigFile.url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent("hosts.new")
        try content.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let script = [
            "on run argv",
            "do shell script \"cat \" & quoted form of (item 1 of argv) & \" > /etc/hosts && dscacheutil -flushcache; killall -HUP mDNSResponder || true\" with administrator privileges",
            "end run",
        ]
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = script.flatMap { ["-e", $0] } + [tmp.path]
        let err = Pipe()
        task.standardError = err
        task.standardOutput = FileHandle.nullDevice
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw Failure.message(msg.contains("-128") ? "Admin password was not given." : msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
