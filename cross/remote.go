package main

import (
	"bytes"
	"encoding/base64"
	"errors"
	"fmt"
	"math/rand"
	"net"
	"os"
	"strconv"
	"strings"
	"time"

	"golang.org/x/crypto/ssh"
)

// Everything OntuTunnel does on the relay server, over SSH.
// Ground rules (same as the macOS app): only its own files
// (/opt/ontutunnel, /etc/ontutunnel, /var/lib/ontutunnel, the
// "ontutunnel-caddy" service, or /etc/nginx/conf.d/ontutunnel-*.conf);
// nginx is reloaded only after `nginx -t` passes; tunnel ports are random
// and bound to the server's 127.0.0.1.

// Dial opens an SSH connection; the host key is pinned on first use.
func Dial(store *Store) (*ssh.Client, error) {
	s := store.Get().Server
	if !s.Complete() {
		return nil, errors.New("enter the server IP and SSH user first")
	}
	keyData, err := os.ReadFile(expandHome(s.KeyPath))
	if err != nil {
		return nil, fmt.Errorf("SSH key not found at %s — choose a key or create one", s.KeyPath)
	}
	signer, err := ssh.ParsePrivateKey(keyData)
	if err != nil {
		return nil, fmt.Errorf("can't read SSH key (passphrase-protected keys aren't supported): %v", err)
	}
	cfg := &ssh.ClientConfig{
		User:    strings.TrimSpace(s.User),
		Auth:    []ssh.AuthMethod{ssh.PublicKeys(signer)},
		Timeout: 12 * time.Second,
		HostKeyCallback: func(_ string, _ net.Addr, key ssh.PublicKey) error {
			got := base64.StdEncoding.EncodeToString(key.Marshal())
			pinned := store.Get().Server.HostKey
			if pinned == "" {
				store.Update(func(c *Config) { c.Server.HostKey = got })
				return nil
			}
			if pinned != got {
				return errors.New("the server's host key changed — if you rebuilt the server, clear it in Connection → Forget host key")
			}
			return nil
		},
	}
	port := s.Port
	if port == 0 {
		port = 22
	}
	client, err := ssh.Dial("tcp", net.JoinHostPort(strings.TrimSpace(s.Host), strconv.Itoa(port)), cfg)
	if err != nil {
		return nil, explainSSH(err)
	}
	return client, nil
}

func explainSSH(err error) error {
	m := strings.ToLower(err.Error())
	switch {
	case strings.Contains(m, "unable to authenticate"), strings.Contains(m, "permission denied"):
		return errors.New("the server refused the SSH key — add the public key shown below to the server, then test again")
	case strings.Contains(m, "timeout"), strings.Contains(m, "no route"), strings.Contains(m, "refused"):
		return errors.New("no answer from the server — check the IP, that the server is running, and that port 22 is open")
	case strings.Contains(m, "no such host"):
		return errors.New("server name not found — check the IP or host name")
	}
	return err
}

// Run executes a bash script on the server (sent on stdin).
func Run(store *Store, script string, timeout time.Duration) (string, string, error) {
	client, err := Dial(store)
	if err != nil {
		return "", "", err
	}
	defer client.Close()
	return runOn(client, script, timeout)
}

// freeStalePortsScript ends old SSH sessions that still hold our tunnel
// ports. After a network change the server keeps the dead session for
// minutes (its ClientAlive timeout) and the new tunnel can't take the ports
// until it's gone. Only sshd processes listening on these ports are touched.
func freeStalePortsScript(ports []int) string {
	var ps []string
	for _, p := range ports {
		ps = append(ps, fmt.Sprint(p))
	}
	return `for p in ` + strings.Join(ps, " ") + `; do
  for pid in $( (sudo -n ss -ltnpH "sport = :$p" 2>/dev/null || ss -ltnpH "sport = :$p") | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u); do
    case "$(ps -o comm= -p "$pid")" in sshd*) sudo -n kill "$pid" 2>/dev/null || kill "$pid" 2>/dev/null; echo "freed $p";; esac
  done
done
true`
}

func runOn(client *ssh.Client, script string, timeout time.Duration) (string, string, error) {
	sess, err := client.NewSession()
	if err != nil {
		return "", "", err
	}
	defer sess.Close()
	var out, errb bytes.Buffer
	sess.Stdout, sess.Stderr = &out, &errb
	sess.Stdin = strings.NewReader("set -o pipefail\n" + script + "\n")
	done := make(chan error, 1)
	go func() { done <- sess.Run("bash -s") }()
	select {
	case err = <-done:
	case <-time.After(timeout):
		_ = sess.Signal(ssh.SIGKILL)
		err = errors.New("timed out")
	}
	return out.String(), errb.String(), err
}

func writeFile(path, content string) string {
	b64 := base64.StdEncoding.EncodeToString([]byte(content))
	return fmt.Sprintf("echo '%s' | base64 -d | sudo tee '%s' >/dev/null", b64, path)
}

type Facts struct {
	OS        string `json:"os"`
	Arch      string `json:"arch"`
	Sudo      bool   `json:"sudo"`
	Port80    string `json:"port80"`
	Port443   string `json:"port443"`
	Nginx     bool   `json:"nginx"`
	Certbot   bool   `json:"certbot"`
	OurCaddy  bool   `json:"ourCaddy"`
	UsedPorts []int  `json:"usedPorts"`
	// Tunnel ports OntuTunnel gave to each domain on this server (from any
	// computer), so two computers never pick the same port.
	Reserved   map[string][]int `json:"reserved"`
	Forwarding string           `json:"forwarding"`
}

// Plan returns "caddy", "nginx", or an error explaining why not.
func (f Facts) Plan() (string, error) {
	if f.OurCaddy || (f.Port80 == "" && f.Port443 == "") {
		return "caddy", nil
	}
	if strings.Contains(f.Port80, "nginx") || strings.Contains(f.Port443, "nginx") {
		if f.Nginx {
			return "nginx", nil
		}
		return "", errors.New("nginx is using port 80/443 but its command was not found")
	}
	who := strings.Trim(strings.Join([]string{f.Port80, f.Port443}, ", "), ", ")
	return "", fmt.Errorf("ports 80/443 are used by %s — OntuTunnel works on a free server or one running nginx, and won't touch %s", who, who)
}

const probeScript = `echo "os=$(. /etc/os-release 2>/dev/null; echo "$PRETTY_NAME")"
echo "arch=$(uname -m)"
echo "sudo=$(sudo -n true 2>/dev/null && echo yes || echo no)"
L=$(sudo -n ss -tlnpH 2>/dev/null || ss -tlnH 2>/dev/null)
for p in 80 443; do
  echo "port$p=$(echo "$L" | awk -v p=":$p" '$4 ~ p"$"' | grep -o '(("[^"]*"' | head -1 | tr -d '("')"
  echo "listen$p=$(echo "$L" | awk -v p=":$p" '$4 ~ p"$"' | wc -l | tr -d ' ')"
done
echo "nginx=$(command -v nginx || ls /usr/sbin/nginx 2>/dev/null)"
echo "certbot=$(command -v certbot)"
echo "ourcaddy=$(systemctl is-active ontutunnel-caddy 2>/dev/null | grep -m1 '^active$')"
echo "used=$(echo "$L" | awk '{print $4}' | sed 's/.*://' | sort -un | tr '\n' ',')"
echo "forwarding=$(sudo -n sshd -T 2>/dev/null | awk '/^allowtcpforwarding/{print $2}')"
echo "reserved=$(grep -Ho '127\.0\.0\.1:[0-9]*' /etc/nginx/conf.d/ontutunnel-*.conf /etc/ontutunnel/sites/*.caddy 2>/dev/null | sed -E 's#^.*/(ontutunnel-)?([^/]*)\.(conf|caddy):127\.0\.0\.1:#\2=#' | tr '\n' ',')"`

func Probe(store *Store) (Facts, error) {
	out, errOut, err := Run(store, probeScript, 40*time.Second)
	if err != nil {
		if errOut != "" {
			return Facts{}, fmt.Errorf("%v: %s", err, strings.TrimSpace(errOut))
		}
		return Facts{}, err
	}
	return parseFacts(out), nil
}

// parseFacts reads the probe script's "key=value" lines.
func parseFacts(out string) Facts {
	var f Facts
	for _, line := range strings.Split(out, "\n") {
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		v = strings.TrimSpace(v)
		switch k {
		case "os":
			f.OS = v
		case "arch":
			f.Arch = v
		case "sudo":
			f.Sudo = v == "yes"
		case "port80":
			f.Port80 = v
		case "port443":
			f.Port443 = v
		case "listen80":
			if n, _ := strconv.Atoi(v); f.Port80 == "" && n > 0 {
				f.Port80 = "another program"
			}
		case "listen443":
			if n, _ := strconv.Atoi(v); f.Port443 == "" && n > 0 {
				f.Port443 = "another program"
			}
		case "nginx":
			f.Nginx = v != ""
		case "certbot":
			f.Certbot = v != ""
		case "ourcaddy":
			f.OurCaddy = v == "active"
		case "used":
			for _, p := range strings.Split(v, ",") {
				if n, err := strconv.Atoi(p); err == nil {
					f.UsedPorts = append(f.UsedPorts, n)
				}
			}
		case "forwarding":
			f.Forwarding = v
		case "reserved":
			f.Reserved = map[string][]int{}
			for _, pair := range strings.Split(v, ",") {
				d, p, ok := strings.Cut(pair, "=")
				if n, err := strconv.Atoi(p); ok && err == nil {
					f.Reserved[d] = append(f.Reserved[d], n)
				}
			}
		}
	}
	if f.OurCaddy {
		if f.Port80 == "caddy" {
			f.Port80 = ""
		}
		if f.Port443 == "caddy" {
			f.Port443 = ""
		}
	}
	return f
}

func freePort(used map[int]bool) int {
	for {
		p := 20000 + rand.Intn(20000)
		if !used[p] {
			return p
		}
	}
}

// ---------- Caddy mode ----------

const caddyUnit = `[Unit]
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
`

func activeServices(services []Service) []Service {
	var out []Service
	for _, s := range services {
		if s.Enabled && s.RemotePort > 0 && s.Safe() {
			out = append(out, s)
		}
	}
	return out
}

// Caddy mode: the main Caddyfile only has global options and imports one
// file per site, so several computers can share the server and each only
// writes and removes its own sites.
func caddyMain(email string) string {
	var b strings.Builder
	b.WriteString("# Written by OntuTunnel. Sites: /etc/ontutunnel/sites/<domain>.caddy\n{\n\tadmin off\n")
	if email != "" {
		fmt.Fprintf(&b, "\temail %s\n", email)
	}
	b.WriteString("}\n\nimport /etc/ontutunnel/sites/*.caddy\n")
	return b.String()
}

func caddySite(s Service) string {
	var b strings.Builder
	fmt.Fprintf(&b, "# Written by OntuTunnel\n%s {\n", s.NormalizedDomain())
	if s.RemoteSocketPort > 0 {
		fmt.Fprintf(&b, "\treverse_proxy /socket.io/* 127.0.0.1:%d\n", s.RemoteSocketPort)
	}
	fmt.Fprintf(&b, "\treverse_proxy 127.0.0.1:%d {\n", s.RemotePort)
	if s.FrappeSite != "" {
		fmt.Fprintf(&b, "\t\theader_up X-Frappe-Site-Name %s\n", s.FrappeSite)
	}
	b.WriteString("\t}\n}\n")
	return b.String()
}

// conflictScript stops when a domain this computer hasn't published yet
// already has an OntuTunnel file that points to another port: another
// computer serves it, and taking it over would break that computer's site.
func conflictScript(active []Service, published []string, file func(string) string) string {
	var b strings.Builder
	for _, s := range active {
		d := s.NormalizedDomain()
		if contains(published, d) {
			continue
		}
		fmt.Fprintf(&b, "if [ -e %q ] && ! grep -q '127.0.0.1:%d[;[:space:]]' %q; then echo \"CONFLICT: %s is already published by another computer with OntuTunnel. Remove it there first (or, if that computer is gone, delete %s on the server), or use another domain.\" >&2; exit 3; fi\n",
			file(d), s.RemotePort, file(d), d, file(d))
	}
	return b.String()
}

func installCaddyScript() string {
	return `set -e
sudo mkdir -p /opt/ontutunnel /etc/ontutunnel /var/lib/ontutunnel
if [ ! -x /opt/ontutunnel/caddy ]; then
  case "$(uname -m)" in x86_64) A=amd64;; aarch64|arm64) A=arm64;; *) echo "Unsupported CPU $(uname -m)" >&2; exit 1;; esac
  sudo curl -fsSL "https://caddyserver.com/api/download?os=linux&arch=$A" -o /opt/ontutunnel/caddy.new
  sudo chmod +x /opt/ontutunnel/caddy.new
  sudo mv /opt/ontutunnel/caddy.new /opt/ontutunnel/caddy
fi
/opt/ontutunnel/caddy version
` + writeFile("/etc/systemd/system/ontutunnel-caddy.service", caddyUnit) + `
sudo systemctl daemon-reload`
}

func caddySiteFile(d string) string { return "/etc/ontutunnel/sites/" + d + ".caddy" }

func applyCaddyScript(services []Service, email string, published []string) string {
	active := activeServices(services)
	var keep []string
	for _, s := range active {
		keep = append(keep, s.NormalizedDomain())
	}
	var b strings.Builder
	b.WriteString(`set -e
sudo mkdir -p /etc/ontutunnel/sites /var/lib/ontutunnel
sudo rm -rf /var/lib/ontutunnel/caddy-backup && sudo mkdir -p /var/lib/ontutunnel/caddy-backup
sudo cp -a /etc/ontutunnel/sites /var/lib/ontutunnel/caddy-backup/ 2>/dev/null || true
[ -e /etc/ontutunnel/Caddyfile ] && sudo cp /etc/ontutunnel/Caddyfile /var/lib/ontutunnel/caddy-backup/
restore() { sudo rm -rf /etc/ontutunnel/sites; sudo cp -a /var/lib/ontutunnel/caddy-backup/sites /etc/ontutunnel/ 2>/dev/null || sudo mkdir -p /etc/ontutunnel/sites; sudo cp /var/lib/ontutunnel/caddy-backup/Caddyfile /etc/ontutunnel/ 2>/dev/null || true; }
`)
	b.WriteString(conflictScript(active, published, caddySiteFile))
	// remove only sites this computer published that are gone now
	for _, d := range published {
		if !contains(keep, d) && validHost.MatchString(d) {
			fmt.Fprintf(&b, "sudo rm -f %q\n", caddySiteFile(d))
		}
	}
	for _, s := range active {
		b.WriteString(writeFile(caddySiteFile(s.NormalizedDomain()), caddySite(s)) + "\n")
	}
	b.WriteString(writeFile("/etc/ontutunnel/Caddyfile", caddyMain(email)) + `
if ! sudo XDG_DATA_HOME=/var/lib/ontutunnel /opt/ontutunnel/caddy validate --config /etc/ontutunnel/Caddyfile --adapter caddyfile >/tmp/ontutunnel-caddy.log 2>&1; then
  tail -3 /tmp/ontutunnel-caddy.log >&2; restore; echo "Caddy config was invalid — put back the previous one." >&2; exit 1
fi
sudo systemctl enable ontutunnel-caddy >/dev/null 2>&1
sudo systemctl restart ontutunnel-caddy
sleep 2
systemctl is-active ontutunnel-caddy`)
	return b.String()
}

// ---------- nginx mode ----------

func nginxFile(d string) string { return "/etc/nginx/conf.d/ontutunnel-" + d + ".conf" }

func nginxConf(s Service, tls bool) string {
	d := s.NormalizedDomain()
	site := ""
	if s.FrappeSite != "" {
		site = "\n        proxy_set_header X-Frappe-Site-Name " + s.FrappeSite + ";"
	}
	proxy := fmt.Sprintf(`    location / {
        proxy_pass http://127.0.0.1:%d;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;%s
        proxy_read_timeout 300;
        client_max_body_size 50m;
    }`, s.RemotePort, site)
	if s.RemoteSocketPort > 0 {
		proxy += fmt.Sprintf(`
    location /socket.io {
        proxy_pass http://127.0.0.1:%d;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;%s
    }`, s.RemoteSocketPort, site)
	}
	acme := "    location /.well-known/acme-challenge/ { root /var/www/ontutunnel-acme; }"
	if !tls {
		return fmt.Sprintf("# Written by OntuTunnel for %s — remove this file to undo.\nserver {\n    listen 80;\n    listen [::]:80;\n    server_name %s;\n%s\n%s\n}\n", d, d, acme, proxy)
	}
	return fmt.Sprintf(`# Written by OntuTunnel for %[1]s — remove this file to undo.
server {
    listen 80;
    listen [::]:80;
    server_name %[1]s;
%[2]s
    location / { return 301 https://$host$request_uri; }
}
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name %[1]s;
    ssl_certificate /etc/letsencrypt/live/%[1]s/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/%[1]s/privkey.pem;
%[3]s
}
`, d, acme, proxy)
}

// published: domains this installation wrote before; only those may be removed.
func applyNginxScript(services []Service, email string, published []string) string {
	active := activeServices(services)
	var keep, domains []string
	for _, s := range active {
		keep = append(keep, "ontutunnel-"+s.NormalizedDomain()+".conf")
		domains = append(domains, s.NormalizedDomain())
	}
	var b strings.Builder
	fmt.Fprintf(&b, `set -e
sudo mkdir -p /var/www/ontutunnel-acme /var/lib/ontutunnel/nginx-backup
sudo rm -f /var/lib/ontutunnel/nginx-backup/*
for f in /etc/nginx/conf.d/ontutunnel-*.conf; do [ -e "$f" ] && sudo cp "$f" /var/lib/ontutunnel/nginx-backup/; done
restore() { sudo rm -f /etc/nginx/conf.d/ontutunnel-*.conf; sudo cp /var/lib/ontutunnel/nginx-backup/* /etc/nginx/conf.d/ 2>/dev/null || true; }
for d in %s; do
  if sudo grep -rlE "server_name[^;]*[[:space:]]$d([[:space:];]|$)" /etc/nginx/ 2>/dev/null | grep -v "/ontutunnel-" | grep -q .; then
    echo "CONFLICT: $d is already configured in another nginx file — not touching it." >&2; exit 3
  fi
done
for d in %s; do
  case " %s " in *" ontutunnel-$d.conf "*) ;; *) sudo rm -f "/etc/nginx/conf.d/ontutunnel-$d.conf";; esac
done
`, strings.Join(domains, " "), strings.Join(published, " "), strings.Join(keep, " "))
	b.WriteString(conflictScript(active, published, nginxFile))
	for _, s := range active {
		d := s.NormalizedDomain()
		fmt.Fprintf(&b, "if sudo test -f /etc/letsencrypt/live/%s/fullchain.pem; then\n  %s\nelse\n  %s\nfi\n",
			d, writeFile(nginxFile(d), nginxConf(s, true)), writeFile(nginxFile(d), nginxConf(s, false)))
	}
	b.WriteString(`if ! sudo nginx -t 2>/tmp/ontutunnel-nginx-test; then
  restore; cat /tmp/ontutunnel-nginx-test >&2; echo "nginx test failed — your previous config was kept" >&2; exit 4
fi
sudo systemctl reload nginx
`)
	mail := "--register-unsafely-without-email"
	if email != "" {
		mail = "-m " + email
	}
	for _, s := range active {
		d := s.NormalizedDomain()
		fmt.Fprintf(&b, `if ! sudo test -f /etc/letsencrypt/live/%[1]s/fullchain.pem; then
  command -v certbot >/dev/null || (sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq certbot)
  if sudo certbot certonly --webroot -w /var/www/ontutunnel-acme -d %[1]s --non-interactive --agree-tos %[2]s --deploy-hook "systemctl reload nginx" >/tmp/ontutunnel-certbot 2>&1; then
    %[3]s
    if sudo nginx -t 2>/dev/null; then sudo systemctl reload nginx; echo "CERT-OK %[1]s"; else %[4]s; sudo nginx -t && sudo systemctl reload nginx; fi
  else
    echo "CERT-PENDING %[1]s: $(tail -2 /tmp/ontutunnel-certbot | tr '\n' ' ')"
  fi
fi
`, d, mail, writeFile(nginxFile(d), nginxConf(s, true)), writeFile(nginxFile(d), nginxConf(s, false)))
	}
	return b.String()
}

// uninstallScript removes this computer's sites only. The shared parts
// (OntuTunnel's Caddy, its folders) go only when no other computer still has
// OntuTunnel sites on the server.
func uninstallScript(domains []string) string {
	var ds []string
	for _, d := range domains {
		if validHost.MatchString(d) {
			ds = append(ds, d)
		}
	}
	return `for d in ` + strings.Join(ds, " ") + `; do
  sudo rm -f "/etc/nginx/conf.d/ontutunnel-$d.conf" "/etc/ontutunnel/sites/$d.caddy"
done
if [ -n "$(ls /etc/nginx/conf.d/ontutunnel-*.conf /etc/ontutunnel/sites/*.caddy 2>/dev/null)" ]; then
  echo "OTHERS-REMAIN"
  if systemctl is-active --quiet nginx; then sudo nginx -t 2>/dev/null && sudo systemctl reload nginx; fi
  if systemctl is-active --quiet ontutunnel-caddy; then sudo systemctl restart ontutunnel-caddy; fi
else
  sudo systemctl disable --now ontutunnel-caddy localbridge-caddy 2>/dev/null || true
  sudo rm -f /etc/systemd/system/ontutunnel-caddy.service /etc/systemd/system/localbridge-caddy.service
  sudo systemctl daemon-reload
  if systemctl is-active --quiet nginx; then sudo nginx -t && sudo systemctl reload nginx; fi
  sudo rm -rf /opt/ontutunnel /etc/ontutunnel /var/lib/ontutunnel /var/www/ontutunnel-acme
fi
echo removed`
}
