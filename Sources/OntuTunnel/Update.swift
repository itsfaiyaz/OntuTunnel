import AppKit
import SwiftUI

/// Update notice: asks GitHub for the latest release (at start, then twice a
/// day) and shows "New version available". Nothing is downloaded by itself.
struct UpdateInfo: Equatable {
    let version: String
    let url: URL
}

enum UpdateCheck {
    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    static func latest() async -> UpdateInfo? {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/itsfaiyaz/OntuTunnel/releases/latest")!)
        req.timeoutInterval = 10
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("OntuTunnel/\(current)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String, let link = obj["html_url"] as? String,
              link.hasPrefix("https://github.com/itsfaiyaz/OntuTunnel/"), let url = URL(string: link),
              (obj["prerelease"] as? Bool) != true, (obj["draft"] as? Bool) != true
        else { return nil }
        let v = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return newer(v, than: current) ? UpdateInfo(version: v, url: url) : nil
    }

    /// "1.1.10" is newer than "1.1.9".
    static func newer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}

extension AppModel {
    func checkForUpdate() async {
        guard !Demo.on, let u = await UpdateCheck.latest() else { return }
        if update != u { log("OntuTunnel", "New version \(u.version) is available: \(u.url.absoluteString)") }
        update = u
    }
}

struct UpdateBanner: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("hiddenUpdate") private var hidden = ""

    var body: some View {
        if let u = model.update, hidden != u.version {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill").font(.title2).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("OntuTunnel \(u.version) is available").font(.headline)
                    Text("You have \(UpdateCheck.current).").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Download") { NSWorkspace.shared.open(u.url) }.buttonStyle(.borderedProminent)
                Button("Later") { hidden = u.version }
            }
            .padding(12)
            .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
