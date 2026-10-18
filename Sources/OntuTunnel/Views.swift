import AppKit
import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case server = "Connection"
    case domains = "Domains"
    case hosts = "Hosts file"
    case logs = "Logs"
    case settings = "Settings"
    case guide = "Guide"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .server: return "network"
        case .domains: return "globe"
        case .hosts: return "list.bullet.rectangle"
        case .logs: return "text.alignleft"
        case .settings: return "gearshape"
        case .guide: return "book"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var page: Page = .dashboard

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $page) { p in
                Label(p.rawValue, systemImage: p.icon).tag(p)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            .safeAreaInset(edge: .bottom) { TunnelBadge().padding(12) }
        } detail: {
            Group {
                switch page {
                case .dashboard: DashboardView(goToServer: { page = .server })
                case .server: ConnectionView()
                case .domains: DomainsView()
                case .hosts: HostsView()
                case .logs: LogsView()
                case .settings: SettingsView()
                case .guide: GuideView()
                }
            }
            .frame(minWidth: 680, minHeight: 500)
        }
        .tint(.ontu)
        .onAppear {
            model.startIfNeeded()
            if !model.isReady { page = .server }
        }
    }
}

// MARK: - Shared pieces

struct StatusDot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 9, height: 9)
            .overlay(Circle().stroke(color.opacity(0.35), lineWidth: 4))
    }
}

struct Pill: View {
    let text: String
    let color: Color
    var body: some View {
        HStack(spacing: 6) {
            StatusDot(color: color)
            Text(text).font(.caption.weight(.medium)).lineLimit(1)
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(color.opacity(0.12), in: Capsule())
    }
}

extension Check {
    var color: Color {
        switch self {
        case .ok: return .green
        case .warning: return .orange
        case .failed: return .red
        default: return .gray
        }
    }
    var symbol: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.circle.fill"
        case .checking: return "arrow.triangle.2.circlepath"
        case .unknown: return "circle"
        }
    }
    var text: String {
        switch self {
        case .ok: return "OK"
        case .checking: return "Checking…"
        case .unknown: return "Not checked"
        case .warning(let m), .failed(let m): return m
        }
    }
}

struct Card<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct TunnelBadge: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack {
            switch model.config.mode {
            case .relay:
                if !model.isSetUp { Pill(text: "Server not set up", color: .gray) } else { state(model.tunnelState, "Tunnel") }
            case .staticIP:
                switch model.proxyState {
                case .listening: Pill(text: "Static IP · port 80 open" + (model.httpsRunning ? " · HTTPS" : ""), color: .green)
                case .failed: Pill(text: "Port 80 failed", color: .red)
                default: Pill(text: "Static IP · off", color: .gray)
                }
            case .cloudflare:
                if !model.isReady { Pill(text: "Cloudflare not set up", color: .gray) } else { state(model.cfState, "Cloudflare") }
            }
            Spacer()
        }
    }

    @ViewBuilder private func state(_ s: Tunnel.State, _ name: String) -> some View {
        switch s {
        case .connected: Pill(text: "\(name) connected", color: .green)
        case .connecting: Pill(text: "Connecting…", color: .orange)
        case .failed: Pill(text: "\(name) down", color: .red)
        case .stopped: Pill(text: "\(name) off", color: .gray)
        }
    }
}

/// "shop.example.com" → "shop" (what DNS panels ask for).
enum DomainLabel {
    static func of(_ domain: String) -> String {
        let parts = domain.split(separator: ".")
        guard parts.count > 2 else { return "@" }
        let compound = ["co.in", "org.in", "net.in", "gov.in", "ac.in", "co.uk", "com.au"]
        let keep = compound.contains(parts.suffix(2).joined(separator: ".")) ? 3 : 2
        return parts.count > keep ? parts.dropLast(keep).joined(separator: ".") : "@"
    }
}

// MARK: - Service editor

struct ServiceEditor: View {
    @EnvironmentObject var model: AppModel
    @State var service: Service
    let done: () -> Void
    @State private var portText = ""
    @State private var socketText = ""
    @State private var useWildcard = false
    @State private var base = ""
    @State private var subdomain = ""

    var isNew: Bool { model.binding(for: service.id) == nil }
    var fullDomain: String {
        useWildcard
            ? (subdomain.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: " ", with: "-") + "." + base)
            : service.normalizedDomain
    }
    var valid: Bool {
        (useWildcard ? (!subdomain.trimmingCharacters(in: .whitespaces).isEmpty && !subdomain.contains(".") && !base.isEmpty)
                     : service.normalizedDomain.contains("."))
            && (useWildcard || service.isSafe)
            && (service.frappeSite.isEmpty || service.frappeSite.range(of: "^[A-Za-z0-9._-]{1,100}$", options: .regularExpression) != nil)
            && Int(portText).map { (1...65535).contains($0) } == true
            && (socketText.isEmpty || Int(socketText).map { (1...65535).contains($0) } == true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isNew ? "Add Service" : "Edit Service").font(.title2.bold()).padding([.horizontal, .top], 20)
            Form {
                Section("What to publish") {
                    TextField("Name", text: $service.name, prompt: Text("My Shop"))
                    TextField("Local port", text: $portText, prompt: Text("8001"))
                }
                Section {
                    Picker("Domain", selection: $useWildcard) {
                        Text("Under my wildcard domain").tag(true)
                        Text("Custom domain").tag(false)
                    }
                    .pickerStyle(.radioGroup)
                    if useWildcard {
                        if model.config.wildcardBases.isEmpty {
                            Text("No wildcard domain yet — set one up once in the sidebar → Domains (e.g. dev.example.com).")
                                .font(.callout).foregroundStyle(.orange)
                        } else {
                            HStack(spacing: 6) {
                                TextField("Name", text: $subdomain, prompt: Text("shop"))
                                    .frame(minWidth: 140)
                                Text(".").foregroundStyle(.secondary)
                                Picker("", selection: $base) {
                                    ForEach(model.config.wildcardBases, id: \.self) { Text($0).tag($0) }
                                }
                                .labelsHidden()
                            }
                            if !subdomain.isEmpty {
                                let ok = model.wildcardStatus[base]?.isOK == true
                                Label(ok ? "\(fullDomain) — goes live without any DNS step"
                                         : "\(fullDomain) — works as soon as the *.\(base) DNS record is in place",
                                      systemImage: ok ? "checkmark.circle.fill" : "clock")
                                    .font(.callout).foregroundStyle(ok ? .green : .orange)
                            }
                        }
                    } else {
                        TextField("Full domain", text: $service.domain, prompt: Text("shop.example.com"))
                        if model.config.mode != .cloudflare && service.normalizedDomain.contains(".") {
                            Text("You add its DNS record yourself: **A** · name **\(DomainLabel.of(service.normalizedDomain))** · value **\(model.dnsTarget.isEmpty ? "your connection's IP" : model.dnsTarget)**")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Domain")
                }
                Section {
                    TextField("Frappe site", text: $service.frappeSite, prompt: Text("mysite.local"))
                    TextField("Realtime (Socket.IO) port", text: $socketText, prompt: Text("9001 — optional"))
                } header: {
                    Text("Frappe / bench (optional)")
                } footer: {
                    Text("Site name is sent as X-Frappe-Site-Name. A bench with a default site (bench use …) serves only that site on its main port — for another site use a start command like `bench --site SITE serve --port 8011`.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    TextField("Start command", text: $service.startCommand, prompt: Text("bench start"))
                    HStack {
                        TextField("Folder", text: $service.workingDirectory, prompt: Text("/path/to/frappe-bench"))
                        Button("Choose…") { chooseFolder() }
                    }
                    Toggle("Start when OntuTunnel opens", isOn: $service.autoStart)
                    Toggle("Keep alive (restart if it stops)", isOn: $service.keepAlive)
                } header: {
                    Text("Start command (optional)")
                }
            }
            .formStyle(.grouped)
            HStack {
                if model.config.mode == .cloudflare {
                    Text("DNS: created automatically in Cloudflare").font(.caption).foregroundStyle(.secondary)
                } else if !model.dnsTarget.isEmpty {
                    Text("DNS: A record → \(model.dnsTarget)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    service.localPort = Int(portText) ?? service.localPort
                    service.socketPort = Int(socketText) ?? 0
                    service.domain = fullDomain
                    model.save(service)
                    done()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!valid)
            }
            .padding(20)
        }
        .frame(width: 560, height: 640)
        .onAppear {
            portText = String(service.localPort)
            socketText = service.socketPort > 0 ? String(service.socketPort) : ""
            let d = service.normalizedDomain
            if let b = model.config.wildcardBases.first(where: { d.hasSuffix("." + $0) && !d.dropLast($0.count + 1).contains(".") }) {
                useWildcard = true; base = b; subdomain = String(d.dropLast(b.count + 1))
            } else {
                useWildcard = d.isEmpty && !model.config.wildcardBases.isEmpty
                base = model.config.wildcardBases.first ?? ""
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { service.workingDirectory = url.path }
    }
}

// MARK: - Server

struct RelayView: View {
    @EnvironmentObject var model: AppModel
    @State private var portText = "22"
    @State private var confirmRemove = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("A server with a static IP that visitors reach. OntuTunnel logs in with SSH, sets up what is needed — only its own files, nothing you already run is changed — and keeps a tunnel open from this Mac.")
                    .foregroundStyle(.secondary)

                Card(title: "1 · Connect", icon: "key") {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                        GridRow {
                            Text("Server IP / host").foregroundStyle(.secondary)
                            TextField("203.0.113.10", text: $model.config.server.host).textFieldStyle(.roundedBorder)
                        }
                        GridRow {
                            Text("SSH user").foregroundStyle(.secondary)
                            TextField("ubuntu", text: $model.config.server.user).textFieldStyle(.roundedBorder)
                        }
                        GridRow {
                            Text("SSH port").foregroundStyle(.secondary)
                            TextField("22", text: $portText).textFieldStyle(.roundedBorder).frame(width: 90)
                                .onChange(of: portText) { model.config.server.port = Int(portText) ?? 22 }
                        }
                        GridRow {
                            Text("SSH key").foregroundStyle(.secondary)
                            Text(model.config.server.keyPath).font(.system(.body, design: .monospaced))
                                .lineLimit(1).truncationMode(.middle)
                        }
                        GridRow {
                            Text("Email (optional)").foregroundStyle(.secondary)
                            TextField("for SSL expiry notices", text: $model.config.server.email).textFieldStyle(.roundedBorder)
                        }
                    }
                    HStack {
                        Button("Test connection") { Task { await model.testConnection() } }
                            .disabled(!model.config.server.isComplete || model.busy)
                        checkLabel(model.connection)
                    }
                }

                SSHKeyCard()

                if let f = model.facts {
                    Card(title: "What's on the server", icon: "magnifyingglass") {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                            row("System", "\(f.os) · \(f.arch)")
                            row("Admin (sudo)", f.sudo ? "yes" : "no — needed")
                            row("Port 80", f.port80.isEmpty ? "free" : "used by \(f.port80)")
                            row("Port 443", f.port443.isEmpty ? "free" : "used by \(f.port443)")
                            row("nginx", f.nginx ? "installed" : "not installed")
                            row("OntuTunnel Caddy", f.ourCaddy ? "running" : "not installed")
                            row("Ports in use", f.usedPorts.sorted().map(String.init).joined(separator: ", "))
                        }
                        switch f.plan {
                        case .use(.caddy):
                            Label("Plan: run OntuTunnel's own Caddy on 80/443 (automatic HTTPS). Nothing else on the server is changed.", systemImage: "checkmark.seal").foregroundStyle(.green)
                        case .use(.nginx):
                            Label("Plan: keep your nginx as it is and only add new files /etc/nginx/conf.d/ontutunnel-<domain>.conf. Config is tested before reload; HTTPS with certbot.", systemImage: "checkmark.seal").foregroundStyle(.green)
                        case .blocked(let why):
                            Label(why, systemImage: "xmark.octagon").foregroundStyle(.red)
                        }
                    }
                }

                Card(title: "2 · Set up server", icon: "wand.and.stars") {
                    Text("Checks the server, installs what is missing, publishes your services and starts the tunnel. Safe to run again any time.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button(model.isSetUp ? "Run setup again" : "Set up server") { Task { await model.setupServer() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.config.server.isComplete || model.busy)
                        if model.busy { ProgressView().controlSize(.small) }
                    }
                    ForEach(model.steps) { s in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: s.state.symbol).foregroundStyle(s.state.color).frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.title).fontWeight(.medium)
                                let detail = s.detail.isEmpty ? (s.state == .ok || s.state == .unknown || s.state == .checking ? "" : s.state.text) : s.detail
                                if !detail.isEmpty {
                                    Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                        }
                    }
                }

                if model.isSetUp {
                    Card(title: "3 · Tunnel", icon: "point.3.connected.trianglepath.dotted") {
                        HStack {
                            TunnelBadge()
                            Toggle("Connect when OntuTunnel opens", isOn: $model.config.autoConnect)
                        }
                        if case .failed(let why) = model.tunnelState {
                            Text(why).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        }
                        HStack {
                            if model.tunnelUp { Button("Disconnect") { model.disconnectTunnel() } }
                            else { Button("Connect") { model.connectTunnel() }.buttonStyle(.borderedProminent) }
                            Button("Sync now") { Task { await model.sync() } }.disabled(model.busy)
                            Spacer()
                            Button("Remove OntuTunnel from server", role: .destructive) { confirmRemove = true }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .onAppear { portText = String(model.config.server.port) }
        .confirmationDialog("Remove OntuTunnel from \(model.config.server.host)?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { Task { await model.removeFromServer() } }
        } message: {
            Text("Stops the tunnel and deletes only what OntuTunnel added (its Caddy service or its nginx files). Your other sites are not touched.")
        }
    }

    @ViewBuilder private func checkLabel(_ c: Check) -> some View {
        switch c {
        case .unknown: EmptyView()
        case .checking: ProgressView().controlSize(.small)
        default:
            Label(c.isOK ? "Connected" : c.text, systemImage: c.symbol).foregroundStyle(c.color).font(.callout)
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).textSelection(.enabled)
        }
    }
}

// MARK: - Logs

struct LogsView: View {
    @EnvironmentObject var model: AppModel
    @State private var filter = "All"

    var sources: [String] { ["All"] + Array(Set(model.logs.map(\.source))).sorted() }
    var shown: [LogLine] { filter == "All" ? model.logs : model.logs.filter { $0.source == filter } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Logs").font(.largeTitle.bold())
                Spacer()
                Picker("Source", selection: $filter) { ForEach(sources, id: \.self) { Text($0) } }.frame(width: 220)
                Button("Open log file") { NSWorkspace.shared.open(AppModel.logFile) }
                Button("Clear") { model.logs.removeAll() }
            }
            ScrollViewReader { proxy in
                List(shown) { line in
                    HStack(alignment: .top, spacing: 8) {
                        Text(line.date.formatted(date: .omitted, time: .standard)).foregroundStyle(.secondary)
                        Text(line.source).foregroundStyle(.blue).frame(width: 110, alignment: .leading).lineLimit(1)
                        Text(line.text).foregroundStyle(line.isError ? Color.red : Color.primary).textSelection(.enabled)
                    }
                    .font(.system(.caption, design: .monospaced))
                    .id(line.id)
                }
                .onChange(of: model.logs.count) {
                    if let last = shown.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .padding(24)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: Binding(
                    get: { model.config.appearance }, set: { model.config.appearance = $0; model.applyAppearance() })) {
                    Text("Same as Mac").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
            }
            Section("Start-up") {
                Toggle("Open OntuTunnel when I log in", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                Toggle("Connect the tunnel when OntuTunnel opens", isOn: $model.config.autoConnect)
                Toggle("Keep this Mac awake while OntuTunnel is running", isOn: Binding(
                    get: { model.config.keepAwake }, set: { model.config.keepAwake = $0; model.applyKeepAwake() }))
                Text("Your sites stay online when you leave the Mac. The screen can still turn off. Closing the lid still sleeps the Mac, unless it's plugged in with an external display.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("My static IP: open my sites from this Mac too", isOn: Binding(
                    get: { !model.config.localHostsOff },
                    set: { model.config.localHostsOff = !$0; model.hostsDeclined = ""; Task { await model.syncHosts() } }))
                Text("Adds your sites to /etc/hosts (127.0.0.1), because many routers can't reach their own public IP from inside. Asks for your password when the list changes.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Per service, \"Start when OntuTunnel opens\" and \"Keep alive\" are in its Edit screen.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Browser dashboard", isOn: Binding(get: { model.config.web.enabled }, set: { model.config.web.enabled = $0; model.startWebDashboard() }))
                Toggle("Allow other devices on my Wi-Fi (phone, laptop) — needs the access key", isOn: Binding(
                    get: { model.config.web.allowLAN }, set: { model.config.web.allowLAN = $0; model.startWebDashboard() }))
                    .disabled(!model.config.web.enabled)
                HStack {
                    Text(model.webURL).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Spacer()
                    Button("Open") { NSWorkspace.shared.open(URL(string: model.webURL)!) }
                    Button("Copy") { model.copy(model.webURL) }
                }
                .disabled(!model.config.web.enabled)
                switch model.webState {
                case .listening(let p): Pill(text: "Running on port \(String(p))", color: .green)
                case .failed(let m): Pill(text: "Failed: \(m)", color: .red)
                case .stopped: Pill(text: "Off", color: .gray)
                }
            } header: {
                Text("Browser dashboard")
            } footer: {
                Text(model.config.web.allowLAN
                     ? "Anyone on your Wi-Fi who has this exact link (with the key) can control OntuTunnel. Don't share it."
                     : "Only this Mac can open it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Data") {
                LabeledContent("Config file", value: ConfigFile.url.path)
                LabeledContent("Log file", value: AppModel.logFile.path)
                Button("Show config in Finder") { NSWorkspace.shared.activateFileViewerSelecting([ConfigFile.url]) }
            }
        }
        .formStyle(.grouped)
        .padding(12)
    }
}

// MARK: - Guide

struct GuideView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Guide").font(.largeTitle.bold())
                Text("Pick ONE way to connect (Connection page). All three give you your own domain with HTTPS; they differ in what you need.")
                    .foregroundStyle(.secondary)

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow { Text("").bold(); Text("You need").bold(); Text("Cost").bold(); Text("DNS").bold() }
                    GridRow { Text("My server (SSH)"); Text("A VPS / cloud VM with static IP"); Text("Server bill"); Text("A record → server IP") }
                    GridRow { Text("My static IP"); Text("Static IP from your ISP + router port forwarding"); Text("ISP add-on"); Text("A record → your static IP") }
                    GridRow { Text("Cloudflare Tunnel"); Text("Free Cloudflare account, domain on Cloudflare"); Text("Free"); Text("Automatic") }
                }
                .font(.callout)
                .padding(16)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))

                section("Every way: start", "play.circle") {
                    Text("1. Run your app on this Mac (e.g. `bench start` → localhost:8001). Dashboard → **Running on this Mac** lists open ports; click **Publish** next to one to add it as a service.")
                    Text("2. Frappe: a bench with a default site serves only that site on its main port — for another site give the service the start command `bench --site SITE serve --port 8011`.")
                        .foregroundStyle(.secondary)
                }

                section("A · My server (SSH)", "server.rack") {
                    Text("Visitor → domain → **server's static IP** → nginx/Caddy (HTTPS) → SSH tunnel → this Mac.")
                    Text("1. Server: Linux VM with static IP. Google Cloud: VM running · VPC network → IP addresses → **Promote to static** · VM → Edit → **Allow HTTP / HTTPS traffic**.")
                    Text("2. Connection → My server: IP, SSH user, key → **Test connection** (if refused, copy the shown public key to the server: GCP VM → Edit → SSH Keys).")
                    Text("3. **Set up server**. If nginx already runs there, only new files `ontutunnel-<domain>.conf` are added; otherwise OntuTunnel runs its own Caddy. Random free ports, nothing existing is changed.")
                    Text("4. DNS: **A** record name = subdomain, value = **\(model.serverIP.isEmpty ? "server IP" : model.serverIP)**. Then **Sync now** → HTTPS is issued.")
                    Text("Undo: Connection → **Remove OntuTunnel from server**.").foregroundStyle(.secondary)
                }

                section("B · My static IP (no server)", "wifi.router") {
                    Text("Visitor → domain → **your static IP** → your router → this Mac (OntuTunnel on ports 80/443 with its own HTTPS).")
                    Text("1. Get a **static public IPv4** from your ISP (Jio: JioFiber static IP add-on / business plan). A normal home IP is shared (CGNAT) and won't work.")
                    Text("2. Router: give this Mac a fixed LAN IP (\(model.network.localIPv4.isEmpty ? "e.g. 192.168.1.x" : model.network.localIPv4)) and add **Port Forwarding**: TCP **80** and **443** → that IP, same ports. JioFiber: SECURITY → Firewall → **Port Forwarding** tab → + Add new.")
                    Text("3. Connection → **My static IP**: enter the static IP (or leave empty to use the detected public IP) → **Start**. Keep HTTPS on.")
                    Text("4. DNS: **A** record name = subdomain, value = your static IP. HTTPS is issued automatically once the domain reaches this Mac.")
                    Text("Test from your phone on mobile data — many routers can't open your own public IP from inside the home network.").foregroundStyle(.secondary)
                }

                section("C · Cloudflare Tunnel (free, nothing else needed)", "cloud") {
                    Text("Visitor → Cloudflare (HTTPS) → tunnel that this Mac opens → this Mac.")
                    Text("1. Free account at **dash.cloudflare.com** → **Add a domain** → follow the steps, then at your registrar (e.g. Hostinger → DNS / Nameservers) change the nameservers to the two Cloudflare shows. Cloudflare copies your existing records; wait until it says *Active*.")
                    Text("2. Connection → **Cloudflare Tunnel** → **Set up**. OntuTunnel installs `cloudflared`, opens Cloudflare in the browser once (choose the domain → **Authorize**), creates the tunnel and starts it.")
                    Text("3. Add services: DNS records are created **automatically** and HTTPS comes from Cloudflare — nothing to type in DNS.")
                    Text("Works on any network, no router change, no static IP.").foregroundStyle(.secondary)
                }

                section("Wildcard domain — set DNS once", "globe") {
                    Text("1. Sidebar → **Domains** → add a base, e.g. `dev.example.com`.")
                    Text("2. At your DNS provider add ONE record: **A** · name **`*.dev`** · value = your connection's IP (server IP or static IP). Hostinger: DNS / Nameservers → Type A, Name `*.dev`.")
                    Text("3. The card turns green (**Ready**). From now on, Add Service → **Under my wildcard domain** → type just `shop` → `shop.dev.example.com` is live with HTTPS, no DNS step.")
                    Text("**Custom domain** is always available too: type any full domain and add its own A record yourself.")
                    Text("Cloudflare mode creates every record automatically, so a wildcard isn't needed there.").foregroundStyle(.secondary)
                }

                section("Keep it running", "bolt.circle") {
                    Text("Settings → **Open OntuTunnel when I log in** and **Connect when OntuTunnel opens**. Keep the Mac awake and your app running (or give the service a start command with Keep alive).")
                }
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
        }
    }

    private func section<Content: View>(_ title: String, _ icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.headline)
            VStack(alignment: .leading, spacing: 6) { content() }.textSelection(.enabled)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Connection (choose mode)

struct ConnectionView: View {
    @EnvironmentObject var model: AppModel
    @State private var selected: ConnectionMode?
    @State private var confirmSwitch = false

    private var shown: ConnectionMode { selected ?? model.config.mode }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Connection").font(.largeTitle.bold())
                Text("How should visitors reach this Mac?").foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    ForEach(ConnectionMode.allCases) { m in
                        Button { selected = m } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Label(m.title, systemImage: m.icon).font(.headline)
                                    Spacer()
                                    if model.config.mode == m { Pill(text: "Active", color: .green) }
                                }
                                Text(m.subtitle).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
                            .background(shown == m ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(shown == m ? Color.accentColor : .clear, lineWidth: 1.5))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding([.horizontal, .top], 24)
            .padding(.bottom, 8)
            if shown != model.config.mode {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle").foregroundStyle(.orange)
                    Text("You're looking at **\(shown.title)**. Your sites currently use **\(model.config.mode.title)** — nothing changes until you switch.")
                    Spacer()
                    Button("Use this connection") { confirmSwitch = true }.buttonStyle(.borderedProminent)
                }
                .font(.callout)
                .padding(12)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 24).padding(.bottom, 8)
            }
            Divider()
            Group {
                switch shown {
                case .relay: RelayView()
                case .staticIP: StaticIPView()
                case .cloudflare: CloudflareView()
                }
            }
            .disabled(shown != model.config.mode)
        }
        .confirmationDialog("Switch to \(shown.title)?", isPresented: $confirmSwitch) {
            Button("Switch") { model.setMode(shown); selected = nil }
        } message: {
            Text("\(model.config.mode.title) will be stopped. Your sites are offline until their DNS points to the new connection (and, for Cloudflare, until setup is done).")
        }
    }
}

struct StaticIPView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("No server: this Mac serves your sites itself on ports 80 and 443, with its own free HTTPS certificate. Needs a static public IP from your internet provider and port forwarding on the router.")
                    .foregroundStyle(.secondary)
                Card(title: "1 · Your static IP", icon: "wifi.router") {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                        GridRow {
                            Text("Static public IP").foregroundStyle(.secondary)
                            TextField(model.network.publicIPv4.isEmpty ? "e.g. 49.36.x.x" : "empty = detected \(model.network.publicIPv4)",
                                      text: $model.config.staticIP.ip).textFieldStyle(.roundedBorder)
                        }
                        GridRow {
                            Text("This Mac on Wi-Fi").foregroundStyle(.secondary)
                            Text(model.network.localIPv4.isEmpty ? "—" : model.network.localIPv4).font(.system(.body, design: .monospaced))
                        }
                        GridRow {
                            Text("Email (optional)").foregroundStyle(.secondary)
                            TextField("for SSL expiry notices", text: $model.config.staticIP.email).textFieldStyle(.roundedBorder)
                        }
                    }
                    Text("Router: forward TCP **80** and **443** to **\(model.network.localIPv4.isEmpty ? "this Mac" : model.network.localIPv4)** (JioFiber: SECURITY → Firewall → Port Forwarding). Give this Mac a fixed LAN IP so the rule keeps working.")
                        .font(.callout)
                    Text("A normal home connection shares its IPv4 with other customers (CGNAT) — then this mode can't work; use My server or Cloudflare instead.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Card(title: "2 · Serve", icon: "play.circle") {
                    TunnelBadge()
                    Toggle("HTTPS (free Let's Encrypt certificate)", isOn: $model.config.staticIP.httpsEnabled)
                    Toggle("Send http:// visitors to https://", isOn: $model.config.staticIP.redirectToHTTPS)
                    HStack {
                        if model.isConnected { Button("Stop") { model.stopAllModes() } }
                        else { Button("Start") { model.startMode() }.buttonStyle(.borderedProminent) }
                        Button("Get / renew certificate") { Task { await model.ensureStaticCertificate(force: true) } }
                            .disabled(model.certBusy || !model.isConnected)
                        if model.certBusy { ProgressView().controlSize(.small) }
                    }
                    if case .failed(let m) = model.proxyState { Text(m).font(.caption).foregroundStyle(.red) }
                    if let c = model.certificate {
                        Text("Certificate: \(c.names.joined(separator: ", ")) · valid until \(c.notAfter.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !model.certMessage.isEmpty { Text(model.certMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                }
                Card(title: "3 · DNS", icon: "globe") {
                    Text("For every service add an **A** record at your DNS provider: name = subdomain, value = **\(model.staticTargetIP.isEmpty ? "your static IP" : model.staticTargetIP)**.")
                    if !model.staticTargetIP.isEmpty {
                        Button("Copy IP") { model.copy(model.staticTargetIP) }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
        }
    }
}

struct CloudflareView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Free, and nothing else needed: no server, no static IP, no router change. Your domain must use Cloudflare's nameservers (free account). OntuTunnel installs Cloudflare's `cloudflared`, you log in once in the browser, and DNS + HTTPS are automatic after that.")
                    .foregroundStyle(.secondary)
                Card(title: "Before you start (once)", icon: "checklist") {
                    Text("1. Sign up free at dash.cloudflare.com → **Add a domain** (e.g. example.com).")
                    Text("2. At your registrar (Hostinger → DNS / Nameservers) set the two **Cloudflare nameservers** it shows. Cloudflare copies your existing records. Wait until the domain is *Active*.")
                    Button("Open Cloudflare dashboard") { NSWorkspace.shared.open(URL(string: "https://dash.cloudflare.com")!) }
                }
                .font(.callout)
                Card(title: "Set up", icon: "wand.and.stars") {
                    HStack {
                        Button(model.isReady ? "Run setup again" : "Set up Cloudflare Tunnel") { Task { await model.setupCloudflare() } }
                            .buttonStyle(.borderedProminent).disabled(model.busy)
                        if model.busy { ProgressView().controlSize(.small) }
                        Spacer()
                        TunnelBadge().frame(maxWidth: 260)
                    }
                    ForEach(model.cfSteps) { s in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: s.state.symbol).foregroundStyle(s.state.color).frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.title).fontWeight(.medium)
                                let detail = s.detail.isEmpty ? (s.state == .ok || s.state == .unknown || s.state == .checking ? "" : s.state.text) : s.detail
                                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                            }
                        }
                    }
                    if model.isReady {
                        HStack {
                            if model.isConnected { Button("Stop") { model.stopAllModes() } }
                            else { Button("Start") { model.startMode() } }
                            Button("Sync now") { Task { await model.syncCurrentMode() } }.disabled(model.busy)
                        }
                        Text("Tunnel: \(model.config.cloudflare.tunnelName) · routed: \(model.config.cloudflare.routed.isEmpty ? "none yet" : model.config.cloudflare.routed.joined(separator: ", "))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
        }
    }
}

// MARK: - Dashboard extras

struct AddressCard: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Card(title: "This Mac's addresses", icon: "globe") {
            let n = model.network
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                row("Public IPv4", n.publicIPv4)
                row("Wi-Fi (LAN)", n.localIPv4)
                row("IPv6", n.ipv6)
                row("Router", n.router)
            }
            if let at = n.checkedAt {
                Text("Checked \(at.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 380)
    }

    @ViewBuilder private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).font(.callout)
            Text(value.isEmpty ? "—" : value).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            if !value.isEmpty {
                Button { model.copy(value) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless)
            }
        }
    }
}

struct DomainsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Domains").font(.largeTitle.bold())
                Text("One-time setup. Add a wildcard base like dev.example.com and one DNS record *.dev → your connection's IP. After that, any service you name under it (shop.dev.example.com, shop.dev.example.com…) goes live without touching DNS. Custom domains still work as before.")
                    .foregroundStyle(.secondary)
                WildcardCard()
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
        }
    }
}

struct WildcardCard: View {
    @EnvironmentObject var model: AppModel
    @State private var newBase = ""

    var body: some View {
        Card(title: "Wildcard domains", icon: "globe.badge.chevron.backward") {
            ForEach(model.config.wildcardBases, id: \.self) { b in
                let st = model.wildcardStatus[b] ?? .unknown
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("*.\(b)").font(.system(.body, design: .monospaced)).fontWeight(.medium)
                        Pill(text: st.isOK ? "Ready — new names go live instantly" : st == .checking ? "Checking…" : st.text, color: st.color)
                        Spacer()
                        Button("Check") { Task { await model.checkWildcard(b) } }
                        Button(role: .destructive) { model.removeWildcard(b) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                    if !st.isOK && model.config.mode != .cloudflare {
                        HStack(spacing: 6) {
                            Text("Add once at your DNS provider: **A** · name **\(AppModel.wildcardRecordName(b))** · value **\(model.dnsTarget.isEmpty ? "your connection's IP" : model.dnsTarget)** · TTL 300")
                            if !model.dnsTarget.isEmpty {
                                Button { model.copy(model.dnsTarget) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless)
                            }
                        }
                        .font(.callout)
                    }
                }
                .padding(10)
                .background(.background, in: RoundedRectangle(cornerRadius: 10))
            }
            HStack {
                TextField("Add wildcard base, e.g. dev.example.com", text: $newBase)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { add() }
                Button("Add", action: add).disabled(!newBase.contains("."))
            }
        }
    }

    private func add() {
        model.addWildcard(newBase)
        newBase = ""
    }
}

struct LocalPortsCard: View {
    @EnvironmentObject var model: AppModel
    let publish: (ListeningPort) -> Void
    @State private var showHidden = false

    var body: some View {
        let hidden = Set(model.config.hiddenPorts)
        let visible = model.localPorts.filter { !hidden.contains($0.port) }
        let hiddenList = model.localPorts.filter { hidden.contains($0.port) }
        Card(title: "Running on this Mac · \(visible.count)", icon: "cpu") {
            if model.localPorts.isEmpty {
                Text("No app is listening on a port right now. Start your app (e.g. bench start), then Refresh.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if visible.isEmpty {
                Text("All running ports are hidden.").font(.callout).foregroundStyle(.secondary)
            } else {
                grid(visible, hidden: false)
            }

            if !hiddenList.isEmpty {
                DisclosureGroup(isExpanded: $showHidden) {
                    grid(hiddenList, hidden: true).padding(.top, 6)
                } label: {
                    Text("Hidden (\(hiddenList.count)) — \(hiddenList.map { "\($0.process) :\(String($0.port))" }.joined(separator: ", "))")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    private func grid(_ ports: [ListeningPort], hidden: Bool) -> some View {
        let published = Set(model.config.services.map(\.localPort))
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 8)], spacing: 8) {
            ForEach(ports) { p in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(":\(String(p.port))").font(.system(.callout, design: .monospaced).weight(.semibold))
                        Text(p.process).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if hidden {
                        Button("Unhide") { setHidden(p.port, false) }.fixedSize()
                    } else {
                        if published.contains(p.port) {
                            Pill(text: "Live", color: .green).fixedSize()
                        } else {
                            Button("Publish") { publish(p) }.fixedSize()
                        }
                        Button { setHidden(p.port, true) } label: { Image(systemName: "eye.slash") }
                            .buttonStyle(.borderless)
                            .help("Hide this port (e.g. database or cache). Find it again under Hidden.")
                    }
                }
                .controlSize(.small)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .opacity(hidden ? 0.7 : 1)
            }
        }
    }

    private func setHidden(_ port: Int, _ on: Bool) {
        if on {
            if !model.config.hiddenPorts.contains(port) { model.config.hiddenPorts.append(port) }
        } else {
            model.config.hiddenPorts.removeAll { $0 == port }
        }
    }
}

// MARK: - Menu bar

struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.isSetUp ? "Server: \(model.config.server.host)" : "Server not set up")
        Text(model.tunnelUp ? "🟢 Tunnel connected" : "⚪️ Tunnel not connected")
        Divider()
        ForEach(model.config.services) { service in
            let st = model.status(of: service)
            let mark = !service.enabled ? "○" : st.live.isOK ? "🟢" : st.port == .closed ? "🔴" : "🟠"
            Menu("\(mark) \(service.name.isEmpty ? service.normalizedDomain : service.name)") {
                Text("\(service.normalizedDomain) → localhost:\(String(service.localPort))")
                Text("Local: \(st.port == .open ? "running" : "not running") · \(st.live.isOK ? "live" : st.live.text)")
                if let url = model.publicURL(service) { Button("Open site") { NSWorkspace.shared.open(url) } }
                if service.hasCommand {
                    if model.isCommandRunning(service) { Button("Stop command") { model.stopCommand(service) } }
                    else { Button("Start command") { model.startCommand(service) } }
                }
            }
        }
        Divider()
        if model.isSetUp {
            if model.tunnelUp { Button("Disconnect tunnel") { model.disconnectTunnel() } }
            else { Button("Connect tunnel") { model.connectTunnel() } }
        }
        if model.config.web.enabled {
            Button("Open browser dashboard") { NSWorkspace.shared.open(URL(string: model.webURL)!) }
        }
        Button("Open OntuTunnel") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("Quit OntuTunnel") {
            model.shutdown()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
        }
        .keyboardShortcut("q")
    }
}

// MARK: - SSH key: pick one this Mac has, or create one, and add it to the server

struct SSHKeyCard: View {
    @EnvironmentObject var model: AppModel
    @State private var newUser = ""
    @State private var createError = ""
    @State private var target = 0   // 0 Google Cloud, 1 other server

    var body: some View {
        let keys = model.sshKeyInfos
        let selected = keys.first { $0.path == model.config.server.keyPath }
        Card(title: "SSH key — how OntuTunnel logs in to the server", icon: "key.horizontal") {
            if keys.isEmpty {
                Label("This Mac has no SSH key yet. Create one below.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            } else {
                Text("Keys on this Mac").font(.subheadline.weight(.semibold))
                VStack(spacing: 0) {
                    ForEach(keys) { k in
                        let isOn = k.path == model.config.server.keyPath
                        HStack(spacing: 10) {
                            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isOn ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(k.name).font(.system(.body, design: .monospaced)).lineLimit(1)
                                Text([k.type, k.cloudUser.isEmpty ? "" : "user: \(k.cloudUser)"]
                                    .filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Button("Copy") { model.copy(k.publicKey) }.fixedSize()
                            if !isOn {
                                Button("Use this") {
                                    model.config.server.keyPath = k.path
                                    if !k.cloudUser.isEmpty && model.config.server.user.isEmpty { model.config.server.user = k.cloudUser }
                                }
                                .fixedSize()
                            }
                        }
                        .padding(.vertical, 7).padding(.horizontal, 10)
                        .background(isOn ? Color.accentColor.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }

            Divider()
            Text("Create a new key").font(.subheadline.weight(.semibold))
            Text("Type the user name you want on the server. Google Cloud creates this user by itself when you add the key.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("user name, e.g. \(NSUserName().lowercased())", text: $newUser)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                    .onSubmit(create)
                Button("Create key", action: create)
                    .disabled(newUser.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !createError.isEmpty { Text(createError).font(.caption).foregroundStyle(.red) }

            if let k = selected {
                Divider()
                Text("Add this key to your server").font(.subheadline.weight(.semibold))
                Text(k.publicKey).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .lineLimit(3).truncationMode(.middle)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background, in: RoundedRectangle(cornerRadius: 6))
                HStack {
                    Button("Copy public key") { model.copy(k.publicKey) }.buttonStyle(.borderedProminent)
                    if !k.cloudUser.isEmpty && model.config.server.user != k.cloudUser {
                        Button("Set SSH user to \(k.cloudUser)") { model.config.server.user = k.cloudUser }
                    }
                }
                Picker("", selection: $target) {
                    Text("Google Cloud").tag(0)
                    Text("Other server").tag(1)
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 320)
                if target == 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        step(1, "Open console.cloud.google.com → Compute Engine → VM instances.")
                        step(2, "Click your VM → Edit.")
                        step(3, "Security and access → SSH Keys → Add item.")
                        step(4, "Paste the key (Copy public key above) → Save at the bottom.")
                        step(5, "SSH user here = \(k.cloudUser.isEmpty ? "the name at the end of the key" : k.cloudUser). Then click Test connection.")
                    }
                } else {
                    let host = model.config.server.host.isEmpty ? "SERVER-IP" : model.config.server.host
                    let user = model.config.server.user.isEmpty ? "USER" : model.config.server.user
                    let cmd = "ssh-copy-id -i \(k.path).pub \(user)@\(host)"
                    Text("If you can log in to the server with a password, run this once in Terminal:")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text(cmd).font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(1)
                        Button("Copy") { model.copy(cmd) }.fixedSize()
                    }
                    Text("Or paste the key as a new line into ~/.ssh/authorized_keys of that user on the server.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(n).").font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 16, alignment: .trailing)
            Text(text).font(.callout)
        }
    }

    private func create() {
        createError = model.createKey(user: newUser) ?? ""
        if createError.isEmpty { newUser = "" }
    }
}

// MARK: - Hosts file page

struct HostsView: View {
    @EnvironmentObject var model: AppModel
    @State private var entries: [HostsFile.Entry] = []
    @State private var newIP = "127.0.0.1"
    @State private var newNames = ""
    @State private var editing: HostsFile.Entry?
    @State private var editIP = ""
    @State private var editNames = ""
    @State private var message = ""
    @State private var saving = false
    @State private var confirmDelete: HostsFile.Entry?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Hosts file").font(.largeTitle.bold())
                    Text("Which IP a name opens on this Mac only. Saving asks for your password once.")
                        .foregroundStyle(.secondary)
                }
                Card(title: "Add an entry", icon: "plus.circle") {
                    HStack(alignment: .bottom, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("IP").font(.caption).foregroundStyle(.secondary)
                            TextField("127.0.0.1", text: $newIP).textFieldStyle(.roundedBorder).frame(width: 170)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Domain(s)").font(.caption).foregroundStyle(.secondary)
                            TextField("meet.example.com", text: $newNames).textFieldStyle(.roundedBorder)
                        }
                        Button("Add") { save(.add, ip: newIP, names: newNames) { newNames = "" } }
                            .buttonStyle(.borderedProminent)
                            .disabled(saving || newNames.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    HStack(spacing: 8) {
                        Text("Quick:").font(.caption).foregroundStyle(.secondary)
                        Button("This Mac (127.0.0.1)") { newIP = "127.0.0.1" }.controlSize(.small)
                        if !model.network.localIPv4.isEmpty {
                            Button("This Mac on Wi-Fi (\(model.network.localIPv4))") { newIP = model.network.localIPv4 }.controlSize(.small)
                        }
                    }
                }
                if !message.isEmpty {
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
                Card(title: "Entries", icon: "list.bullet") {
                    if entries.isEmpty {
                        Text("No entries.").foregroundStyle(.secondary)
                    }
                    ForEach(entries) { e in
                        HStack(spacing: 10) {
                            if editing == e {
                                TextField("IP", text: $editIP).textFieldStyle(.roundedBorder).frame(width: 150)
                                TextField("Domain(s)", text: $editNames).textFieldStyle(.roundedBorder)
                                Button("Save") { save(.update(e), ip: editIP, names: editNames) { editing = nil } }
                                    .buttonStyle(.borderedProminent).disabled(saving)
                                Button("Cancel") { editing = nil }
                            } else {
                                Text(e.ip).font(.system(.body, design: .monospaced)).frame(width: 150, alignment: .leading)
                                Text(e.names).font(.system(.body, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 8)
                                tag(e.source)
                                if e.source == .you {
                                    Button("Edit") { editing = e; editIP = e.ip; editNames = e.names }.disabled(saving)
                                    Button(role: .destructive) { confirmDelete = e } label: { Image(systemName: "trash") }
                                        .disabled(saving)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                        Divider()
                    }
                }
                Text("File: /etc/hosts. In My static IP mode OntuTunnel keeps its own entries up to date by itself (Settings to turn off).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .onAppear(perform: reload)
        .onChange(of: model.hostsVersion) { reload() }
        .confirmationDialog("Delete \(confirmDelete?.names ?? "")?", isPresented: Binding(
            get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let e = confirmDelete { save(.delete(e)) {} }
            }
        }
    }

    private func tag(_ s: HostsFile.Entry.Source) -> some View {
        let (text, color): (String, Color) = switch s {
        case .you: ("yours", .blue)
        case .ontutunnel: ("OntuTunnel", .green)
        case .system: ("system", .secondary)
        }
        return Text(text).font(.caption.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule()).foregroundStyle(color)
    }

    private func reload() { entries = HostsFile.entries() }

    private func save(_ edit: HostsFile.Edit, ip: String = "", names: String = "", done: @escaping () -> Void) {
        saving = true
        message = ""
        Task {
            if let err = await model.editHosts(edit, ip: ip, names: names) { message = err } else { done() }
            saving = false
            reload()
        }
    }
}
