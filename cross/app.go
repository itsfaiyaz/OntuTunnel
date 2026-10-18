package main

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"
)

type Status struct {
	Port      string    `json:"port"` // open | closed | unknown
	Process   string    `json:"process"`
	DNSA      []string  `json:"dnsA"`
	DNS       Check     `json:"dns"`
	Live      Check     `json:"live"`
	CheckedAt time.Time `json:"checkedAt"`
}

type Step struct {
	Title  string `json:"title"`
	State  string `json:"state"`
	Detail string `json:"detail"`
}

type LogLine struct {
	Time   string `json:"time"`
	Source string `json:"source"`
	Text   string `json:"text"`
	Error  bool   `json:"error"`
}

// App is the whole OntuTunnel engine; the browser UI talks to it via JSON.
type App struct {
	hostsMu       sync.Mutex
	hostsDeclined string // domain list the user said "No" to (don't ask again)
	store         *Store
	tunnel        *Tunnel
	proxy         *Proxy
	cf            *CFRunner
	mu            sync.Mutex
	status        map[string]*Status
	runners       map[string]*Runner
	blocked       map[string]bool
	logs          []LogLine
	steps         []Step
	busy          bool
	pending       bool
	network       Network
	ports         []ListeningPort
	facts         *Facts
	conn          Check
	serverIP      string
	wild          map[string]Check
	syncMsg       string
	logFile       *os.File
}

func NewApp(store *Store) *App {
	a := &App{store: store, status: map[string]*Status{}, runners: map[string]*Runner{}, blocked: map[string]bool{},
		wild: map[string]Check{}, conn: unknown()}
	if f, err := os.OpenFile(DataDir()+string(os.PathSeparator)+"ontutunnel.log", os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600); err == nil {
		a.logFile = f
	}
	a.tunnel = NewTunnel(func(s string, e bool) { a.Log("Tunnel", s, e) })
	a.proxy = NewProxy(func(s string, e bool) { a.Log("Proxy", s, e) })
	a.cf = NewCFRunner(func(s string, e bool) { a.Log("Cloudflare", s, e) })
	return a
}

func (a *App) Log(source, text string, isErr bool) {
	l := LogLine{Time: time.Now().Format("15:04:05"), Source: source, Text: text, Error: isErr}
	a.mu.Lock()
	a.logs = append(a.logs, l)
	if len(a.logs) > 2000 {
		a.logs = a.logs[len(a.logs)-2000:]
	}
	a.mu.Unlock()
	if a.logFile != nil {
		mark := ""
		if isErr {
			mark = " ERROR"
		}
		fmt.Fprintf(a.logFile, "%s [%s]%s %s\n", time.Now().Format(time.RFC3339), source, mark, text)
	}
}

func newID() string {
	b := make([]byte, 8)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// ---------- lifecycle ----------

func (a *App) Start() {
	cfg := a.store.Get()
	for _, s := range cfg.Services {
		if s.AutoStart && s.StartCommand != "" {
			a.StartCommand(s.ID)
		}
	}
	a.applyKeepAwake()
	if cfg.AutoConnect {
		a.StartMode()
	}
	go func() {
		a.refreshNetwork()
		a.RefreshAll()
		a.CheckWildcards()
		portTick := time.NewTicker(5 * time.Second)
		netTick := time.NewTicker(60 * time.Second)
		for {
			select {
			case <-portTick.C:
				a.refreshPorts()
			case <-netTick.C:
				a.refreshNetwork()
				a.refreshOnline()
			}
		}
	}()
}

func (a *App) Ready() bool {
	cfg := a.store.Get()
	switch cfg.Mode {
	case ModeStaticIP:
		return true
	case ModeCloudflare:
		return cfg.Cloudflare.TunnelID != ""
	default:
		return cfg.ServerMode != "" && cfg.Server.Complete()
	}
}

func (a *App) Connected() bool {
	switch a.store.Get().Mode {
	case ModeStaticIP:
		s, _, _ := a.proxy.State()
		return s == "listening"
	case ModeCloudflare:
		s, _ := a.cf.State()
		return s == "connected"
	default:
		s, _ := a.tunnel.State()
		return s == "connected"
	}
}

func (a *App) DNSTarget() string {
	cfg := a.store.Get()
	switch cfg.Mode {
	case ModeStaticIP:
		if strings.TrimSpace(cfg.StaticIP.IP) != "" {
			return strings.TrimSpace(cfg.StaticIP.IP)
		}
		a.mu.Lock()
		defer a.mu.Unlock()
		return a.network.PublicIPv4
	case ModeCloudflare:
		return ""
	default:
		a.mu.Lock()
		defer a.mu.Unlock()
		return a.serverIP
	}
}

func (a *App) StopAll() {
	a.tunnel.Stop()
	a.proxy.Stop()
	a.cf.Stop()
}

func (a *App) SetMode(m Mode) {
	if a.store.Get().Mode == m {
		return
	}
	a.StopAll()
	a.store.Update(func(c *Config) { c.Mode = m })
	a.Log("Connection", "Switched to "+m.Title(), false)
	a.StartMode()
	go a.syncHosts() // removes the hosts entries when leaving static IP mode
}

func (a *App) StartMode() {
	cfg := a.store.Get()
	switch cfg.Mode {
	case ModeRelay:
		if a.Ready() {
			a.ConnectTunnel()
			go a.SyncRelay()
		}
	case ModeStaticIP:
		a.proxy.SetRoutes(cfg.Services)
		a.proxy.StartStatic(cfg.StaticIP)
		go a.syncHosts()
	case ModeCloudflare:
		if a.Ready() {
			a.startCloudflare()
		}
	}
}

func (a *App) SyncCurrent() {
	cfg := a.store.Get()
	switch cfg.Mode {
	case ModeRelay:
		a.SyncRelay()
	case ModeStaticIP:
		a.proxy.SetRoutes(cfg.Services)
		a.syncHosts()
	case ModeCloudflare:
		a.SyncCloudflare()
	}
	time.Sleep(3 * time.Second)
	a.refreshOnline()
}

// ---------- relay (own server over SSH) ----------

func (a *App) TestConnection() {
	a.mu.Lock()
	a.conn = Check{State: "checking", Text: "Checking…"}
	a.mu.Unlock()
	f, err := Probe(a.store)
	a.mu.Lock()
	defer a.mu.Unlock()
	if err != nil {
		a.conn = fail(err.Error())
		return
	}
	a.facts = &f
	a.serverIP = ResolveHost(a.store.Get().Server.Host)
	if f.Sudo {
		a.conn = ok()
	} else {
		a.conn = warn("Connected, but this user can't use sudo without a password.")
	}
}

func (a *App) setStep(i int, state, detail string) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if i < len(a.steps) {
		a.steps[i].State, a.steps[i].Detail = state, detail
	}
}

func (a *App) initSteps(titles ...string) {
	a.mu.Lock()
	a.steps = nil
	for _, t := range titles {
		a.steps = append(a.steps, Step{Title: t, State: "unknown"})
	}
	a.mu.Unlock()
}

func (a *App) setBusy(b bool) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	if b && a.busy {
		return false
	}
	a.busy = b
	return true
}

func (a *App) SetupRelay() {
	if !a.setBusy(true) {
		return
	}
	defer a.setBusy(false)
	a.initSteps("Connect over SSH", "Admin rights (sudo)", "Ports 80/443 on the server", "SSH tunnels allowed",
		"Web server for your sites", "Pick free tunnel ports", "Publish your sites", "Start the tunnel", "Check from the internet")
	a.setStep(0, "checking", "")
	f, err := Probe(a.store)
	if err != nil {
		a.setStep(0, "failed", err.Error())
		a.mu.Lock()
		a.conn = fail(err.Error())
		a.mu.Unlock()
		return
	}
	a.mu.Lock()
	a.facts, a.conn = &f, ok()
	a.serverIP = ResolveHost(a.store.Get().Server.Host)
	a.mu.Unlock()
	a.setStep(0, "ok", f.OS+" · "+f.Arch)
	if !f.Sudo {
		a.setStep(1, "failed", "User needs passwordless sudo (add: USER ALL=(ALL) NOPASSWD:ALL with visudo).")
		return
	}
	a.setStep(1, "ok", "")
	mode, err := f.Plan()
	if err != nil {
		a.setStep(2, "failed", err.Error())
		return
	}
	if mode == "caddy" {
		a.setStep(2, "ok", "Free — OntuTunnel will run its own Caddy")
	} else {
		a.setStep(2, "ok", "nginx already uses them — only new files next to your sites")
	}
	if f.Forwarding == "no" {
		a.setStep(3, "failed", "AllowTcpForwarding is off in /etc/ssh/sshd_config — set it to yes and restart ssh.")
		return
	}
	a.setStep(3, "ok", "")
	a.setStep(4, "checking", "")
	if mode == "caddy" {
		out, errOut, err := Run(a.store, installCaddyScript(), 5*time.Minute)
		if err != nil {
			a.setStep(4, "failed", "Installing Caddy failed: "+strings.TrimSpace(errOut+out))
			return
		}
		a.setStep(4, "ok", "Own Caddy at /opt/ontutunnel (service ontutunnel-caddy)")
	} else {
		a.setStep(4, "ok", "Existing nginx — new files only: /etc/nginx/conf.d/ontutunnel-*.conf")
	}
	a.store.Update(func(c *Config) { c.ServerMode = mode })
	a.assignPorts(f.UsedPorts)
	var parts []string
	for _, s := range a.store.Get().Services {
		if s.Enabled {
			parts = append(parts, fmt.Sprintf("%s → 127.0.0.1:%d", s.NormalizedDomain(), s.RemotePort))
		}
	}
	a.setStep(5, "ok", strings.Join(parts, ", "))
	a.setStep(6, "checking", "")
	okApply, msg := a.applyConfig()
	if !okApply {
		a.setStep(6, "failed", msg)
		return
	}
	if msg != "" {
		a.setStep(6, "warning", msg)
	} else {
		a.setStep(6, "ok", "")
	}
	a.setStep(7, "checking", "")
	a.ConnectTunnel()
	for i := 0; i < 15 && !a.Connected(); i++ {
		time.Sleep(time.Second)
	}
	if a.Connected() {
		a.setStep(7, "ok", "")
	} else {
		_, d := a.tunnel.State()
		a.setStep(7, "failed", d)
	}
	a.setStep(8, "checking", "")
	a.refreshOnline()
	all, any := true, false
	for _, s := range a.store.Get().Services {
		if s.Enabled {
			any = true
			if st := a.statusOf(s.ID); !st.Live.OK {
				all = false
			}
		}
	}
	switch {
	case !any:
		a.setStep(8, "warning", "Add a service to publish your first site.")
	case all:
		a.setStep(8, "ok", "Your sites answer over HTTPS")
	default:
		a.setStep(8, "warning", "Not live yet — usually DNS still points elsewhere or the certificate is being issued.")
	}
}

func (a *App) assignPorts(used []int) {
	taken := map[int]bool{}
	for _, p := range used {
		taken[p] = true
	}
	a.store.Update(func(c *Config) {
		for _, s := range c.Services {
			taken[s.RemotePort], taken[s.RemoteSocketPort] = true, true
		}
		usedSet := map[int]bool{}
		for _, p := range used {
			usedSet[p] = true
		}
		for i := range c.Services {
			s := &c.Services[i]
			if s.RemotePort == 0 || usedSet[s.RemotePort] {
				s.RemotePort = freePort(taken)
				taken[s.RemotePort] = true
			}
			if s.SocketPort > 0 {
				if s.RemoteSocketPort == 0 || usedSet[s.RemoteSocketPort] {
					s.RemoteSocketPort = freePort(taken)
					taken[s.RemoteSocketPort] = true
				}
			} else {
				s.RemoteSocketPort = 0
			}
		}
	})
}

func (a *App) applyConfig() (bool, string) {
	cfg := a.store.Get()
	script := applyNginxScript(cfg.Services, cfg.Server.Email, cfg.Published)
	if cfg.ServerMode == "caddy" {
		script = applyCaddyScript(cfg.Services, cfg.Server.Email)
	}
	out, errOut, err := Run(a.store, script, 4*time.Minute)
	pending := false
	for _, line := range strings.Split(out, "\n") {
		if strings.HasPrefix(line, "CERT-") {
			pending = pending || strings.HasPrefix(line, "CERT-PENDING")
			a.Log("Server", line, strings.HasPrefix(line, "CERT-PENDING"))
		}
	}
	if err != nil {
		msg := strings.TrimSpace(errOut)
		if msg == "" {
			msg = err.Error()
		}
		a.Log("Server", "Publishing failed: "+msg, true)
		return false, msg
	}
	n := 0
	var pub []string
	for _, s := range activeServices(cfg.Services) {
		n++
		pub = append(pub, s.NormalizedDomain())
	}
	a.store.Update(func(c *Config) { c.Published = pub })
	a.Log("Server", fmt.Sprintf("Published %d site(s) (%s)", n, cfg.ServerMode), false)
	if pending {
		return true, "HTTPS pending for some domains (DNS must point to the server first) — Sync again after fixing DNS."
	}
	return true, ""
}

func (a *App) SyncRelay() {
	if !a.Ready() {
		return
	}
	if !a.setBusy(true) {
		a.mu.Lock()
		a.pending = true
		a.mu.Unlock()
		return
	}
	needPorts := false
	for _, s := range a.store.Get().Services {
		if s.Enabled && (s.RemotePort == 0 || (s.SocketPort > 0 && s.RemoteSocketPort == 0)) {
			needPorts = true
		}
	}
	if needPorts {
		if f, err := Probe(a.store); err == nil {
			a.assignPorts(f.UsedPorts)
		}
	}
	okApply, msg := a.applyConfig()
	if okApply {
		a.ConnectTunnel()
	}
	a.mu.Lock()
	if okApply && msg == "" {
		a.syncMsg = "Synced at " + time.Now().Format("15:04") + "."
	} else {
		a.syncMsg = msg
	}
	again := a.pending
	a.pending = false
	a.mu.Unlock()
	a.setBusy(false)
	if again {
		a.SyncRelay()
	}
}

func (a *App) ConnectTunnel() {
	var fw []Forward
	for _, s := range a.store.Get().Services {
		if s.Enabled && s.RemotePort > 0 {
			fw = append(fw, Forward{s.RemotePort, s.LocalPort})
			if s.SocketPort > 0 && s.RemoteSocketPort > 0 {
				fw = append(fw, Forward{s.RemoteSocketPort, s.SocketPort})
			}
		}
	}
	a.tunnel.Start(a.store, fw)
}

func (a *App) RemoveFromServer() error {
	a.tunnel.Stop()
	_, errOut, err := Run(a.store, uninstallScript, 2*time.Minute)
	if err != nil {
		return fmt.Errorf("%v %s", err, errOut)
	}
	a.store.Update(func(c *Config) {
		c.ServerMode = ""
		for i := range c.Services {
			c.Services[i].RemotePort, c.Services[i].RemoteSocketPort = 0, 0
		}
	})
	a.Log("Server", "Removed everything OntuTunnel had added to the server.", false)
	return nil
}

// ---------- Cloudflare ----------

func (a *App) SetupCloudflare() {
	if !a.setBusy(true) {
		return
	}
	defer a.setBusy(false)
	a.initSteps("Install cloudflared", "Log in to Cloudflare (browser, once)", "Create the tunnel",
		"Local proxy for your sites", "DNS records in Cloudflare", "Start the tunnel", "Check from the internet")
	a.setStep(0, "checking", "")
	bin, err := InstallCloudflared()
	if err != nil {
		a.setStep(0, "failed", err.Error())
		return
	}
	a.setStep(0, "ok", bin)
	if !cfLoggedIn() {
		a.setStep(1, "checking", "A Cloudflare page opened in your browser — choose your domain there and click Authorize.")
		out, _ := CloudflareLogin(bin)
		if !cfLoggedIn() {
			a.setStep(1, "failed", "Login not finished: "+lastLines(out, 3))
			return
		}
	}
	a.setStep(1, "ok", "Logged in")
	a.setStep(2, "checking", "")
	cfg := a.store.Update(func(c *Config) {
		if c.Cloudflare.TunnelName == "" {
			h, _ := os.Hostname()
			c.Cloudflare.TunnelName = "ontutunnel-" + strings.ToLower(strings.ReplaceAll(h, ".", "-"))
		}
		if c.Cloudflare.ProxyPort == 0 {
			c.Cloudflare.ProxyPort = 41000 + int(time.Now().UnixNano()%7999)
		}
	})
	id, err := CloudflareEnsureTunnel(bin, cfg.Cloudflare.TunnelName)
	if err != nil {
		a.setStep(2, "failed", err.Error())
		return
	}
	cfg = a.store.Update(func(c *Config) { c.Cloudflare.TunnelID = id })
	a.setStep(2, "ok", cfg.Cloudflare.TunnelName+" · "+id)
	if err := CloudflareWriteConfig(id, cfg.Cloudflare.ProxyPort); err != nil {
		a.setStep(3, "failed", err.Error())
		return
	}
	a.proxy.SetRoutes(cfg.Services)
	a.proxy.StartLoopback(cfg.Cloudflare.ProxyPort)
	a.setStep(3, "ok", fmt.Sprintf("127.0.0.1:%d — only cloudflared on this computer can reach it", cfg.Cloudflare.ProxyPort))
	a.setStep(4, "checking", "")
	errs := a.routeCloudflare(bin)
	if len(errs) > 0 {
		a.setStep(4, "warning", strings.Join(errs, "; "))
	} else {
		a.setStep(4, "ok", strings.Join(a.store.Get().Cloudflare.Routed, ", "))
	}
	a.setStep(5, "checking", "")
	a.cf.Start(bin)
	for i := 0; i < 20 && !a.Connected(); i++ {
		time.Sleep(time.Second)
	}
	if a.Connected() {
		a.setStep(5, "ok", "")
	} else {
		_, d := a.cf.State()
		a.setStep(5, "warning", "Still connecting… "+d)
	}
	a.setStep(6, "checking", "")
	time.Sleep(3 * time.Second)
	a.refreshOnline()
	a.setStep(6, "ok", "Press Refresh on the Dashboard if a site isn't green yet — DNS can take a minute.")
}

func (a *App) routeCloudflare(bin string) []string {
	var errs []string
	cfg := a.store.Get()
	routed := map[string]bool{}
	for _, d := range cfg.Cloudflare.Routed {
		routed[d] = true
	}
	for _, s := range cfg.Services {
		d := s.NormalizedDomain()
		if !s.Enabled || !strings.Contains(d, ".") || routed[d] {
			continue
		}
		if err := CloudflareRouteDNS(bin, cfg.Cloudflare.TunnelID, d); err != nil {
			errs = append(errs, err.Error())
			a.Log("Cloudflare", err.Error(), true)
		} else {
			a.store.Update(func(c *Config) { c.Cloudflare.Routed = append(c.Cloudflare.Routed, d) })
			a.Log("Cloudflare", "DNS: "+d+" → tunnel", false)
		}
	}
	return errs
}

func (a *App) startCloudflare() {
	bin := cfBinary()
	if bin == "" {
		return
	}
	cfg := a.store.Get()
	_ = CloudflareWriteConfig(cfg.Cloudflare.TunnelID, cfg.Cloudflare.ProxyPort)
	a.proxy.SetRoutes(cfg.Services)
	a.proxy.StartLoopback(cfg.Cloudflare.ProxyPort)
	a.cf.Start(bin)
}

func (a *App) SyncCloudflare() {
	bin := cfBinary()
	if bin == "" || !a.Ready() {
		return
	}
	a.proxy.SetRoutes(a.store.Get().Services)
	errs := a.routeCloudflare(bin)
	a.mu.Lock()
	if len(errs) == 0 {
		a.syncMsg = "Synced at " + time.Now().Format("15:04") + "."
	} else {
		a.syncMsg = strings.Join(errs, "; ")
	}
	a.mu.Unlock()
}

// ---------- services ----------

func (a *App) SaveService(s Service) {
	s.Domain = s.NormalizedDomain()
	a.store.Update(func(c *Config) {
		for i := range c.Services {
			if c.Services[i].ID == s.ID {
				if c.Services[i].SocketPort != s.SocketPort {
					s.RemoteSocketPort = 0
				}
				s.RemotePort = c.Services[i].RemotePort
				c.Services[i] = s
				return
			}
		}
		if s.ID == "" {
			s.ID = newID()
		}
		c.Services = append(c.Services, s)
	})
	go a.SyncCurrent()
}

func (a *App) DeleteService(id string) {
	a.StopCommand(id)
	a.store.Update(func(c *Config) {
		for i := range c.Services {
			if c.Services[i].ID == id {
				c.Services = append(c.Services[:i], c.Services[i+1:]...)
				return
			}
		}
	})
	a.mu.Lock()
	delete(a.status, id)
	a.mu.Unlock()
	go a.SyncCurrent()
}

func (a *App) SetEnabled(id string, on bool) {
	for _, s := range a.store.Get().Services {
		if s.ID == id {
			s.Enabled = on
			a.SaveService(s)
			return
		}
	}
}

func (a *App) service(id string) (Service, bool) {
	for _, s := range a.store.Get().Services {
		if s.ID == id {
			return s, true
		}
	}
	return Service{}, false
}

func (a *App) StartCommand(id string) {
	s, found := a.service(id)
	if !found || s.StartCommand == "" {
		return
	}
	a.mu.Lock()
	r := a.runners[id]
	if r == nil {
		r = &Runner{}
		a.runners[id] = r
	}
	delete(a.blocked, id)
	a.mu.Unlock()
	err := r.Start(s, func(line string, e bool) { a.Log(s.Name, line, e) }, func(requested bool) {
		a.mu.Lock()
		blocked := a.blocked[id]
		a.mu.Unlock()
		cur, still := a.service(id)
		if !requested && still && cur.KeepAlive && !blocked {
			a.Log(s.Name, "Exited — keep alive: restarting in 3 s", true)
			time.AfterFunc(3*time.Second, func() { a.StartCommand(id) })
		} else if !requested {
			a.Log(s.Name, "Exited", true)
		}
	})
	if err != nil {
		a.Log(s.Name, "Could not start: "+err.Error(), true)
	} else {
		a.Log(s.Name, "$ "+s.StartCommand, false)
	}
}

func (a *App) StopCommand(id string) {
	a.mu.Lock()
	a.blocked[id] = true
	r := a.runners[id]
	a.mu.Unlock()
	if r != nil {
		r.Stop()
	}
}

func (a *App) commandRunning(id string) bool {
	a.mu.Lock()
	r := a.runners[id]
	a.mu.Unlock()
	return r != nil && r.Running()
}

// ---------- wildcard domains ----------

func (a *App) AddWildcard(base string) {
	base = strings.TrimPrefix(strings.ToLower(strings.TrimSpace(base)), "*.")
	if !strings.Contains(base, ".") {
		return
	}
	a.store.Update(func(c *Config) {
		for _, b := range c.WildcardBases {
			if b == base {
				return
			}
		}
		c.WildcardBases = append(c.WildcardBases, base)
	})
	go a.CheckWildcard(base)
}

func (a *App) RemoveWildcard(base string) {
	a.store.Update(func(c *Config) {
		for i, b := range c.WildcardBases {
			if b == base {
				c.WildcardBases = append(c.WildcardBases[:i], c.WildcardBases[i+1:]...)
				return
			}
		}
	})
}

func (a *App) CheckWildcard(base string) {
	probe := fmt.Sprintf("ot-check-%d.%s", time.Now().UnixNano()%1000000, base)
	ips := LookupA(probe)
	target := a.DNSTarget()
	var c Check
	switch {
	case a.store.Get().Mode == ModeCloudflare:
		c = ok()
	case len(ips) == 0:
		c = fail("No *." + base + " record yet")
	case target != "" && contains(ips, target):
		c = ok()
	default:
		c = warn(fmt.Sprintf("*.%s points to %s, not %s", base, strings.Join(ips, ", "), target))
	}
	a.mu.Lock()
	a.wild[base] = c
	a.mu.Unlock()
}

func (a *App) CheckWildcards() {
	for _, b := range a.store.Get().WildcardBases {
		a.CheckWildcard(b)
	}
}

func contains(list []string, v string) bool {
	for _, x := range list {
		if x == v {
			return true
		}
	}
	return false
}

// ---------- checks ----------

func (a *App) statusOf(id string) Status {
	a.mu.Lock()
	defer a.mu.Unlock()
	if st := a.status[id]; st != nil {
		return *st
	}
	return Status{Port: "unknown", DNS: unknown(), Live: unknown()}
}

func (a *App) updateStatus(id string, fn func(*Status)) {
	a.mu.Lock()
	defer a.mu.Unlock()
	st := a.status[id]
	if st == nil {
		st = &Status{Port: "unknown", DNS: unknown(), Live: unknown()}
		a.status[id] = st
	}
	fn(st)
}

func (a *App) refreshNetwork() {
	n := GetNetwork()
	p := ScanPorts()
	ip := ""
	if h := a.store.Get().Server.Host; h != "" {
		ip = ResolveHost(h)
	}
	a.mu.Lock()
	a.network, a.ports = n, p
	if ip != "" {
		a.serverIP = ip
	}
	a.mu.Unlock()
}

func (a *App) refreshPorts() {
	for _, s := range a.store.Get().Services {
		open := PortOpen(s.LocalPort)
		a.updateStatus(s.ID, func(st *Status) {
			if open {
				st.Port = "open"
			} else {
				st.Port = "closed"
			}
		})
	}
	p := ScanPorts()
	a.mu.Lock()
	a.ports = p
	a.mu.Unlock()
}

func (a *App) refreshOnline() {
	cfg := a.store.Get()
	target := a.DNSTarget()
	var wg sync.WaitGroup
	for _, s := range cfg.Services {
		if !s.Enabled {
			continue
		}
		wg.Add(1)
		go func(s Service) {
			defer wg.Done()
			d := s.NormalizedDomain()
			ips := LookupA(d)
			var dns Check
			switch {
			case cfg.Mode == ModeCloudflare:
				if contains(cfg.Cloudflare.Routed, d) {
					dns = ok()
				} else {
					dns = warn("Not routed yet — click Sync")
				}
			case len(ips) == 0:
				dns = fail("No A record")
			case target != "" && len(ips) == 1 && ips[0] == target:
				dns = ok()
			default:
				dns = warn("Points to " + strings.Join(ips, ", "))
			}
			live := unknown()
			if a.Ready() {
				live = LiveCheck(d)
				if cfg.Mode == ModeStaticIP && live.State != "ok" {
					// Home routers often can't reach their own public IP from
					// inside; test this computer directly instead.
					switch here := liveCheckAt(d, "127.0.0.1"); {
					case here.State == "ok":
						live = warn("Works on this computer · from outside, check on a phone with mobile data")
					case strings.Contains(here.Text, "certificate"):
						live = warn("HTTPS certificate not ready · router must forward ports 80 and 443 to this computer")
					}
				}
			}
			a.updateStatus(s.ID, func(st *Status) {
				st.DNSA, st.DNS, st.Live, st.CheckedAt = ips, dns, live, time.Now()
			})
		}(s)
	}
	wg.Wait()
}

func (a *App) RefreshAll() {
	a.refreshPorts()
	a.refreshOnline()
}

func lastLines(s string, n int) string {
	lines := strings.Split(strings.TrimSpace(s), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, " ")
}
