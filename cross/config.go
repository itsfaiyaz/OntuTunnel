package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
)

// Mode is how visitors reach this computer.
type Mode string

const (
	ModeRelay      Mode = "relay"      // own server, SSH reverse tunnel
	ModeStaticIP   Mode = "staticIP"   // static public IP, serve 80/443 here
	ModeCloudflare Mode = "cloudflare" // Cloudflare Tunnel
)

func (m Mode) Title() string {
	switch m {
	case ModeStaticIP:
		return "My static IP"
	case ModeCloudflare:
		return "Cloudflare Tunnel"
	default:
		return "My server (SSH)"
	}
}

type ServerConfig struct {
	Host    string `json:"host"`
	User    string `json:"user"`
	Port    int    `json:"port"`
	KeyPath string `json:"keyPath"`
	Email   string `json:"email"`
	// Trust-on-first-use host key (base64 of the wire format).
	HostKey string `json:"hostKey,omitempty"`
}

func (s ServerConfig) Complete() bool {
	return strings.TrimSpace(s.Host) != "" && strings.TrimSpace(s.User) != ""
}

type StaticIPConfig struct {
	IP              string `json:"ip"`
	HTTPSEnabled    bool   `json:"httpsEnabled"`
	RedirectToHTTPS bool   `json:"redirectToHTTPS"`
	Email           string `json:"email"`
}

type CloudflareConfig struct {
	TunnelName string   `json:"tunnelName"`
	TunnelID   string   `json:"tunnelID"`
	ProxyPort  int      `json:"proxyPort"`
	Routed     []string `json:"routed"`
}

type WebConfig struct {
	Port     int    `json:"port"`
	AllowLAN bool   `json:"allowLAN"`
	Key      string `json:"key"`
}

type Service struct {
	ID               string `json:"id"`
	Name             string `json:"name"`
	Domain           string `json:"domain"`
	LocalPort        int    `json:"localPort"`
	FrappeSite       string `json:"frappeSite"`
	SocketPort       int    `json:"socketPort"`
	Enabled          bool   `json:"enabled"`
	StartCommand     string `json:"startCommand"`
	WorkingDirectory string `json:"workingDirectory"`
	AutoStart        bool   `json:"autoStart"`
	KeepAlive        bool   `json:"keepAlive"`
	RemotePort       int    `json:"remotePort"`
	RemoteSocketPort int    `json:"remoteSocketPort"`
}

func (s Service) NormalizedDomain() string { return strings.ToLower(strings.TrimSpace(s.Domain)) }

var validSite = regexp.MustCompile(`^[A-Za-z0-9._-]{1,100}$`)

// Safe: domain and Frappe site contain only characters that are harmless in
// the nginx/Caddy files and shell scripts OntuTunnel sends to the server.
func (s Service) Safe() bool {
	return validHost.MatchString(s.NormalizedDomain()) &&
		(s.FrappeSite == "" || validSite.MatchString(s.FrappeSite))
}

type Config struct {
	Mode        Mode             `json:"mode"`
	Server      ServerConfig     `json:"server"`
	ServerMode  string           `json:"serverMode,omitempty"` // "caddy" | "nginx" once set up
	StaticIP    StaticIPConfig   `json:"staticIP"`
	Cloudflare  CloudflareConfig `json:"cloudflare"`
	Services    []Service        `json:"services"`
	AutoConnect bool             `json:"autoConnect"`
	KeepAwake   bool             `json:"keepAwake"` // stop idle sleep while running
	// Static IP mode adds the sites to this computer's hosts file unless off.
	LocalHostsOff bool     `json:"localHostsOff"`
	HiddenPorts   []int    `json:"hiddenPorts"`
	WildcardBases []string `json:"wildcardBases"`
	// Domains this installation has published on the server — cleanup only
	// ever removes these, never files written by another computer.
	Published []string  `json:"published"`
	Web       WebConfig `json:"web"`
}

func defaultConfig() Config {
	home, _ := os.UserHomeDir()
	return Config{
		Mode:        ModeRelay,
		Server:      ServerConfig{Port: 22, KeyPath: filepath.Join(home, ".ssh", "id_ed25519")},
		StaticIP:    StaticIPConfig{HTTPSEnabled: true, RedirectToHTTPS: true},
		AutoConnect: true,
		Web:         WebConfig{Port: 7777},
	}
}

// Store keeps the config in memory and on disk.
type Store struct {
	mu   sync.Mutex
	path string
	cfg  Config
}

// DataDir: %APPDATA%\OntuTunnel on Windows, ~/.config/ontutunnel on Linux,
// ~/Library/Application Support/OntuTunnel on macOS.
func DataDir() string {
	if custom := os.Getenv("ONTUTUNNEL_HOME"); custom != "" {
		_ = os.MkdirAll(custom, 0o700)
		return custom
	}
	base, err := os.UserConfigDir()
	if err != nil {
		home, _ := os.UserHomeDir()
		base = filepath.Join(home, ".config")
	}
	name := "OntuTunnel"
	if strings.HasSuffix(base, ".config") {
		name = "ontutunnel"
	}
	dir := filepath.Join(base, name)
	_ = os.MkdirAll(dir, 0o700)
	return dir
}

func OpenStore() *Store {
	s := &Store{path: filepath.Join(DataDir(), "config.json"), cfg: defaultConfig()}
	if data, err := os.ReadFile(s.path); err == nil {
		_ = json.Unmarshal(data, &s.cfg)
	}
	if s.cfg.Web.Port == 0 {
		s.cfg.Web.Port = 7777
	}
	if s.cfg.Server.Port == 0 {
		s.cfg.Server.Port = 22
	}
	if s.cfg.Mode == "" {
		s.cfg.Mode = ModeRelay
	}
	return s
}

func (s *Store) Get() Config {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.cfg
}

// Update changes the config and saves it.
func (s *Store) Update(fn func(*Config)) Config {
	s.mu.Lock()
	defer s.mu.Unlock()
	fn(&s.cfg)
	if data, err := json.MarshalIndent(s.cfg, "", "  "); err == nil {
		_ = os.WriteFile(s.path, data, 0o600)
	}
	return s.cfg
}
