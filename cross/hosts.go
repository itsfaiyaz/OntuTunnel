package main

import (
	"fmt"
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

func hostsPath() string {
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

// writeHosts replaces our block with these domains (none = remove it).
func writeHosts(domains []string) error {
	for _, d := range domains {
		if !validHost.MatchString(d) {
			return fmt.Errorf("not a valid domain: %q", d)
		}
	}
	data, err := os.ReadFile(hostsPath())
	if err != nil {
		return err
	}
	rest, _ := splitHosts(string(data))
	if err := os.WriteFile(hostsPath(), []byte(buildHosts(rest, domains)), 0o644); err != nil {
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
// -hosts-set, which only rewrites its own block.
func writeHostsAsAdmin(domains []string) error {
	if err := writeHosts(domains); err == nil {
		return nil
	}
	self, err := os.Executable()
	if err != nil {
		return err
	}
	args := append([]string{"-hosts-set"}, domains...)
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "windows":
		quoted := make([]string, len(args))
		for i, a := range args {
			quoted[i] = "'" + a + "'"
		}
		ps := fmt.Sprintf("$p = Start-Process -FilePath '%s' -ArgumentList %s -Verb RunAs -WindowStyle Hidden -Wait -PassThru; exit $p.ExitCode",
			strings.ReplaceAll(self, "'", "''"), strings.Join(quoted, ","))
		cmd = exec.Command("powershell", "-NoProfile", "-Command", ps)
	case "darwin":
		line := "'" + strings.ReplaceAll(self, "'", `'\''`) + "' " + strings.Join(args, " ")
		cmd = exec.Command("osascript", "-e", fmt.Sprintf("do shell script %q with administrator privileges", line))
	default:
		if _, err := exec.LookPath("pkexec"); err != nil {
			return fmt.Errorf("needs admin rights: run  sudo %s %s", self, strings.Join(args, " "))
		}
		cmd = exec.Command("pkexec", append([]string{self}, args...)...)
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
	if key == strings.Join(managedHosts(), " ") || key == a.hostsDeclined {
		return
	}
	if err := writeHostsAsAdmin(want); err != nil {
		a.hostsDeclined = key
		a.Log("This computer", "Couldn't update the hosts file: "+err.Error(), true)
		return
	}
	a.hostsDeclined = ""
	if len(want) == 0 {
		a.Log("This computer", "Removed OntuTunnel's entries from the hosts file", false)
	} else {
		a.Log("This computer", "Your sites now open from this computer too (hosts file: "+key+" → 127.0.0.1)", false)
	}
}
