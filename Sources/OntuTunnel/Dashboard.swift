import AppKit
import SwiftUI

/// Ontu brand blue.
extension Color {
    static let ontu = Color(red: 0.243, green: 0.545, blue: 1.0)
}

enum ServiceFilter: String, CaseIterable, Identifiable {
    case all = "All", live = "Live", attention = "Needs attention", offline = "Offline"
    var id: String { rawValue }
}

@MainActor
extension AppModel {
    func needsAttention(_ s: Service) -> Bool {
        guard s.enabled else { return false }
        let st = status(of: s)
        return st.port == .closed || !st.live.isOK || !st.dns.isOK
    }
}

// MARK: - Dashboard

struct DashboardView: View {
    @EnvironmentObject var model: AppModel
    let goToServer: () -> Void
    @State private var editing: Service?
    @State private var selection: Service.ID? = Demo.preselect
    @State private var search = ""
    @State private var filter: ServiceFilter = .all

    private var filtered: [Service] {
        model.config.services.filter { s in
            let q = search.trimmingCharacters(in: .whitespaces).lowercased()
            let matches = q.isEmpty || s.name.lowercased().contains(q) || s.normalizedDomain.contains(q) || String(s.localPort).contains(q)
            let st = model.status(of: s)
            switch filter {
            case .all: return matches
            case .live: return matches && s.enabled && st.live.isOK
            case .attention: return matches && model.needsAttention(s)
            case .offline: return matches && !s.enabled
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                StatsRow(goToServer: goToServer)
                servicesPanel
                LocalPortsCard { port in editing = model.suggestedService(for: port) }
            }
            .padding(20)
        }
        .inspector(isPresented: Binding(get: { selection != nil }, set: { if !$0 { selection = nil } })) {
            if let id = selection, let s = model.binding(for: id) {
                ServiceInspector(service: s, onEdit: { editing = s }, onClose: { selection = nil })
                    .inspectorColumnWidth(min: 300, ideal: 340, max: 420)
            }
        }
        .sheet(item: $editing) { service in
            ServiceEditor(service: service) { editing = nil }
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                titleBlock
                Spacer(minLength: 12)
                headerControls
            }
            VStack(alignment: .leading, spacing: 10) {
                titleBlock
                headerControls
            }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Dashboard").font(.system(size: 26, weight: .bold)).lineLimit(1)
            Text("OntuTunnel · \(model.config.mode.title)")
                .font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
        }
        .fixedSize()
    }

    private var headerControls: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search sites, domains, ports", text: $search).textFieldStyle(.plain).frame(minWidth: 120, maxWidth: 220)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            Button { Task { await model.refreshNetwork(); await model.refreshAll() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh")
            Button { editing = Service() } label: { Label("Add Service", systemImage: "plus").fixedSize() }
                .buttonStyle(.borderedProminent).tint(.ontu)
        }
    }

    private var filterPicker: some View {
        Picker("Show", selection: $filter) {
            ForEach(ServiceFilter.allCases) { Text($0.rawValue).tag($0) }
        }
    }

    private var tableHeight: CGFloat {
        CGFloat(min(max(filtered.count, 3), 14)) * 28 + 36
    }

    private var servicesPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    servicesTitle
                    Spacer(minLength: 12)
                    filterPicker.pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                HStack {
                    servicesTitle
                    Spacer(minLength: 8)
                    filterPicker.pickerStyle(.menu).fixedSize()
                }
            }
            if model.config.services.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "point.3.filled.connected.trianglepath.dotted").font(.system(size: 36)).foregroundStyle(Color.ontu)
                    Text("No services yet").font(.headline)
                    Text("Publish a port from “Running on this Mac” below, or add one.").foregroundStyle(.secondary)
                    Button("Add Service") { editing = Service() }.buttonStyle(.borderedProminent).tint(.ontu)
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                Table(filtered, selection: $selection) {
                    TableColumn("") { s in
                        StatusDot(color: rowColor(s))
                    }
                    .width(16)
                    TableColumn("Name") { s in
                        Text(s.name.isEmpty ? DomainLabel.of(s.normalizedDomain) : s.name).fontWeight(.medium)
                            .foregroundStyle(s.enabled ? .primary : .secondary)
                    }
                    .width(min: 90, ideal: 150)
                    TableColumn("Domain") { s in
                        Text(s.normalizedDomain).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    .width(min: 140, ideal: 260)
                    TableColumn("Local") { s in
                        Text(":\(String(s.localPort))").font(.system(.callout, design: .monospaced))
                    }
                    .width(60)
                    TableColumn("Health") { s in HealthIcons(service: s) }
                        .width(84)
                    TableColumn("Online") { s in
                        Toggle("", isOn: Binding(get: { s.enabled }, set: { model.setEnabled(s, $0) }))
                            .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    }
                    .width(56)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .contextMenu(forSelectionType: Service.ID.self) { ids in
                    if let id = ids.first, let s = model.binding(for: id) {
                        Button("Open site") { NSWorkspace.shared.open(model.publicURL(s)!) }
                        Button("Copy URL") { model.copy("https://\(s.normalizedDomain)") }
                        Button("Open local") { NSWorkspace.shared.open(URL(string: "http://localhost:\(s.localPort)")!) }
                        Divider()
                        Button("Edit…") { editing = s }
                        Button(s.enabled ? "Take offline" : "Bring online") { model.setEnabled(s, !s.enabled) }
                    }
                } primaryAction: { ids in
                    if let id = ids.first, let s = model.binding(for: id) { NSWorkspace.shared.open(model.publicURL(s)!) }
                }
                .frame(height: tableHeight)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                if !model.syncMessage.isEmpty {
                    Text(model.syncMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
    }

    private var servicesTitle: some View {
        HStack(spacing: 8) {
            Text("Services").font(.headline)
            Text("\(model.config.services.count)").font(.caption.monospacedDigit())
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15), in: Capsule())
        }
        .fixedSize()
    }

    private func rowColor(_ s: Service) -> Color {
        if !s.enabled { return .gray }
        let st = model.status(of: s)
        if st.port == .closed { return .red }
        return st.live.isOK ? .green : .orange
    }
}

/// Three tiny lights: local app · DNS · HTTPS on the internet.
struct HealthIcons: View {
    @EnvironmentObject var model: AppModel
    let service: Service

    var body: some View {
        let st = model.status(of: service)
        HStack(spacing: 10) {
            icon("laptopcomputer", st.port == .open ? .green : st.port == .closed ? .red : .gray,
                 st.port == .open ? "Local app running on :\(service.localPort)" : "Local app not running on :\(service.localPort)")
            icon("globe", st.dns.color, st.dns.isOK ? "DNS OK" : "DNS: \(st.dns.text)")
            icon("lock.shield", service.enabled ? st.live.color : .gray, st.live.isOK ? "Live on the internet over HTTPS" : "Internet: \(st.live.text)")
        }
    }

    private func icon(_ name: String, _ color: Color, _ help: String) -> some View {
        Image(systemName: name).foregroundStyle(color).help(help)
    }
}

// MARK: - Stats

struct StatsRow: View {
    @EnvironmentObject var model: AppModel
    let goToServer: () -> Void

    var body: some View {
        let active = model.config.services.filter(\.enabled)
        let live = active.filter { model.status(of: $0).live.isOK }.count
        let attention = model.config.services.filter { model.needsAttention($0) }.count
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
            Tile(icon: model.config.mode.icon, label: "Connection", tint: model.isConnected ? .green : model.isReady ? .red : .gray) {
                Text(model.isConnected ? "Connected" : model.isReady ? "Disconnected" : "Not set up").font(.title3.weight(.semibold))
                Text(connectionDetail).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            } action: {
                if !model.isReady { Button("Set up", action: goToServer) }
                else if model.isConnected { Button("Stop") { model.stopAllModes() } }
                else { Button("Connect") { model.startMode() } }
            }
            Tile(icon: "dot.radiowaves.left.and.right", label: "Live sites", tint: active.isEmpty ? .gray : live == active.count ? .green : .orange) {
                Text("\(live) / \(active.count)").font(.title3.weight(.semibold).monospacedDigit())
                Text("online over HTTPS").font(.caption).foregroundStyle(.secondary)
            } action: {
                Button("Sync") { Task { await model.syncCurrentMode() } }.disabled(model.busy || !model.isReady)
            }
            Tile(icon: attention == 0 ? "checkmark.seal" : "exclamationmark.triangle", label: "Attention", tint: attention == 0 ? .green : .orange) {
                Text(attention == 0 ? "All good" : "\(attention) site\(attention == 1 ? "" : "s")").font(.title3.weight(.semibold))
                Text(attention == 0 ? "nothing to fix" : "see Health column").font(.caption).foregroundStyle(.secondary)
            } action: { EmptyView() }
            Tile(icon: "network", label: "This Mac", tint: .ontu) {
                Text(model.network.publicIPv4.isEmpty ? "—" : model.network.publicIPv4).font(.system(.title3, design: .monospaced).weight(.semibold))
                Text("LAN \(model.network.localIPv4.isEmpty ? "—" : model.network.localIPv4)").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            } action: {
                Menu {
                    Button("Copy public IPv4") { model.copy(model.network.publicIPv4) }
                    Button("Copy LAN IP") { model.copy(model.network.localIPv4) }
                    Button("Copy IPv6") { model.copy(model.network.ipv6) }
                    Button("Copy router") { model.copy(model.network.router) }
                } label: { Image(systemName: "doc.on.doc") }
                .menuStyle(.borderlessButton).fixedSize()
            }
        }
    }

    private var connectionDetail: String {
        switch model.config.mode {
        case .relay: return model.serverIP.isEmpty ? model.config.server.host : "\(model.config.server.host) · \(model.serverIP)"
        case .staticIP: return model.staticTargetIP.isEmpty ? "static IP" : model.staticTargetIP
        case .cloudflare: return model.config.cloudflare.tunnelName.isEmpty ? "Cloudflare" : model.config.cloudflare.tunnelName
        }
    }
}

struct Tile<Content: View, Action: View>: View {
    let icon: String
    let label: String
    let tint: Color
    @ViewBuilder var content: Content
    @ViewBuilder var action: Action

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(label.uppercased()).font(.caption2.weight(.semibold)).tracking(0.8).foregroundStyle(.secondary)
                    .lineLimit(1).fixedSize()
                Spacer(minLength: 4)
                action.controlSize(.small).fixedSize()
            }
            content
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(tint.opacity(0.9)).frame(width: 3).padding(.vertical, 14)
        }
    }
}

// MARK: - Inspector

struct ServiceInspector: View {
    @EnvironmentObject var model: AppModel
    let service: Service
    let onEdit: () -> Void
    let onClose: () -> Void
    @State private var confirmDelete = false

    var body: some View {
        let st = model.status(of: service)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(service.name.isEmpty ? DomainLabel.of(service.normalizedDomain) : service.name).font(.title2.bold())
                        Link(service.normalizedDomain, destination: model.publicURL(service)!)
                            .font(.system(.callout, design: .monospaced))
                    }
                    Spacer()
                    Toggle("Online", isOn: Binding(get: { service.enabled }, set: { model.setEnabled(service, $0) }))
                        .toggleStyle(.switch).controlSize(.small)
                }

                VStack(spacing: 0) {
                    row("laptopcomputer", "Local app", "localhost:\(String(service.localPort))",
                        st.port == .open ? .ok : st.port == .closed ? .failed("Not running") : .unknown)
                    Divider()
                    if service.hasCommand {
                        row("terminal", "Command", service.startCommand,
                            st.process == .running ? .ok : st.process == .stopped || st.process == .none ? .unknown : .failed(st.process.label))
                        Divider()
                    }
                    row("globe", "DNS", st.dnsA.isEmpty ? "—" : st.dnsA.joined(separator: ", "), st.dns)
                    Divider()
                    row("lock.shield", "Internet (HTTPS)", st.liveCheckedAt.map { "checked \($0.formatted(date: .omitted, time: .shortened))" } ?? "", service.enabled ? st.live : .unknown)
                }
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))

                if service.enabled && !st.dns.isOK && model.config.mode != .cloudflare && !model.dnsTarget.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("DNS record needed", systemImage: "info.circle").font(.callout.weight(.semibold)).foregroundStyle(.orange)
                        Text("A · \(DomainLabel.of(service.normalizedDomain)) · \(model.dnsTarget)").font(.system(.callout, design: .monospaced))
                        Button("Copy IP") { model.copy(model.dnsTarget) }.controlSize(.small)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("DETAILS").font(.caption2.weight(.semibold)).tracking(0.8).foregroundStyle(.secondary)
                    detail("Frappe site", service.frappeSite.isEmpty ? "—" : service.frappeSite)
                    detail("Realtime port", service.socketPort > 0 ? String(service.socketPort) : "—")
                    if model.config.mode == .relay {
                        detail("Server port", service.remotePort > 0 ? "127.0.0.1:\(service.remotePort)" : "—")
                    }
                }

                VStack(spacing: 8) {
                    Button { NSWorkspace.shared.open(model.publicURL(service)!) } label: { Label("Open site", systemImage: "safari").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).tint(.ontu)
                    HStack {
                        Button { model.copy("https://\(service.normalizedDomain)") } label: { Label("Copy URL", systemImage: "link").frame(maxWidth: .infinity) }
                        Button { NSWorkspace.shared.open(URL(string: "http://localhost:\(service.localPort)")!) } label: { Label("Local", systemImage: "house").frame(maxWidth: .infinity) }
                    }
                    if service.hasCommand {
                        if model.isCommandRunning(service) {
                            Button { model.stopCommand(service) } label: { Label("Stop command", systemImage: "stop.fill").frame(maxWidth: .infinity) }
                        } else {
                            Button { model.startCommand(service) } label: { Label("Start command", systemImage: "play.fill").frame(maxWidth: .infinity) }
                        }
                    }
                    HStack {
                        Button { onEdit() } label: { Label("Edit", systemImage: "pencil").frame(maxWidth: .infinity) }
                        Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash").frame(maxWidth: .infinity) }
                    }
                }
                .controlSize(.large)
            }
            .padding(16)
        }
        .confirmationDialog("Delete \(service.name.isEmpty ? service.normalizedDomain : service.name)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { onClose(); model.delete(service) }
        } message: {
            Text("Removes it from OntuTunnel and from the server. Your app and DNS are not touched.")
        }
    }

    private func row(_ icon: String, _ title: String, _ value: String, _ check: Check) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 18).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                if !value.isEmpty { Text(value).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1) }
                if !check.isOK && check != .unknown && check != .checking {
                    Text(check.text).font(.caption).foregroundStyle(check.color)
                }
            }
            Spacer()
            Image(systemName: check.symbol).foregroundStyle(check.color)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private func detail(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).foregroundStyle(.secondary)
            Spacer()
            Text(v).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
        }
        .font(.callout)
    }
}
