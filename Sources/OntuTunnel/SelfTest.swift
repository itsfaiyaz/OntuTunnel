import Foundation

/// Developer checks from Terminal (no UI):
///   OntuTunnel --probe <host> <user> <key>      read-only server check
///   OntuTunnel --print-config                   show generated Caddy + nginx files
///   OntuTunnel --tunnel-test <host> <user> <key> <localPort>
enum SelfTest {
    static func runIfRequested() {
        let a = CommandLine.arguments
        guard a.count >= 2, a[1].hasPrefix("--probe") || a[1] == "--print-config" || a[1] == "--tunnel-test" || a[1] == "--ports" || a[1] == "--proxy-test" else { return }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            var s = ServerConfig()
            if a.count >= 5 { s.host = a[2]; s.user = a[3]; s.keyPath = a[4] }
            switch a[1] {
            case "--probe":
                let (r, f) = await RemoteServer.probe(s)
                if let f {
                    print("os=\(f.os) arch=\(f.arch) sudo=\(f.sudo) port80=\(f.port80) port443=\(f.port443) nginx=\(f.nginx) certbot=\(f.certbot) ourCaddy=\(f.ourCaddy) forwarding=\(f.forwarding)")
                    print("used ports: \(f.usedPorts.sorted())")
                    switch f.plan { case .use(let m): print("PLAN: \(m)"); case .blocked(let w): print("BLOCKED: \(w)") }
                } else { print("FAILED: \(r.message)") }
            case "--ports":
                for p in LocalPorts.scan() { print("\(p.port)\t\(p.process)\t\(p.address)") }
                let n = await NetworkInfo.snapshot()
                print("public=\(n.publicIPv4) lan=\(n.localIPv4) ipv6=\(n.ipv6) router=\(n.router)")
            case "--proxy-test":
                let proxy = ProxyServer()
                proxy.assumeHTTPS = true
                var r = Route(serviceID: UUID(), localPort: 8001, frappeSite: "mysite.local", hostOverride: "", httpsAvailable: false)
                r.socketPort = 9001
                proxy.updateRoutes(["star.test": r])
                proxy.onState = { print("proxy: \($0)") }
                proxy.start(port: 18080, loopbackOnly: true)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                for path in ["/api/method/ping", "/socket.io/?EIO=4&transport=polling"] {
                    let out = Shell.run("/usr/bin/curl", ["-s", "-o", "/dev/null", "-w", "%{http_code}", "-H", "Host: star.test", "http://127.0.0.1:18080\(path)"])
                    print("\(path) → \(out)")
                }
                let ext = Shell.run("/usr/bin/curl", ["-s", "-o", "/dev/null", "-m", "3", "-w", "%{http_code}", "http://\(Shell.run("/usr/sbin/ipconfig", ["getifaddr", "en1"]).trimmingCharacters(in: .whitespacesAndNewlines)):18080/"])
                print("from LAN address (should fail, loopback only): \(ext)")
            case "--print-config":
                var svc = Service(name: "My Shop", domain: "shop.example.com", localPort: 8001)
                svc.frappeSite = "mysite.local"; svc.socketPort = 9001; svc.remotePort = 23456; svc.remoteSocketPort = 34567
                print("===== Caddyfile =====\n" + RemoteServer.caddyfile([svc], email: ""))
                print("===== nginx (before cert) =====\n" + RemoteServer.nginxConf(svc, withTLS: false))
                print("===== nginx (with cert) =====\n" + RemoteServer.nginxConf(svc, withTLS: true))
            default:
                let local = Int(a[5]) ?? 8001
                let (_, f) = await RemoteServer.probe(s)
                let remote = RemoteServer.freePort(avoiding: f?.usedPorts ?? [])
                let t = Tunnel()
                t.onState = { print("tunnel: \($0)") }
                t.onLog = { line, _ in print("log: \(line)") }
                t.start(server: s, forwards: [(remote: remote, local: local)])
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                let r = await RemoteServer.run(s, "curl -s -o /dev/null -m 10 -w '%{http_code}' http://127.0.0.1:\(remote)/api/method/ping; echo; ss -tln | grep -c ':\(remote) '")
                print("server → 127.0.0.1:\(remote) → Mac:\(local): HTTP \(r.out.split(separator: "\n").first ?? "?") (listeners: \(r.out.split(separator: "\n").last ?? "?"))")
                t.stop()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                let after = await RemoteServer.run(s, "ss -tln | grep -c ':\(remote) ' || true")
                print("after stop, listeners on \(remote): \(after.out.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            done.signal()
        }
        done.wait()
        exit(0)
    }
}
