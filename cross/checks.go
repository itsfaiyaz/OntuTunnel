package main

import (
	"fmt"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"sync"
	"time"
)

// First-time checks for "My static IP": everything that has to be open
// before Let's Encrypt can give the sites HTTPS certificates.

const firewallRule = "OntuTunnel"

var fw struct {
	sync.Mutex
	state string
	at    time.Time
}

// firewallState: "ok", "missing" or "n/a" (not Windows); checked at most
// every 30 s.
func firewallState() string {
	if runtime.GOOS != "windows" {
		return "n/a"
	}
	fw.Lock()
	defer fw.Unlock()
	if time.Since(fw.at) < 30*time.Second && fw.state != "" {
		return fw.state
	}
	out, _ := run("netsh", "advfirewall", "firewall", "show", "rule", "name="+firewallRule)
	fw.state = "missing"
	if strings.Contains(out, firewallRule) && !strings.Contains(strings.ToLower(out), "no rules match") {
		fw.state = "ok"
	}
	fw.at = time.Now()
	return fw.state
}

// AllowFirewall adds the inbound rule for OntuTunnel (asks for admin rights).
func (a *App) AllowFirewall() error {
	if runtime.GOOS != "windows" {
		return nil
	}
	self, err := os.Executable()
	if err != nil {
		return err
	}
	q := func(s string) string { return "'" + strings.ReplaceAll(s, "'", "''") + "'" }
	args := fmt.Sprintf(`advfirewall firewall add rule name="%s" dir=in action=allow program="%s" enable=yes profile=any`, firewallRule, self)
	ps := fmt.Sprintf("$p = Start-Process -FilePath 'netsh' -ArgumentList %s -Verb RunAs -WindowStyle Hidden -Wait -PassThru; exit $p.ExitCode", q(args))
	cmd := exec.Command("powershell", "-NoProfile", "-Command", ps)
	hideWindow(cmd)
	if out, err := cmd.CombinedOutput(); err != nil {
		msg := strings.TrimSpace(string(out))
		if msg == "" {
			msg = "admin permission was not given"
		}
		a.Log("Firewall", "Not changed: "+msg, true)
		return fmt.Errorf("%s", msg)
	}
	fw.Lock()
	fw.at = time.Time{}
	fw.Unlock()
	a.Log("Firewall", "Windows Firewall now lets visitors reach OntuTunnel (ports 80 and 443)", false)
	return nil
}

// OutsideCheck: can the internet reach this computer's public IP on 80/443?
// Tested from the user's own server (My server settings), because from inside
// the home network the router's own IP usually can't be tested.
type OutsideCheck struct {
	State   string    `json:"state"` // unknown | checking | ok | failed | warning
	Text    string    `json:"text"`
	Checked time.Time `json:"checked"`
}

func (a *App) TestFromOutside() {
	cfg := a.store.Get()
	ip := a.DNSTarget()
	set := func(c OutsideCheck) { a.mu.Lock(); a.outside = c; a.mu.Unlock() }
	if !cfg.Server.Complete() {
		set(OutsideCheck{State: "warning", Text: "Needs a server to test from (Connection → My server: IP, user, key). Or open http://" + ip + " on a phone with mobile data."})
		return
	}
	set(OutsideCheck{State: "checking", Text: "Testing " + ip + " from " + cfg.Server.Host + "…"})
	script := fmt.Sprintf(`for p in 80 443; do if timeout 6 bash -c "</dev/tcp/%s/$p" 2>/dev/null; then echo "$p open"; else echo "$p closed"; fi; done`, ip)
	out, _, err := Run(a.store, script, 30*time.Second)
	switch {
	case err != nil:
		set(OutsideCheck{State: "warning", Text: "Couldn't log in to " + cfg.Server.Host + " to test: " + err.Error(), Checked: time.Now()})
	case strings.Contains(out, "80 open") && strings.Contains(out, "443 open"):
		set(OutsideCheck{State: "ok", Text: "The internet reaches " + ip + " on ports 80 and 443", Checked: time.Now()})
	case strings.Contains(out, "80 open"):
		set(OutsideCheck{State: "warning", Text: "Port 80 is reachable but 443 is not: forward 443 on the router too", Checked: time.Now()})
	default:
		set(OutsideCheck{State: "failed", Text: "The internet can't reach " + ip + " on ports 80/443. Forward them on the router; if they are forwarded, your internet provider blocks incoming connections (ask them to open 80 and 443, or use My server mode).", Checked: time.Now()})
	}
}
