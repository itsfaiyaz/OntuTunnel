import Foundation

/// Everything OntuTunnel does on the relay server, over SSH.
///
/// Ground rules, so existing sites on the server are never affected:
///  - OntuTunnel only creates its own files: /opt/ontutunnel, /etc/ontutunnel,
///    /var/lib/ontutunnel, the "ontutunnel-caddy" service, or (when nginx is
///    already there) /etc/nginx/conf.d/ontutunnel-*.conf. Nothing else is edited.
///  - Tunnel ports are random, unused ports bound to the server's 127.0.0.1 only.
///  - nginx is only reloaded after `nginx -t` passes; on failure our files are
///    removed again so nginx keeps running exactly as before.
enum RemoteServer {
    struct Result {
        let code: Int32
        let out: String
        let err: String
        var ok: Bool { code == 0 }
        var message: String {
            let text = (err.isEmpty ? out : err).trimmingCharacters(in: .whitespacesAndNewlines)
            return String(text.suffix(600))
        }
    }

    // MARK: SSH

    static func sshArgs(_ s: ServerConfig, extra: [String] = []) -> [String] {
        var args = ["-p", String(s.port),
                    "-o", "BatchMode=yes",
                    "-o", "ConnectTimeout=12",
                    "-o", "StrictHostKeyChecking=accept-new",
                    "-o", "ServerAliveInterval=20",
                    "-o", "ServerAliveCountMax=3"]
        if !s.keyPath.trimmingCharacters(in: .whitespaces).isEmpty {
            args += ["-i", s.expandedKeyPath, "-o", "IdentitiesOnly=yes"]
        }
        return args + extra + ["\(s.user.trimmingCharacters(in: .whitespaces))@\(s.host.trimmingCharacters(in: .whitespaces))"]
    }

    /// Runs `script` with bash on the server (sent on stdin — no quoting issues).
    static func run(_ s: ServerConfig, _ script: String, timeout: TimeInterval = 120) async -> Result {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                task.arguments = sshArgs(s) + ["bash -s"]
                let input = Pipe(), output = Pipe(), errors = Pipe()
                task.standardInput = input
                task.standardOutput = output
                task.standardError = errors
                do { try task.run() } catch {
                    cont.resume(returning: Result(code: -1, out: "", err: error.localizedDescription)); return
                }
                input.fileHandleForWriting.write(Data(("set -o pipefail\n" + script + "\n").utf8))
                try? input.fileHandleForWriting.close()
                let killer = DispatchWorkItem { if task.isRunning { task.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let out = output.fileHandleForReading.readDataToEndOfFile()
                let err = errors.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                killer.cancel()
                cont.resume(returning: Result(code: task.terminationStatus,
                                              out: String(data: out, encoding: .utf8) ?? "",
                                              err: String(data: err, encoding: .utf8) ?? ""))
            }
        }
    }

    /// Shell line that writes `content` to `path` as root (base64: safe for any text).
    static func writeFile(_ path: String, _ content: String) -> String {
        let b64 = Data(content.utf8).base64EncodedString()
        return "echo '\(b64)' | base64 -d | sudo tee '\(path)' >/dev/null"
    }

    // MARK: Probe (read-only)

    struct Facts {
        var os = "", arch = "", sudo = false
        var port80 = "", port443 = ""          // process names using them ("" = free)
        var nginx = false, certbot = false, ourCaddy = false
        var usedPorts: Set<Int> = []
        var forwarding = ""

        enum Plan { case use(ServerMode), blocked(String) }

        /// What OntuTunnel will do on this server.
        var plan: Plan {
            if ourCaddy || (port80.isEmpty && port443.isEmpty) { return .use(.caddy) }
            if port80.contains("nginx") || port443.contains("nginx") {
                return nginx ? .use(.nginx) : .blocked("nginx is using port 80/443 but its command was not found.")
            }
            let who = [port80, port443].filter { !$0.isEmpty }.joined(separator: ", ")
            return .blocked("Ports 80/443 are used by \(who). OntuTunnel works on a free server or one running nginx, and won't touch \(who).")
        }
    }

    static func probe(_ s: ServerConfig) async -> (Result, Facts?) {
        let script = #"""
        echo "os=$(. /etc/os-release 2>/dev/null; echo "$PRETTY_NAME")"
        echo "arch=$(uname -m)"
        echo "sudo=$(sudo -n true 2>/dev/null && echo yes || echo no)"
        L=$(sudo -n ss -tlnpH 2>/dev/null || ss -tlnH 2>/dev/null)
        for p in 80 443; do
          echo "port$p=$(echo "$L" | awk -v p=":$p" '$4 ~ p"$"' | grep -o '(("[^"]*"' | head -1 | tr -d '("')"
          echo "listen$p=$(echo "$L" | awk -v p=":$p" '$4 ~ p"$"' | wc -l | tr -d ' ')"
        done
        echo "nginx=$(command -v nginx || ls /usr/sbin/nginx 2>/dev/null)"
        echo "certbot=$(command -v certbot)"
        echo "ourcaddy=$( (systemctl is-active ontutunnel-caddy || systemctl is-active localbridge-caddy) 2>/dev/null | grep -m1 '^active$')"
        echo "used=$(echo "$L" | awk '{print $4}' | sed 's/.*://' | sort -un | tr '\n' ',')"
        echo "forwarding=$(sudo -n sshd -T 2>/dev/null | awk '/^allowtcpforwarding/{print $2}')"
        """#
        let r = await run(s, script, timeout: 40)
        guard r.ok else { return (r, nil) }
        var f = Facts()
        for line in r.out.split(separator: "\n") {
            let kv = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            let (k, v) = (kv[0], kv[1].trimmingCharacters(in: .whitespaces))
            switch k {
            case "os": f.os = v
            case "arch": f.arch = v
            case "sudo": f.sudo = v == "yes"
            case "port80": f.port80 = v
            case "port443": f.port443 = v
            case "listen80": if f.port80.isEmpty, (Int(v) ?? 0) > 0 { f.port80 = "another program" }
            case "listen443": if f.port443.isEmpty, (Int(v) ?? 0) > 0 { f.port443 = "another program" }
            case "nginx": f.nginx = !v.isEmpty
            case "certbot": f.certbot = !v.isEmpty
            case "ourcaddy": f.ourCaddy = v == "active"
            case "used": f.usedPorts = Set(v.split(separator: ",").compactMap { Int($0) })
            case "forwarding": f.forwarding = v
            default: break
            }
        }
        if f.ourCaddy {                      // ports held by our own Caddy are "ours"
            if f.port80 == "caddy" { f.port80 = "" }
            if f.port443 == "caddy" { f.port443 = "" }
        }
        return (r, f)
    }

    /// A random port in 20000–39999 that nothing on the server listens on.
    static func freePort(avoiding used: Set<Int>) -> Int {
        while true {
            let p = Int.random(in: 20000...39999)
            if !used.contains(p) { return p }
        }
    }

    // MARK: Caddy mode

    static let caddyUnit = """
    [Unit]
    Description=OntuTunnel relay (Caddy, own instance)
    After=network-online.target
    Wants=network-online.target

    [Service]
    ExecStart=/opt/ontutunnel/caddy run --config /etc/ontutunnel/Caddyfile --adapter caddyfile
    Environment=XDG_DATA_HOME=/var/lib/ontutunnel XDG_CONFIG_HOME=/var/lib/ontutunnel
    Restart=always
    RestartSec=3
    LimitNOFILE=1048576

    [Install]
    WantedBy=multi-user.target
    """

    static func caddyfile(_ services: [Service], email: String) -> String {
        var out = "# Written by OntuTunnel — edits are replaced on the next sync.\n{\n\tadmin off\n"
        if !email.isEmpty { out += "\temail \(email)\n" }
        out += "}\n"
        for s in services where s.enabled && s.remotePort > 0 && !s.normalizedDomain.isEmpty {
            out += "\n\(s.normalizedDomain) {\n"
            if s.remoteSocketPort > 0 {
                out += "\treverse_proxy /socket.io/* 127.0.0.1:\(s.remoteSocketPort)\n"
            }
            out += "\treverse_proxy 127.0.0.1:\(s.remotePort) {\n"
            if !s.frappeSite.isEmpty { out += "\t\theader_up X-Frappe-Site-Name \(s.frappeSite)\n" }
            out += "\t}\n}\n"
        }
        return out
    }

    static func installCaddyScript() -> String {
        """
        set -e
        # migrate from the old name (LocalBridge): same Caddy, its certificates kept
        if [ -e /etc/systemd/system/localbridge-caddy.service ]; then
          sudo systemctl disable --now localbridge-caddy 2>/dev/null || true
          sudo rm -f /etc/systemd/system/localbridge-caddy.service
          [ -d /var/lib/localbridge ] && [ ! -d /var/lib/ontutunnel ] && sudo mv /var/lib/localbridge /var/lib/ontutunnel
          [ -d /opt/localbridge ] && [ ! -d /opt/ontutunnel ] && sudo mv /opt/localbridge /opt/ontutunnel
          sudo rm -rf /etc/localbridge
        fi
        sudo mkdir -p /opt/ontutunnel /etc/ontutunnel /var/lib/ontutunnel
        if [ ! -x /opt/ontutunnel/caddy ]; then
          case "$(uname -m)" in x86_64) A=amd64;; aarch64|arm64) A=arm64;; *) echo "Unsupported CPU $(uname -m)" >&2; exit 1;; esac
          sudo curl -fsSL "https://caddyserver.com/api/download?os=linux&arch=$A" -o /opt/ontutunnel/caddy.new
          sudo chmod +x /opt/ontutunnel/caddy.new
          sudo mv /opt/ontutunnel/caddy.new /opt/ontutunnel/caddy
        fi
        /opt/ontutunnel/caddy version
        \(writeFile("/etc/systemd/system/ontutunnel-caddy.service", caddyUnit))
        sudo systemctl daemon-reload
        """
    }

    static func applyCaddyScript(_ services: [Service], email: String) -> String {
        """
        set -e
        \(writeFile("/etc/ontutunnel/Caddyfile.new", caddyfile(services, email: email)))
        sudo XDG_DATA_HOME=/var/lib/ontutunnel /opt/ontutunnel/caddy validate --config /etc/ontutunnel/Caddyfile.new --adapter caddyfile 2>&1 | tail -3
        sudo mv /etc/ontutunnel/Caddyfile.new /etc/ontutunnel/Caddyfile
        sudo systemctl enable ontutunnel-caddy >/dev/null 2>&1
        sudo systemctl restart ontutunnel-caddy
        sleep 2
        systemctl is-active ontutunnel-caddy
        """
    }

    // MARK: nginx mode (existing nginx: only our own files)

    static func nginxFileName(_ domain: String) -> String { "/etc/nginx/conf.d/ontutunnel-\(domain).conf" }

    static func nginxConf(_ s: Service, withTLS: Bool) -> String {
        let d = s.normalizedDomain
        var proxy = """
            location / {
                proxy_pass http://127.0.0.1:\(s.remotePort);
                proxy_http_version 1.1;
                proxy_set_header Host $host;
                proxy_set_header X-Real-IP $remote_addr;
                proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                proxy_set_header X-Forwarded-Proto $scheme;
        """
        if !s.frappeSite.isEmpty { proxy += "\n            proxy_set_header X-Frappe-Site-Name \(s.frappeSite);" }
        proxy += """

                proxy_read_timeout 300;
                client_max_body_size 50m;
            }
        """
        if s.remoteSocketPort > 0 {
            proxy += """

            location /socket.io {
                proxy_pass http://127.0.0.1:\(s.remoteSocketPort);
                proxy_http_version 1.1;
                proxy_set_header Upgrade $http_upgrade;
                proxy_set_header Connection "upgrade";
                proxy_set_header Host $host;
        """
            if !s.frappeSite.isEmpty { proxy += "\n            proxy_set_header X-Frappe-Site-Name \(s.frappeSite);" }
            proxy += "\n        }"
        }
        let acme = "    location /.well-known/acme-challenge/ { root /var/www/ontutunnel-acme; }"
        if !withTLS {
            return """
            # Written by OntuTunnel for \(d) — remove this file to undo.
            server {
                listen 80;
                listen [::]:80;
                server_name \(d);
            \(acme)
            \(proxy)
            }

            """
        }
        return """
        # Written by OntuTunnel for \(d) — remove this file to undo.
        server {
            listen 80;
            listen [::]:80;
            server_name \(d);
        \(acme)
            location / { return 301 https://$host$request_uri; }
        }
        server {
            listen 443 ssl;
            listen [::]:443 ssl;
            server_name \(d);
            ssl_certificate /etc/letsencrypt/live/\(d)/fullchain.pem;
            ssl_certificate_key /etc/letsencrypt/live/\(d)/privkey.pem;
        \(proxy)
        }

        """
    }

    /// Writes our files, removes our files for deleted services, tests nginx,
    /// reloads — or rolls back to the previous files if the test fails.
    static func applyNginxScript(_ services: [Service], email: String) -> String {
        let active = services.filter { $0.enabled && $0.remotePort > 0 && !$0.normalizedDomain.isEmpty }
        let keep = active.map { "ontutunnel-\($0.normalizedDomain).conf" }.joined(separator: " ")
        var script = """
        set -e
        # migrate from the old name (LocalBridge): adopt its files; certbot
        # renewals still use /var/www/localbridge-acme, so keep that as a link
        for f in /etc/nginx/conf.d/localbridge-*.conf; do
          [ -e "$f" ] && sudo mv "$f" "/etc/nginx/conf.d/ontutunnel-${f#/etc/nginx/conf.d/localbridge-}"
        done
        sudo mkdir -p /var/www/ontutunnel-acme
        if [ -d /var/www/localbridge-acme ] && [ ! -L /var/www/localbridge-acme ]; then
          sudo cp -a /var/www/localbridge-acme/. /var/www/ontutunnel-acme/ 2>/dev/null || true
          sudo rm -rf /var/www/localbridge-acme
          sudo ln -s /var/www/ontutunnel-acme /var/www/localbridge-acme
        fi
        sudo rm -rf /var/lib/localbridge
        sudo mkdir -p /var/lib/ontutunnel/nginx-backup
        sudo rm -f /var/lib/ontutunnel/nginx-backup/*
        for f in /etc/nginx/conf.d/ontutunnel-*.conf; do [ -e "$f" ] && sudo cp "$f" /var/lib/ontutunnel/nginx-backup/; done
        restore() { sudo rm -f /etc/nginx/conf.d/ontutunnel-*.conf; sudo cp /var/lib/ontutunnel/nginx-backup/* /etc/nginx/conf.d/ 2>/dev/null || true; }
        # domains another (non-OntuTunnel) nginx file already serves are refused
        for d in \(active.map(\.normalizedDomain).joined(separator: " ")); do
          if sudo grep -rlE "server_name[^;]*[[:space:]]$d([[:space:];]|$)" /etc/nginx/ 2>/dev/null | grep -v "/ontutunnel-" | grep -q .; then
            echo "CONFLICT: $d is already configured in another nginx file — not touching it." >&2; exit 3
          fi
        done
        for f in /etc/nginx/conf.d/ontutunnel-*.conf; do
          [ -e "$f" ] || continue
          case " \(keep) " in *" $(basename "$f") "*) ;; *) sudo rm -f "$f";; esac
        done

        """
        for s in active {
            let d = s.normalizedDomain
            script += """
            if sudo test -f /etc/letsencrypt/live/\(d)/fullchain.pem; then
              \(writeFile(nginxFileName(d), nginxConf(s, withTLS: true)))
            else
              \(writeFile(nginxFileName(d), nginxConf(s, withTLS: false)))
            fi

            """
        }
        script += """
        if ! sudo nginx -t 2>/tmp/ontutunnel-nginx-test; then
          restore; cat /tmp/ontutunnel-nginx-test >&2; echo "nginx test failed — your previous config was kept" >&2; exit 4
        fi
        sudo systemctl reload nginx

        """
        // certificates for domains that don't have one yet and already point here
        let mail = email.isEmpty ? "--register-unsafely-without-email" : "-m \(email)"
        for s in active {
            let d = s.normalizedDomain
            script += """
            if ! sudo test -f /etc/letsencrypt/live/\(d)/fullchain.pem; then
              command -v certbot >/dev/null || (sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq certbot)
              if sudo certbot certonly --webroot -w /var/www/ontutunnel-acme -d \(d) --non-interactive --agree-tos \(mail) --deploy-hook "systemctl reload nginx" >/tmp/ontutunnel-certbot 2>&1; then
                \(writeFile(nginxFileName(d), nginxConf(s, withTLS: true)))
                if sudo nginx -t 2>/dev/null; then sudo systemctl reload nginx; echo "CERT-OK \(d)"; else \(writeFile(nginxFileName(d), nginxConf(s, withTLS: false))); sudo nginx -t && sudo systemctl reload nginx; fi
              else
                echo "CERT-PENDING \(d): $(tail -2 /tmp/ontutunnel-certbot | tr '\\n' ' ')"
              fi
            fi

            """
        }
        return script
    }

    // MARK: Remove everything OntuTunnel added

    static func uninstallScript(_ mode: ServerMode?) -> String {
        """
        sudo systemctl disable --now ontutunnel-caddy localbridge-caddy 2>/dev/null || true
        sudo rm -f /etc/systemd/system/ontutunnel-caddy.service /etc/systemd/system/localbridge-caddy.service
        sudo systemctl daemon-reload
        if ls /etc/nginx/conf.d/ontutunnel-*.conf /etc/nginx/conf.d/localbridge-*.conf >/dev/null 2>&1; then
          sudo rm -f /etc/nginx/conf.d/ontutunnel-*.conf /etc/nginx/conf.d/localbridge-*.conf
          sudo nginx -t && sudo systemctl reload nginx
        fi
        sudo rm -rf /opt/ontutunnel /etc/ontutunnel /var/lib/ontutunnel /var/www/ontutunnel-acme
        sudo rm -rf /opt/localbridge /etc/localbridge /var/lib/localbridge /var/www/localbridge-acme
        echo removed
        """
    }
}
