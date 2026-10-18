package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/subtle"
	"embed"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io/fs"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strings"

	"golang.org/x/crypto/ssh"
)

//go:embed web
var webFiles embed.FS

func (a *App) Handler() http.Handler {
	mux := http.NewServeMux()
	sub, _ := fs.Sub(webFiles, "web")
	mux.Handle("/", http.FileServer(http.FS(sub)))
	mux.HandleFunc("/api/state", a.apiState)
	mux.HandleFunc("/api/action", a.apiAction)
	// a second start of OntuTunnel asks this one to show its window
	mux.HandleFunc("/ui/show", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "POST only", http.StatusMethodNotAllowed)
			return
		}
		if a.ShowUI != nil {
			go a.ShowUI()
		}
		w.WriteHeader(http.StatusNoContent)
	})
	return a.auth(mux)
}

// auth: when other devices may connect, every request needs the access key
// (?key=… once, then a cookie). Loopback is always allowed.
func (a *App) auth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		cfg := a.store.Get()
		host := r.RemoteAddr
		if i := strings.LastIndex(host, ":"); i > 0 {
			host = host[:i]
		}
		local := host == "127.0.0.1" || host == "[::1]"
		if !local {
			if !cfg.Web.AllowLAN {
				http.Error(w, "Forbidden", http.StatusForbidden)
				return
			}
			c, _ := r.Cookie("otkey")
			if keyOK(r.URL.Query().Get("key"), cfg.Web.Key) {
				http.SetCookie(w, &http.Cookie{Name: "otkey", Value: cfg.Web.Key, Path: "/", HttpOnly: true, SameSite: http.SameSiteStrictMode})
			} else if c == nil || !keyOK(c.Value, cfg.Web.Key) {
				http.Error(w, "Open the link with the access key shown in OntuTunnel → Settings.", http.StatusUnauthorized)
				return
			}
		}
		if !sameOriginOK(r) {
			http.Error(w, "Forbidden", http.StatusForbidden)
			return
		}
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("X-Frame-Options", "DENY")
		next.ServeHTTP(w, r)
	})
}

// sameOriginOK stops other websites from using the dashboard API through
// the browser (it can start commands and change servers):
//   - the Host must be "localhost" or an IP address, so a website can't
//     point its own domain at 127.0.0.1 (DNS rebinding);
//   - changes need the X-OntuTunnel header, which a page from another site
//     can't send without the browser asking us first (we never allow it);
//   - an Origin, when sent, must be this dashboard.
func keyOK(got, want string) bool {
	return want != "" && subtle.ConstantTimeCompare([]byte(got), []byte(want)) == 1
}

func sameOriginOK(r *http.Request) bool {
	host := strings.ToLower(r.Host)
	if h, _, err := net.SplitHostPort(host); err == nil {
		host = h
	}
	host = strings.Trim(host, "[]")
	if host != "localhost" && net.ParseIP(host) == nil {
		return false
	}
	if o := r.Header.Get("Origin"); o != "" && o != "null" {
		u, err := url.Parse(o)
		if err != nil || !strings.EqualFold(u.Host, r.Host) {
			return false
		}
	}
	if r.Method != http.MethodGet && r.Method != http.MethodHead && r.Header.Get("X-OntuTunnel") != "1" {
		return false
	}
	return true
}

func sshKeys() []string {
	home, _ := os.UserHomeDir()
	matches, _ := filepath.Glob(filepath.Join(home, ".ssh", "*.pub"))
	var out []string
	for _, m := range matches {
		out = append(out, strings.TrimSuffix(m, ".pub"))
	}
	sort.Strings(out)
	return out
}

func publicKey(keyPath string) string {
	b, err := os.ReadFile(expandHome(keyPath) + ".pub")
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

// SSHKeyInfo: one key pair in ~/.ssh, as shown on the Connection page.
type SSHKeyInfo struct {
	Path      string `json:"path"`
	Name      string `json:"name"`
	Type      string `json:"type"`
	Comment   string `json:"comment"`
	CloudUser string `json:"cloudUser"` // the user Google Cloud creates for it
	PublicKey string `json:"publicKey"`
}

var validUser = regexp.MustCompile(`^[a-z_][a-z0-9_-]{0,31}$`)

func sshKeyInfos() []SSHKeyInfo {
	var out []SSHKeyInfo
	for _, p := range sshKeys() {
		line := publicKey(p)
		f := strings.SplitN(line, " ", 3)
		if len(f) < 2 {
			continue
		}
		k := SSHKeyInfo{Path: p, Name: filepath.Base(p), Type: strings.ToUpper(strings.TrimPrefix(f[0], "ssh-")), PublicKey: line}
		if len(f) == 3 {
			k.Comment = f[2]
			if u := strings.ToLower(strings.SplitN(f[2], "@", 2)[0]); validUser.MatchString(u) {
				k.CloudUser = u
			}
		}
		out = append(out, k)
	}
	return out
}

// createKey makes a new ed25519 key whose comment is the user name: Google
// Cloud creates that user on the VM when the key is added.
func createKey(user string) (string, error) {
	user = strings.ToLower(strings.TrimSpace(user))
	if !validUser.MatchString(user) {
		return "", fmt.Errorf("use small letters, numbers, - or _ (for example: faiyaz)")
	}
	home, _ := os.UserHomeDir()
	dir := filepath.Join(home, ".ssh")
	path := filepath.Join(dir, "ontutunnel_"+user+"_ed25519")
	for n := 2; ; n++ {
		if _, err := os.Stat(path); err != nil {
			break
		}
		path = filepath.Join(dir, fmt.Sprintf("ontutunnel_%s_%d_ed25519", user, n))
	}
	_ = os.MkdirAll(dir, 0o700)
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return "", err
	}
	block, err := ssh.MarshalPrivateKey(priv, user)
	if err != nil {
		return "", err
	}
	if err := os.WriteFile(path, pem.EncodeToMemory(block), 0o600); err != nil {
		return "", err
	}
	sshPub, _ := ssh.NewPublicKey(pub)
	line := strings.TrimSpace(string(ssh.MarshalAuthorizedKey(sshPub))) + " " + user + "\n"
	return path, os.WriteFile(path+".pub", []byte(line), 0o644)
}

func (a *App) apiState(w http.ResponseWriter, _ *http.Request) {
	cfg := a.store.Get()
	cfg.Server.HostKey = ""
	hidden := map[int]bool{}
	for _, p := range cfg.HiddenPorts {
		hidden[p] = true
	}
	published := map[int]bool{}
	type svcOut struct {
		Service
		Status         Status `json:"status"`
		CommandRunning bool   `json:"commandRunning"`
	}
	var services []svcOut
	for _, s := range cfg.Services {
		published[s.LocalPort] = true
		services = append(services, svcOut{s, a.statusOf(s.ID), a.commandRunning(s.ID)})
	}
	a.mu.Lock()
	type portOut struct {
		ListeningPort
		Hidden    bool `json:"hidden"`
		Published bool `json:"published"`
	}
	var ports []portOut
	for _, p := range a.ports {
		ports = append(ports, portOut{p, hidden[p.Port], published[p.Port]})
	}
	wild := map[string]Check{}
	for _, b := range cfg.WildcardBases {
		if c, ok := a.wild[b]; ok {
			wild[b] = c
		} else {
			wild[b] = unknown()
		}
	}
	logs := a.logs
	if len(logs) > 200 {
		logs = logs[len(logs)-200:]
	}
	out := map[string]any{
		"config": cfg, "services": services, "ports": ports, "wildcards": wild,
		"steps": a.steps, "logs": logs, "busy": a.busy, "facts": a.facts, "conn": a.conn,
		"network": a.network, "serverIP": a.serverIP, "syncMessage": a.syncMsg,
	}
	a.mu.Unlock()
	ts, td := a.tunnel.State()
	ps, pd, https := a.proxy.State()
	cs, cd := a.cf.State()
	out["tunnel"] = map[string]any{"state": ts, "detail": td}
	out["proxy"] = map[string]any{"state": ps, "detail": pd, "https": https}
	a.mu.Lock()
	outside := a.outside
	a.mu.Unlock()
	a.mu.Lock()
	out["update"] = a.update
	a.mu.Unlock()
	out["staticChecks"] = map[string]any{"firewall": firewallState(), "outside": outside, "os": runtime.GOOS}
	out["cloudflared"] = map[string]any{"state": cs, "detail": cd, "installed": cfBinary() != "", "loggedIn": cfLoggedIn()}
	out["ready"], out["connected"], out["dnsTarget"] = a.Ready(), a.Connected(), a.DNSTarget()
	out["modeTitle"] = cfg.Mode.Title()
	out["sshKeys"], out["publicKey"] = sshKeys(), publicKey(cfg.Server.KeyPath)
	out["sshKeyInfos"] = sshKeyInfos()
	out["hosts"] = map[string]any{"path": hostsPath(), "entries": hostEntries()}
	out["version"] = Version
	host, _ := os.Hostname()
	out["hostname"] = host
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(out)
}

func (a *App) apiAction(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	var req map[string]json.RawMessage
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error":"bad request"}`, http.StatusBadRequest)
		return
	}
	str := func(k string) string { var s string; _ = json.Unmarshal(req[k], &s); return s }
	num := func(k string) int { var n int; _ = json.Unmarshal(req[k], &n); return n }
	boolean := func(k string) bool { var b bool; _ = json.Unmarshal(req[k], &b); return b }
	reply := func(err error) {
		w.Header().Set("Content-Type", "application/json")
		if err != nil {
			w.WriteHeader(http.StatusBadRequest)
			_ = json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
			return
		}
		_, _ = w.Write([]byte(`{"ok":true}`))
	}

	switch str("action") {
	case "setMode":
		go a.SetMode(Mode(str("mode")))
	case "start":
		go a.StartMode()
	case "stop":
		a.StopAll()
	case "sync":
		go a.SyncCurrent()
	case "refresh":
		go func() { a.refreshNetwork(); a.RefreshAll(); a.CheckWildcards() }()
	case "saveServer":
		var s ServerConfig
		_ = json.Unmarshal(req["server"], &s)
		a.store.Update(func(c *Config) {
			key := c.Server.HostKey
			if s.Host != c.Server.Host {
				key = ""
			}
			c.Server.Host, c.Server.User, c.Server.Port, c.Server.KeyPath, c.Server.Email = strings.TrimSpace(s.Host), strings.TrimSpace(s.User), s.Port, s.KeyPath, s.Email
			c.Server.HostKey = key
		})
	case "forgetHostKey":
		a.store.Update(func(c *Config) { c.Server.HostKey = "" })
	case "createKey":
		p, err := createKey(str("user"))
		if err == nil {
			user := strings.ToLower(strings.TrimSpace(str("user")))
			a.store.Update(func(c *Config) { c.Server.KeyPath, c.Server.User = p, user })
			a.Log("Server", "New SSH key "+filepath.Base(p)+" for user "+user+" — add its public key to the server", false)
		}
		reply(err)
		return
	case "useKey":
		a.store.Update(func(c *Config) {
			c.Server.KeyPath = str("path")
			if c.Server.User == "" {
				c.Server.User = str("user")
			}
		})
	case "setUser":
		a.store.Update(func(c *Config) { c.Server.User = str("user") })
	case "hostsEdit":
		var e HostEdit
		_ = json.Unmarshal(req["edit"], &e)
		reply(a.EditHosts(e))
		return
	case "testConnection":
		go a.TestConnection()
	case "setupRelay":
		go a.SetupRelay()
	case "removeFromServer":
		go func() {
			if err := a.RemoveFromServer(); err != nil {
				a.Log("Server", "Remove failed: "+err.Error(), true)
			}
		}()
	case "allowFirewall":
		reply(a.AllowFirewall())
		return
	case "testOutside":
		go a.TestFromOutside()
	case "saveStatic":
		var s StaticIPConfig
		_ = json.Unmarshal(req["staticIP"], &s)
		if s.IP = strings.TrimSpace(s.IP); s.IP != "" && net.ParseIP(s.IP) == nil {
			reply(fmt.Errorf("%q is not an IP address", s.IP))
			return
		}
		a.store.Update(func(c *Config) { c.StaticIP = s })
	case "setupCloudflare":
		go a.SetupCloudflare()
	case "saveService":
		var s Service
		if err := json.Unmarshal(req["service"], &s); err != nil {
			reply(err)
			return
		}
		s.FrappeSite = strings.TrimSpace(s.FrappeSite)
		if !s.Safe() || s.LocalPort < 1 || s.LocalPort > 65535 || s.SocketPort < 0 || s.SocketPort > 65535 {
			reply(fmt.Errorf("enter a full domain (letters, numbers, - and .), a valid Frappe site name and a port between 1 and 65535"))
			return
		}
		a.SaveService(s)
	case "deleteService":
		a.DeleteService(str("id"))
	case "toggle":
		a.SetEnabled(str("id"), boolean("on"))
	case "startCmd":
		a.StartCommand(str("id"))
	case "stopCmd":
		a.StopCommand(str("id"))
	case "hide", "unhide":
		p := num("port")
		a.store.Update(func(c *Config) {
			var keep []int
			for _, x := range c.HiddenPorts {
				if x != p {
					keep = append(keep, x)
				}
			}
			if str("action") == "hide" {
				keep = append(keep, p)
			}
			c.HiddenPorts = keep
		})
	case "addWildcard":
		a.AddWildcard(str("base"))
	case "removeWildcard":
		a.RemoveWildcard(str("base"))
	case "checkWildcards":
		go a.CheckWildcards()
	case "settings":
		a.store.Update(func(c *Config) {
			c.AutoConnect = boolean("autoConnect")
			c.KeepAwake = boolean("keepAwake")
			c.LocalHostsOff = !boolean("localHosts")
			if c.Web.AllowLAN != boolean("allowLAN") {
				c.Web.AllowLAN = boolean("allowLAN")
				a.Log("Settings", "Restart OntuTunnel to apply the browser access change.", false)
			}
		})
		a.applyKeepAwake()
		a.hostsMu.Lock()
		a.hostsDeclined = ""
		a.hostsMu.Unlock()
		go a.syncHosts()
	default:
		reply(fmt.Errorf("unknown action"))
		return
	}
	reply(nil)
}
