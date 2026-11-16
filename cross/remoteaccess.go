package main

import (
	"fmt"
	"net"
	"strings"
	"time"
)

// "My server (SSH)" → Remote access: ports of this computer (SSH, Remote
// Desktop …) reachable from anywhere at the server's fixed public IP, e.g.
// 34.47.187.74:2201 → this computer's port 22. The SSH tunnel brings each port
// to a loopback port on the server; for every public port OntuTunnel adds two
// systemd units of its own (ontutunnel-tcp-<port>.socket / .service) that pass
// connections on to it. Nothing else on the server is changed.

func remotePortsScript(ports []RemotePort, published []int) string {
	var active []RemotePort
	for _, p := range ports {
		if p.Enabled && p.TunnelPort > 0 && p.PublicPort > 0 && p.PublicPort <= 65535 {
			active = append(active, p)
		}
	}
	isActive := func(pub int) bool {
		for _, p := range active {
			if p.PublicPort == pub {
				return true
			}
		}
		return false
	}
	var b strings.Builder
	b.WriteString(`set -e
P=$(command -v systemd-socket-proxyd || ls /lib/systemd/systemd-socket-proxyd /usr/lib/systemd/systemd-socket-proxyd 2>/dev/null | head -1)
[ -n "$P" ] || { echo "This server has no systemd-socket-proxyd (it needs systemd)." >&2; exit 5; }
U=/etc/systemd/system
`)
	for _, p := range published {
		if !isActive(p) {
			fmt.Fprintf(&b, `sudo systemctl disable --now ontutunnel-tcp-%[1]d.socket >/dev/null 2>&1 || true
sudo systemctl stop ontutunnel-tcp-%[1]d.service >/dev/null 2>&1 || true
sudo rm -f $U/ontutunnel-tcp-%[1]d.socket $U/ontutunnel-tcp-%[1]d.service
`, p)
		}
	}
	// a port another computer (or another program) already uses is refused
	for _, p := range active {
		if intsContain(published, p.PublicPort) {
			continue
		}
		fmt.Fprintf(&b, `if [ -e $U/ontutunnel-tcp-%[1]d.service ]; then
  if ! grep -q "127.0.0.1:%[2]d$" $U/ontutunnel-tcp-%[1]d.service; then echo "CONFLICT: Port %[1]d is already used by another computer with OntuTunnel. Choose another port." >&2; exit 3; fi
elif ss -tlnH | awk '{print $4}' | grep -qE '[:.]%[1]d$'; then
  echo "CONFLICT: Port %[1]d is already used on the server by another program. Choose another port." >&2; exit 3
fi
`, p.PublicPort, p.TunnelPort)
	}
	for _, p := range active {
		fmt.Fprintf(&b, `sudo tee $U/ontutunnel-tcp-%[1]d.socket >/dev/null <<UNIT
[Unit]
Description=OntuTunnel remote access: public port %[1]d
[Socket]
ListenStream=%[1]d
[Install]
WantedBy=sockets.target
UNIT
sudo tee $U/ontutunnel-tcp-%[1]d.service >/dev/null <<UNIT
[Unit]
Description=OntuTunnel remote access: port %[1]d to the computer's tunnel
Requires=ontutunnel-tcp-%[1]d.socket
After=ontutunnel-tcp-%[1]d.socket
[Service]
ExecStart=$P 127.0.0.1:%[2]d
UNIT
`, p.PublicPort, p.TunnelPort)
	}
	b.WriteString("sudo systemctl daemon-reload\n")
	for _, p := range active {
		fmt.Fprintf(&b, `sudo systemctl stop ontutunnel-tcp-%[1]d.service >/dev/null 2>&1 || true
sudo systemctl enable ontutunnel-tcp-%[1]d.socket >/dev/null 2>&1
sudo systemctl restart ontutunnel-tcp-%[1]d.socket
`, p.PublicPort)
	}
	b.WriteString("echo REMOTE-OK\n")
	return b.String()
}

func intsContain(list []int, v int) bool {
	for _, x := range list {
		if x == v {
			return true
		}
	}
	return false
}

// PublicServerIP: the server's fixed IP (what people outside connect to).
func (a *App) PublicServerIP() string {
	a.mu.Lock()
	ip := a.serverIP
	a.mu.Unlock()
	if ip == "" {
		ip = ResolveHost(a.store.Get().Server.Host)
	}
	return ip
}

// SuggestPublicPort: a free public port from `start` (2201 SSH, 2251 RDP …).
func (a *App) SuggestPublicPort(start int) int {
	cfg := a.store.Get()
	taken := map[int]bool{}
	for _, p := range cfg.RemotePorts {
		taken[p.PublicPort] = true
	}
	if f, err := Probe(a.store); err == nil {
		for _, p := range f.UsedPorts {
			taken[p] = true
		}
		for k := range f.Reserved {
			var n int
			if _, err := fmt.Sscanf(k, "tcp-%d", &n); err == nil {
				taken[n] = true
			}
		}
	}
	p := start
	for taken[p] {
		p++
	}
	return p
}

func (a *App) AddRemotePort(name string, local, public int) error {
	if local < 1 || local > 65535 || public < 1024 || public > 65535 {
		return fmt.Errorf("ports: this computer 1–65535, public 1024–65535")
	}
	for _, p := range a.store.Get().RemotePorts {
		if p.PublicPort == public {
			return fmt.Errorf("public port %d is already in the list", public)
		}
	}
	if strings.TrimSpace(name) == "" {
		name = fmt.Sprintf("Port %d", local)
	}
	a.store.Update(func(c *Config) {
		c.RemotePorts = append(c.RemotePorts, RemotePort{ID: newID(), Name: strings.TrimSpace(name), LocalPort: local, PublicPort: public, Enabled: true})
	})
	if err := a.SyncRemoteAccess(); err != nil {
		a.store.Update(func(c *Config) {
			if intsContain(c.PublishedPublicPorts, public) {
				return
			}
			var keep []RemotePort
			for _, p := range c.RemotePorts {
				if p.PublicPort != public {
					keep = append(keep, p)
				}
			}
			c.RemotePorts = keep
		})
		return err
	}
	return nil
}

func (a *App) RemoveRemotePort(id string) error {
	a.store.Update(func(c *Config) {
		var keep []RemotePort
		for _, p := range c.RemotePorts {
			if p.ID != id {
				keep = append(keep, p)
			}
		}
		c.RemotePorts = keep
	})
	return a.SyncRemoteAccess()
}

func (a *App) SetRemotePortEnabled(id string, on bool) error {
	a.store.Update(func(c *Config) {
		for i := range c.RemotePorts {
			if c.RemotePorts[i].ID == id {
				c.RemotePorts[i].Enabled = on
			}
		}
	})
	return a.SyncRemoteAccess()
}

// SyncRemoteAccess opens/closes the public ports on the server and restarts
// the tunnel with them. Websites keep their ports; they pause a few seconds.
func (a *App) SyncRemoteAccess() error {
	cfg := a.store.Get()
	if !a.Ready() || cfg.Mode != ModeRelay {
		return fmt.Errorf("set up the server first (My server → Server setup)")
	}
	f, err := Probe(a.store)
	if err != nil {
		return fmt.Errorf("can't reach the server: %v", err)
	}
	a.store.Update(func(c *Config) {
		mine := map[string]bool{}
		for _, s := range c.Services {
			mine[s.NormalizedDomain()] = true
		}
		for _, p := range c.RemotePorts {
			mine[fmt.Sprintf("tcp-%d", p.PublicPort)] = true
		}
		taken, foreign := map[int]bool{}, map[int]bool{}
		for _, p := range f.UsedPorts {
			taken[p] = true
		}
		for d, ports := range f.Reserved {
			if !mine[d] {
				for _, p := range ports {
					foreign[p], taken[p] = true, true
				}
			}
		}
		for _, s := range c.Services {
			taken[s.RemotePort], taken[s.RemoteSocketPort] = true, true
		}
		for _, p := range c.RemotePorts {
			taken[p.TunnelPort] = true
		}
		for i := range c.RemotePorts {
			if c.RemotePorts[i].TunnelPort == 0 || foreign[c.RemotePorts[i].TunnelPort] {
				c.RemotePorts[i].TunnelPort = freePort(taken)
				taken[c.RemotePorts[i].TunnelPort] = true
			}
		}
	})
	cfg = a.store.Get()
	_, errOut, err := Run(a.store, remotePortsScript(cfg.RemotePorts, cfg.PublishedPublicPorts), 90*time.Second)
	if err != nil {
		msg := strings.TrimSpace(errOut)
		if msg == "" {
			msg = err.Error()
		}
		a.Log("Remote access", "Not changed: "+msg, true)
		return fmt.Errorf("%s", msg)
	}
	var open []int
	var parts []string
	for _, p := range cfg.RemotePorts {
		if p.Enabled && p.TunnelPort > 0 {
			open = append(open, p.PublicPort)
			parts = append(parts, fmt.Sprintf("%d → this computer :%d", p.PublicPort, p.LocalPort))
		}
	}
	a.store.Update(func(c *Config) { c.PublishedPublicPorts = open })
	a.ConnectTunnel()
	if len(parts) == 0 {
		a.Log("Remote access", "No public ports open", false)
	} else {
		a.Log("Remote access", "Open on "+a.PublicServerIP()+": "+strings.Join(parts, ", "), false)
	}
	return nil
}

// Reachable: can this computer connect to host:port? (It is outside the
// server's network, so this is a real "from the internet" test.)
func Reachable(host string, port int) bool {
	c, err := net.DialTimeout("tcp", net.JoinHostPort(host, fmt.Sprint(port)), 5*time.Second)
	if err != nil {
		return false
	}
	c.Close()
	return true
}

// TestRemotePorts checks every open public port from this computer.
func (a *App) TestRemotePorts() {
	time.Sleep(2 * time.Second) // let the tunnel come back up
	ip := a.PublicServerIP()
	res := map[int]bool{}
	for _, p := range a.store.Get().RemotePorts {
		if p.Enabled {
			res[p.PublicPort] = Reachable(ip, p.PublicPort)
		}
	}
	a.mu.Lock()
	a.remoteReach = res
	a.mu.Unlock()
}
