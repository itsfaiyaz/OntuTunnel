package main

import (
	"fmt"
	"net"
	"strings"
)

// The Hosts page: every "IP name" line of this computer's hosts file, which
// the user can add, change or delete. OntuTunnel's own block is shown but
// managed automatically; system lines (localhost …) are shown read-only.

type HostEntry struct {
	Line    int    `json:"line"` // index in the file; -1 for OntuTunnel's block
	IP      string `json:"ip"`
	Names   string `json:"names"`
	Comment string `json:"comment"`
	Source  string `json:"source"` // "you" | "ontutunnel" | "system"
	Raw     string `json:"raw"`
}

var systemNames = map[string]bool{"localhost": true, "broadcasthost": true, "ip6-localhost": true,
	"ip6-loopback": true, "ip6-allnodes": true, "ip6-allrouters": true, "ip6-localnet": true, "ip6-mcastprefix": true}

func hostEntries() []HostEntry {
	var out []HostEntry
	in := false
	for i, line := range strings.Split(readHosts(), "\n") {
		t := strings.TrimSpace(line)
		switch {
		case t == hostsBegin:
			in = true
			continue
		case t == hostsEnd:
			in = false
			continue
		}
		body, comment, _ := strings.Cut(t, "#")
		f := strings.Fields(body)
		if len(f) < 2 || net.ParseIP(f[0]) == nil {
			continue
		}
		e := HostEntry{Line: i, IP: f[0], Names: strings.Join(f[1:], " "), Comment: strings.TrimSpace(comment), Source: "you", Raw: line}
		if in {
			e.Line, e.Source = -1, "ontutunnel"
		} else if systemNames[strings.ToLower(f[1])] {
			e.Source = "system"
		}
		out = append(out, e)
	}
	return out
}

// HostEdit: add (Line -1), change or delete one of the user's lines.
type HostEdit struct {
	Op    string `json:"op"` // add | update | delete
	Line  int    `json:"line"`
	Raw   string `json:"raw"` // the line as shown, to catch outside changes
	IP    string `json:"ip"`
	Names string `json:"names"`
}

func applyHostEdit(e HostEdit) (string, error) {
	lines := strings.Split(readHosts(), "\n")
	newLine := ""
	if e.Op != "delete" {
		ip := strings.TrimSpace(e.IP)
		if net.ParseIP(ip) == nil {
			return "", fmt.Errorf("%q is not an IP address", ip)
		}
		names := strings.Fields(strings.ToLower(e.Names))
		if len(names) == 0 {
			return "", fmt.Errorf("enter a domain")
		}
		for _, n := range names {
			if !validHost.MatchString(n) && n != "localhost" {
				return "", fmt.Errorf("%q is not a valid domain", n)
			}
		}
		newLine = ip + "\t" + strings.Join(names, " ")
	}
	switch e.Op {
	case "add":
		// before OntuTunnel's block (so the order stays tidy), else at the end
		at := len(lines)
		for at > 0 && strings.TrimSpace(lines[at-1]) == "" {
			at--
		}
		for i, l := range lines {
			if strings.TrimSpace(l) == hostsBegin {
				at = i
				break
			}
		}
		lines = append(lines[:at], append([]string{newLine}, lines[at:]...)...)
	case "update", "delete":
		if e.Line < 0 || e.Line >= len(lines) || lines[e.Line] != e.Raw {
			return "", fmt.Errorf("the hosts file changed meanwhile — refresh and try again")
		}
		if e.Op == "update" {
			lines[e.Line] = newLine
		} else {
			lines = append(lines[:e.Line], lines[e.Line+1:]...)
		}
	default:
		return "", fmt.Errorf("unknown change")
	}
	content := strings.Join(lines, "\n")
	if !strings.HasSuffix(content, "\n") {
		content += "\n"
	}
	return content, nil
}

// EditHosts applies one change (asks for admin rights once).
func (a *App) EditHosts(e HostEdit) error {
	a.hostsMu.Lock()
	defer a.hostsMu.Unlock()
	content, err := applyHostEdit(e)
	if err == nil {
		err = writeHostsAsAdmin(content)
	}
	if err != nil {
		a.Log("Hosts", "Not saved: "+err.Error(), true)
		return err
	}
	a.Log("Hosts", fmt.Sprintf("Hosts file: %s %s %s", e.Op, strings.TrimSpace(e.IP), strings.TrimSpace(e.Names)), false)
	return nil
}
