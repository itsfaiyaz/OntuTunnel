import Foundation

/// Cloudflare Tunnel mode, driven through the official `cloudflared` tool:
///   install → `tunnel login` (browser, once) → `tunnel create` →
///   `tunnel route dns` per domain → `tunnel run` (kept alive).
/// cloudflared sends every hostname to OntuTunnel's local proxy on
/// 127.0.0.1, which routes by domain to the right local port.
enum Cloudflare {
    static var supportDir: URL { ConfigFile.url.deletingLastPathComponent() }
    static var configFile: URL { supportDir.appendingPathComponent("cloudflared.yml") }
    static var bundledBinary: URL { supportDir.appendingPathComponent("bin/cloudflared") }
    static var cfHome: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cloudflared") }
    static var certFile: URL { cfHome.appendingPathComponent("cert.pem") }

    /// Path of an installed cloudflared, if any.
    static func binary() -> String? {
        for path in ["/opt/homebrew/bin/cloudflared", "/usr/local/bin/cloudflared", bundledBinary.path]
        where FileManager.default.isExecutableFile(atPath: path) { return path }
        return nil
    }

    static var isLoggedIn: Bool { FileManager.default.fileExists(atPath: certFile.path) }

    struct Output { let code: Int32; let out: String; let err: String; var text: String { (out + err).trimmingCharacters(in: .whitespacesAndNewlines) } }

    static func exec(_ path: String, _ args: [String], timeout: TimeInterval = 120) async -> Output {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: path)
                task.arguments = args
                let out = Pipe(), err = Pipe()
                task.standardOutput = out
                task.standardError = err
                task.standardInput = FileHandle.nullDevice
                do { try task.run() } catch {
                    cont.resume(returning: Output(code: -1, out: "", err: error.localizedDescription)); return
                }
                let killer = DispatchWorkItem { if task.isRunning { task.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let o = out.fileHandleForReading.readDataToEndOfFile()
                let e = err.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                killer.cancel()
                cont.resume(returning: Output(code: task.terminationStatus,
                                              out: String(data: o, encoding: .utf8) ?? "",
                                              err: String(data: e, encoding: .utf8) ?? ""))
            }
        }
    }

    /// Installs cloudflared: Homebrew if present, else the official release.
    static func install() async -> Result<String, DNSError> {
        if let b = binary() { return .success(b) }
        if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/brew") {
            let r = await exec("/opt/homebrew/bin/brew", ["install", "cloudflared"], timeout: 600)
            if let b = binary() { return .success(b) }
            if r.code != 0 { /* fall through to the direct download */ }
        }
        let arch = Shell.run("/usr/bin/uname", ["-m"]).trimmingCharacters(in: .whitespacesAndNewlines) == "arm64" ? "arm64" : "amd64"
        let url = "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-\(arch).tgz"
        let dir = bundledBinary.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tgz = dir.appendingPathComponent("cloudflared.tgz").path
        let dl = await exec("/usr/bin/curl", ["-fsSL", url, "-o", tgz], timeout: 300)
        guard dl.code == 0 else { return .failure(DNSError(message: "Download failed: \(dl.text)")) }
        _ = await exec("/usr/bin/tar", ["-xzf", tgz, "-C", dir.path])
        try? FileManager.default.removeItem(atPath: tgz)
        _ = await exec("/bin/chmod", ["+x", bundledBinary.path])
        _ = await exec("/usr/bin/xattr", ["-d", "com.apple.quarantine", bundledBinary.path])
        return binary().map { .success($0) } ?? .failure(DNSError(message: "cloudflared was not found after installing."))
    }

    /// Opens Cloudflare in the browser; finishes when the user has chosen a domain.
    static func login(_ bin: String) async -> Output {
        await exec(bin, ["tunnel", "login"], timeout: 600)
    }

    /// Finds or creates the named tunnel, returns its ID.
    static func ensureTunnel(_ bin: String, name: String) async -> Result<String, DNSError> {
        if let id = await findTunnel(bin, name: name) { return .success(id) }
        let r = await exec(bin, ["tunnel", "create", name])
        if let id = await findTunnel(bin, name: name) { return .success(id) }
        return .failure(DNSError(message: "Could not create the tunnel: \(r.text)"))
    }

    private static func findTunnel(_ bin: String, name: String) async -> String? {
        let r = await exec(bin, ["tunnel", "list", "--output", "json"])
        guard let data = r.out.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        return list.first { ($0["name"] as? String) == name && ($0["deleted_at"] as? String).map { $0.hasPrefix("0001") } ?? true }?["id"] as? String
    }

    /// Creates/updates the CNAME for `domain` → the tunnel in Cloudflare DNS.
    static func routeDNS(_ bin: String, tunnelID: String, domain: String) async -> Output {
        await exec(bin, ["tunnel", "route", "dns", "--overwrite-dns", tunnelID, domain])
    }

    static func writeConfig(tunnelID: String, proxyPort: Int) throws {
        let creds = cfHome.appendingPathComponent("\(tunnelID).json").path
        let yaml = """
        # Written by OntuTunnel — replaced on every sync.
        tunnel: \(tunnelID)
        credentials-file: \(creds)
        ingress:
          - service: http://127.0.0.1:\(proxyPort)
        """
        try yaml.write(to: configFile, atomically: true, encoding: .utf8)
    }

    static func runArguments() -> [String] {
        ["tunnel", "--no-autoupdate", "--config", configFile.path, "run"]
    }
}
