package main

import (
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strings"
)

// "My static IP" serves sites from this computer, but many home routers
// can't loop a request from inside the network back to their own public IP.
// So OntuTunnel adds its domains to this computer's hosts file (127.0.0.1)
// in a block it owns; nothing else in the file is touched.

const (
	hostsBegin = "# BEGIN OntuTunnel (added automatically, do not edit)"
	hostsEnd   = "# END OntuTunnel"
)

var validHost = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$`)

// hostsPathOverride is used by tests.
var hostsPathOverride string

func hostsPath() string {
	if hostsPathOverride != "" {
		return hostsPathOverride
	}
	if runtime.GOOS == "windows" {
		root := os.Getenv("SystemRoot")
		if root == "" {
			root = `C:\Windows`
		}
		return filepath.Join(root, "System32", "drivers", "etc", "hosts")
	}
	return "/etc/hosts"
}

// splitHosts returns the file without our block, and the domains in it.
func splitHosts(content string) (rest string, ours []string) {
	var keep []string
	in := false
	for _, line := range strings.Split(strings.ReplaceAll(content, "\r\n", "\n"), "\n") {
		t := strings.TrimSpace(line)
		switch {
		case t == hostsBegin:
			in = true
		case t == hostsEnd:
			in = false
		case in:
			if f := strings.Fields(t); len(f) >= 2 {
				ours = append(ours, f[1])
			}
		default:
			keep = append(keep, line)
		}
	}
	return strings.TrimRight(strings.Join(keep, "\n"), "\n") + "\n", ours
}

func buildHosts(rest string, domains []string) string {
	out := rest
	if len(domains) > 0 {
		out += "\n" + hostsBegin + "\n"
		for _, d := range domains {
			out += "127.0.0.1\t" + d + "\n"
		}
		out += hostsEnd + "\n"
	}
	if runtime.GOOS == "windows" {
		out = strings.ReplaceAll(out, "\n", "\r\n")
	}
	return out
}

// handAdded: lines outside our block that map one of these domains elsewhere.
func handAdded(domains []string) []string {
	data, err := os.ReadFile(hostsPath())
	if err != nil {
		return nil
	}
	rest, _ := splitHosts(string(data))
	var found []string
	for _, line := range strings.Split(rest, "\n") {
		f := strings.Fields(strings.SplitN(line, "#", 2)[0])
		for i := 1; i < len(f); i++ {
			if contains(domains, strings.ToLower(f[i])) && f[0] != "127.0.0.1" {
				found = append(found, strings.TrimSpace(line))
			}
		}
	}
	return found
}

// managedHosts: the domains currently in our block.
func managedHosts() []string {
	data, err := os.ReadFile(hostsPath())
	if err != nil {
		return nil
	}
	_, ours := splitHosts(string(data))
	sort.Strings(ours)
	return ours
}

// validateHosts accepts only comments, blank lines and "IP name…" lines,
// so the admin helper never writes something that isn't a hosts file.
func validateHosts(content string) error {
	if len(content) > 1<<20 {
		return fmt.Errorf("hosts file too big")
	}
	for n, line := range strings.Split(strings.ReplaceAll(content, "\r\n", "\n"), "\n") {
		t := strings.TrimSpace(strings.SplitN(line, "#", 2)[0])
		if t == "" {
			continue
		}
		f := strings.Fields(t)
		if len(f) < 2 || net.ParseIP(f[0]) == nil {
			return fmt.Errorf("line %d is not \"IP name\": %q", n+1, line)
		}
	}
	return nil
}

// writeHostsContent writes the whole file (needs admin rights) and clears
// the DNS cache.
func writeHostsContent(content string) error {
	if err := validateHosts(content); err != nil {
		return err
	}
	if runtime.GOOS == "windows" {
		content = strings.ReplaceAll(strings.ReplaceAll(content, "\r\n", "\n"), "\n", "\r\n")
	}
	if err := os.WriteFile(hostsPath(), []byte(content), 0o644); err != nil {
		return err
	}
	flushDNS()
	return nil
}

func flushDNS() {
	switch runtime.GOOS {
	case "windows":
		_, _ = run("ipconfig", "/flushdns")
	case "darwin":
		_, _ = run("dscacheutil", "-flushcache")
		_, _ = run("killall", "-HUP", "mDNSResponder")
	default:
		_, _ = run("resolvectl", "flush-caches")
	}
}

// writeHostsAsAdmin: the hosts file needs admin rights, so OntuTunnel asks
// for them (Windows: the usual "Yes/No" prompt) and runs itself with
// -hosts-write <file>, which checks the file and copies it into place.
func writeHostsAsAdmin(content string) error {
	if err := validateHosts(content); err != nil {
		return err
	}
	if err := writeHostsContent(content); err == nil {
		return nil
	}
	tmp := filepath.Join(DataDir(), "hosts.new")
	if err := os.WriteFile(tmp, []byte(content), 0o600); err != nil {
		return err
	}
	defer os.Remove(tmp)
	self, err := os.Executable()
	if err != nil {
		return err
	}
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "windows":
		q := func(s string) string { return "'" + strings.ReplaceAll(s, "'", "''") + "'" }
		ps := fmt.Sprintf("$p = Start-Process -FilePath %s -ArgumentList '-hosts-write',%s -Verb RunAs -WindowStyle Hidden -Wait -PassThru; exit $p.ExitCode",
			q(self), q(`"`+tmp+`"`))
		cmd = exec.Command("powershell", "-NoProfile", "-Command", ps)
	case "darwin":
		sq := func(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }
		cmd = exec.Command("osascript", "-e", fmt.Sprintf("do shell script %q with administrator privileges", sq(self)+" -hosts-write "+sq(tmp)))
	default:
		if _, err := exec.LookPath("pkexec"); err != nil {
			return fmt.Errorf("needs admin rights: run  sudo %s -hosts-write %s", self, tmp)
		}
		cmd = exec.Command("pkexec", self, "-hosts-write", tmp)
	}
	hideWindow(cmd)
	if out, err := cmd.CombinedOutput(); err != nil {
		msg := strings.TrimSpace(string(out))
		if msg == "" {
			msg = "admin permission was not given"
		}
		return fmt.Errorf("%s", msg)
	}
	return nil
}

// readHosts: the hosts file as text ("" if it can't be read).
func readHosts() string {
	b, _ := os.ReadFile(hostsPath())
	return strings.ReplaceAll(string(b), "\r\n", "\n")
}

// syncHosts keeps the block equal to the enabled sites in static IP mode
// (empty in other modes). Asks for admin rights only when something changes,
// and not again for the same list after a "No".
func (a *App) syncHosts() {
	cfg := a.store.Get()
	var want []string
	if cfg.Mode == ModeStaticIP && !cfg.LocalHostsOff {
		for _, s := range cfg.Services {
			if d := s.NormalizedDomain(); s.Enabled && validHost.MatchString(d) {
				want = append(want, d)
			}
		}
	}
	sort.Strings(want)
	key := strings.Join(want, " ")
	a.hostsMu.Lock()
	defer a.hostsMu.Unlock()
	for _, line := range handAdded(want) {
		a.Log("This computer", "The hosts file has a line added by hand that wins over OntuTunnel's: \""+line+"\" — remove it", true)
	}
	if key == strings.Join(managedHosts(), " ") || (a.hostsDeclinedSet && key == a.hostsDeclined) {
		return
	}
	rest, _ := splitHosts(readHosts())
	if err := writeHostsAsAdmin(buildHosts(rest, want)); err != nil {
		a.hostsDeclined, a.hostsDeclinedSet = key, true
		a.Log("This computer", "Couldn't update the hosts file: "+err.Error(), true)
		return
	}
	a.hostsDeclined, a.hostsDeclinedSet = "", false
	if len(want) == 0 {
		a.Log("This computer", "Removed OntuTunnel's entries from the hosts file", false)
	} else {
		a.Log("This computer", "Your sites now open from this computer too (hosts file: "+key+" → 127.0.0.1)", false)
	}
}
