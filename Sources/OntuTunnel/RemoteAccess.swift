import AppKit
import SwiftUI

// "My server (SSH)" → Remote access: ports of this Mac (SSH, Screen Sharing …)
// reachable from anywhere at the server's fixed public IP, e.g.
// 34.47.187.74:2201 → this Mac's port 22. The SSH tunnel brings each port to
// a loopback port on the server; for every public port OntuTunnel adds two
// systemd units of its own (ontutunnel-tcp-<port>.socket / .service) that pass
// connections on to it. Nothing else on the server is changed.

extension RemoteServer {
    static func remotePortsScript(_ ports: [RemotePort], published: [Int]) -> String {
        let active = ports.filter { $0.enabled && $0.tunnelPort > 0 && (1...65535).contains($0.publicPort) }
        let gone = published.filter { p in !active.contains { $0.publicPort == p } }
        var s = """
        set -e
        P=$(command -v systemd-socket-proxyd || ls /lib/systemd/systemd-socket-proxyd /usr/lib/systemd/systemd-socket-proxyd 2>/dev/null | head -1)
        [ -n "$P" ] || { echo "This server has no systemd-socket-proxyd (it needs systemd)." >&2; exit 5; }
        U=/etc/systemd/system

        """
        for p in gone {
            s += """
            sudo systemctl disable --now ontutunnel-tcp-\(p).socket >/dev/null 2>&1 || true
            sudo systemctl stop ontutunnel-tcp-\(p).service >/dev/null 2>&1 || true
            sudo rm -f $U/ontutunnel-tcp-\(p).socket $U/ontutunnel-tcp-\(p).service

            """
        }
        // a port another computer (or another program) already uses is refused
        for p in active where !published.contains(p.publicPort) {
            s += """
            if [ -e $U/ontutunnel-tcp-\(p.publicPort).service ]; then
              if ! grep -q "127.0.0.1:\(p.tunnelPort)$" $U/ontutunnel-tcp-\(p.publicPort).service; then echo "CONFLICT: Port \(p.publicPort) is already used by another computer with OntuTunnel. Choose another port." >&2; exit 3; fi
            elif ss -tlnH | awk '{print $4}' | grep -qE '[:.]\(p.publicPort)$'; then
              echo "CONFLICT: Port \(p.publicPort) is already used on the server by another program. Choose another port." >&2; exit 3
            fi

            """
        }
        for p in active {
            s += """
            sudo tee $U/ontutunnel-tcp-\(p.publicPort).socket >/dev/null <<UNIT
            [Unit]
            Description=OntuTunnel remote access: public port \(p.publicPort)
            [Socket]
            ListenStream=\(p.publicPort)
            [Install]
            WantedBy=sockets.target
            UNIT
            sudo tee $U/ontutunnel-tcp-\(p.publicPort).service >/dev/null <<UNIT
            [Unit]
            Description=OntuTunnel remote access: port \(p.publicPort) to the computer's tunnel
            Requires=ontutunnel-tcp-\(p.publicPort).socket
            After=ontutunnel-tcp-\(p.publicPort).socket
            [Service]
            ExecStart=$P 127.0.0.1:\(p.tunnelPort)
            UNIT

            """
        }
        s += "sudo systemctl daemon-reload\n"
        for p in active {
            s += """
            sudo systemctl stop ontutunnel-tcp-\(p.publicPort).service >/dev/null 2>&1 || true
            sudo systemctl enable ontutunnel-tcp-\(p.publicPort).socket >/dev/null 2>&1
            sudo systemctl restart ontutunnel-tcp-\(p.publicPort).socket

            """
        }
        return s + "echo REMOTE-OK\n"
    }
}

extension AppModel {
    /// The server's fixed public IP (what people outside connect to).
    var publicServerIP: String { serverIP.isEmpty ? config.server.host : serverIP }

    /// A free public port, starting at `from` (2201, 5901 …).
    func suggestPublicPort(from start: Int) -> Int {
        let mine = Set(config.remotePorts.map(\.publicPort))
        let used = facts?.usedPorts ?? []
        let others = Set((facts?.reserved ?? [:]).keys.compactMap { $0.hasPrefix("tcp-") ? Int($0.dropFirst(4)) : nil })
        var p = start
        while mine.contains(p) || used.contains(p) || others.contains(p) { p += 1 }
        return p
    }

    func addRemotePort(name: String, localPort: Int, publicPort: Int) async -> String? {
        guard (1...65535).contains(localPort), (1024...65535).contains(publicPort) else {
            return "Ports: this Mac 1–65535, public 1024–65535."
        }
        guard !config.remotePorts.contains(where: { $0.publicPort == publicPort }) else {
            return "Public port \(publicPort) is already in the list."
        }
        let clean = name.trimmingCharacters(in: .whitespaces)
        config.remotePorts.append(RemotePort(name: clean.isEmpty ? "Port \(localPort)" : clean, localPort: localPort, publicPort: publicPort))
        let err = await syncRemoteAccess()
        if err != nil { config.remotePorts.removeAll { $0.publicPort == publicPort && !config.publishedPublicPorts.contains(publicPort) } }
        return err
    }

    func removeRemotePort(_ p: RemotePort) async -> String? {
        config.remotePorts.removeAll { $0.id == p.id }
        return await syncRemoteAccess()
    }

    func setRemotePort(_ p: RemotePort, enabled: Bool) async -> String? {
        if let i = config.remotePorts.firstIndex(where: { $0.id == p.id }) { config.remotePorts[i].enabled = enabled }
        return await syncRemoteAccess()
    }

    /// Opens/closes the public ports on the server and restarts the tunnel with
    /// them. Websites keep their ports; they pause for a few seconds.
    func syncRemoteAccess() async -> String? {
        guard isSetUp else { return "Set up the server first (Server setup tab)." }
        let (r, f) = await RemoteServer.probe(config.server)
        guard let f else { return "Can't reach the server: \(r.message)" }
        facts = f
        // tunnel loopback ports: never one another computer or program uses
        let mine = Set(config.services.map(\.normalizedDomain) + config.remotePorts.map { "tcp-\($0.publicPort)" })
        let foreign = Set(f.reserved.filter { !mine.contains($0.key) }.values.flatMap { $0 })
        var taken = f.usedPorts.union(foreign)
        for s in config.services { taken.insert(s.remotePort); taken.insert(s.remoteSocketPort) }
        for p in config.remotePorts { taken.insert(p.tunnelPort) }
        for i in config.remotePorts.indices where config.remotePorts[i].tunnelPort == 0 || foreign.contains(config.remotePorts[i].tunnelPort) {
            config.remotePorts[i].tunnelPort = RemoteServer.freePort(avoiding: taken)
            taken.insert(config.remotePorts[i].tunnelPort)
        }
        let res = await RemoteServer.run(config.server, RemoteServer.remotePortsScript(config.remotePorts, published: config.publishedPublicPorts), timeout: 90)
        guard res.ok else {
            log("Remote access", "Not changed: \(res.message)", error: true)
            return res.message
        }
        config.publishedPublicPorts = config.remotePorts.filter { $0.enabled && $0.tunnelPort > 0 }.map(\.publicPort)
        connectTunnel()
        log("Remote access", config.publishedPublicPorts.isEmpty ? "No public ports open"
            : "Open on \(publicServerIP): " + config.remotePorts.filter(\.enabled).map { "\($0.publicPort) → this Mac :\($0.localPort)" }.joined(separator: ", "))
        return nil
    }

    /// Is ip:port reachable from here? (This Mac is outside the server's
    /// network, so this is a real "from the internet" test.)
    nonisolated static func reachable(_ host: String, _ port: Int) async -> Bool {
        await Task.detached {
            let t = Process()
            t.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
            t.arguments = ["-z", "-G", "5", host, String(port)]
            t.standardOutput = FileHandle.nullDevice
            t.standardError = FileHandle.nullDevice
            guard (try? t.run()) != nil else { return false }
            t.waitUntilExit()
            return t.terminationStatus == 0
        }.value
    }
}

struct RemoteAccessView: View {
    @EnvironmentObject var model: AppModel
    @State private var name = ""
    @State private var localText = ""
    @State private var publicText = ""
    @State private var message = ""
    @State private var working = false
    @State private var reach: [Int: Bool] = [:]       // public port → reachable
    @State private var testing: Set<Int> = []
    @State private var remoteLogin: Bool?

    private var ip: String { model.publicServerIP }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Reach this Mac from anywhere at your server's fixed IP **\(ip)** — SSH, Screen Sharing or any other port. The address stays the same when this Mac's Wi-Fi or IP changes.")
                .foregroundStyle(.secondary)

            if !model.isSetUp {
                Label("Set up the server first (Server setup tab).", systemImage: "info.circle").foregroundStyle(.secondary)
            } else {
                addresses
                addCard
                if model.config.remotePorts.contains(where: { $0.localPort == 22 }) { AuthorizedKeysCard() }
                firstTime
            }
            if !message.isEmpty {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .onAppear(perform: check)
    }

    // MARK: open ports

    private var addresses: some View {
        Card(title: "Open to the internet", icon: "network") {
            if model.config.remotePorts.isEmpty {
                Text("Nothing yet. Add SSH below to log in to this Mac from anywhere.").foregroundStyle(.secondary)
            }
            ForEach(model.config.remotePorts) { p in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Image(systemName: p.localPort == 22 ? "terminal" : p.localPort == 5900 ? "display" : "point.3.connected.trianglepath.dotted")
                            .foregroundStyle(Color.accentColor).frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name).font(.headline)
                            Text("\(ip):\(String(p.publicPort))  →  this Mac :\(String(p.localPort))")
                                .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        }
                        Spacer(minLength: 8)
                        status(p)
                        Toggle("", isOn: Binding(get: { p.enabled }, set: { on in run { await model.setRemotePort(p, enabled: on) } }))
                            .labelsHidden().toggleStyle(.switch).disabled(working)
                        Button(role: .destructive) { run { await model.removeRemotePort(p) } } label: { Image(systemName: "trash") }
                            .disabled(working)
                    }
                    if p.localPort == 22 && p.enabled {
                        let cmd = "ssh \(NSUserName())@\(ip) -p \(p.publicPort)"
                        HStack {
                            Text(cmd).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(.background, in: RoundedRectangle(cornerRadius: 6))
                            Button("Copy") { model.copy(cmd) }
                        }
                        Text("Run this on any computer, anywhere. User: \(NSUserName()) · password or SSH key of this Mac.")
                            .font(.caption).foregroundStyle(.secondary)
                        let alias = SSHConfigFile.thisComputerAlias
                        let block = SSHConfigFile.block(alias: alias, hostName: ip, user: NSUserName(), port: p.publicPort, identityFile: "")
                        HStack {
                            Button("Copy SSH config") { model.copy(block) }
                            Text("Paste it into the other computer's SSH config, then just: ssh \(alias)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Mac/Linux: ~/.ssh/config · Windows: C:\\Users\\<you>\\.ssh\\config")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else if p.localPort == 5900 && p.enabled {
                        let url = "vnc://\(ip):\(p.publicPort)"
                        HStack {
                            Text(url).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            Button("Copy") { model.copy(url) }
                        }
                        Text("Mac: Finder → Go → Connect to Server, paste this. Other computers: any VNC viewer.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                Divider()
            }
            if working { ProgressView().controlSize(.small) }
        }
    }

    @ViewBuilder private func status(_ p: RemotePort) -> some View {
        if !p.enabled {
            Text("off").font(.caption).foregroundStyle(.secondary)
        } else if testing.contains(p.publicPort) {
            ProgressView().controlSize(.small)
        } else if let ok = reach[p.publicPort] {
            Label(ok ? "Reachable" : "Blocked", systemImage: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.caption.weight(.semibold)).foregroundStyle(ok ? .green : .red)
                .help(ok ? "Works from the internet" : "Not reachable yet: allow the port in the server's firewall (step 2 below)")
        } else {
            Button("Test") { test(p.publicPort) }.controlSize(.small)
        }
    }

    // MARK: add

    private var addCard: some View {
        Card(title: "Add a port", icon: "plus.circle") {
            HStack(spacing: 8) {
                Text("Quick:").font(.caption).foregroundStyle(.secondary)
                Button("SSH (22)") { fill("SSH", 22, 2201) }
                Button("Screen Sharing (5900)") { fill("Screen Sharing", 5900, 5901) }
            }
            HStack(alignment: .bottom, spacing: 10) {
                field("Name", $name, "SSH", 160)
                field("This Mac port", $localText, "22", 110)
                field("Public port", $publicText, "2201", 110)
                Button("Add") {
                    let (n, l, pub) = (name, Int(localText) ?? 0, Int(publicText) ?? 0)
                    run { await model.addRemotePort(name: n, localPort: l, publicPort: pub) } done: {
                        name = ""; localText = ""; publicText = ""
                        test(pub)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(working || Int(localText) == nil || Int(publicText) == nil)
            }
            Text("Public port = the number people add after the IP. Use one above 1024 that nothing else on the server uses.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func field(_ title: String, _ text: Binding<String>, _ hint: String, _ width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(hint, text: text).textFieldStyle(.roundedBorder).frame(width: width)
        }
    }

    private func fill(_ n: String, _ local: Int, _ from: Int) {
        name = n
        localText = String(local)
        publicText = String(model.suggestPublicPort(from: from))
    }

    // MARK: first time

    private var firstTime: some View {
        Card(title: "First time (once per port)", icon: "checklist") {
            let ports = model.config.remotePorts.filter(\.enabled).map { String($0.publicPort) }
            let list = firewallPorts(ports)
            step(1, model.config.remotePorts.contains { $0.localPort == 22 } ? remoteLogin : nil,
                 "Turn on Remote Login on this Mac (for SSH)",
                 "System Settings → General → Sharing → Remote Login. For Screen Sharing turn on Screen Sharing there.") {
                Button("Open Sharing settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension")!)
                }
            }
            let cmd = "gcloud compute firewall-rules create ontutunnel-remote-access --allow=tcp:\(list) --direction=INGRESS"
            step(2, ports.isEmpty ? nil : ports.allSatisfy { reach[Int($0) ?? 0] == true },
                 "Allow the port in the server's firewall",
                 "Once for the server (covers this and other computers): Google Cloud → VPC network → Firewall → Create firewall rule → Targets: All instances, Source IPv4 ranges: 0.0.0.0/0, TCP ports: \(list) → Create. Or run in Cloud Shell:") {
                HStack {
                    Text(cmd).font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(2)
                    Button("Copy") { model.copy(cmd) }
                }
            }
            step(3, nil, "Test from the internet",
                 "Checks every open port from this Mac, which is outside the server's network.") {
                Button("Test now") { for p in model.config.remotePorts where p.enabled { test(p.publicPort) } }
            }
            Label("These ports are open to the whole internet. Use a strong password, or log in with SSH keys only.",
                  systemImage: "lock.shield").font(.caption).foregroundStyle(.orange)
        }
    }

    /// Whole ranges, so other computers on this server need no new rule.
    private func firewallPorts(_ ports: [String]) -> String {
        var ranges = ["2201-2299", "5901-5999"]
        for p in ports where !(2201...2299).contains(Int(p) ?? 0) && !(5901...5999).contains(Int(p) ?? 0) { ranges.append(p) }
        return ranges.joined(separator: ",")
    }

    private func step<C: View>(_ n: Int, _ done: Bool?, _ title: String, _ detail: String, @ViewBuilder _ action: () -> C) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done == true ? "checkmark.circle.fill" : done == false ? "xmark.circle.fill" : "\(n).circle")
                .foregroundStyle(done == true ? .green : done == false ? .red : .secondary).font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                action()
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: helpers

    private func run(_ work: @escaping () async -> String?, done: @escaping () -> Void = {}) {
        working = true
        message = ""
        Task {
            if let err = await work() { message = err } else { done() }
            working = false
        }
    }

    private func test(_ port: Int) {
        testing.insert(port)
        let host = ip
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)   // let the tunnel come back up
            reach[port] = await AppModel.reachable(host, port)
            testing.remove(port)
        }
    }

    private func check() {
        Task { remoteLogin = await AppModel.reachable("127.0.0.1", 22) }
        if model.isSetUp {   // fresh server info: suggested ports skip other computers' ports
            Task { if let f = await RemoteServer.probe(model.config.server).1 { model.facts = f } }
        }
        for p in model.config.remotePorts where p.enabled { test(p.publicPort) }
    }
}
