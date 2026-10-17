package main

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"time"
)

// ---------- this computer's addresses ----------

type Network struct {
	PublicIPv4 string `json:"publicIPv4"`
	LocalIPv4  string `json:"localIPv4"`
	IPv6       string `json:"ipv6"`
}

func GetNetwork() Network {
	var n Network
	if c, err := net.Dial("udp", "8.8.8.8:53"); err == nil {
		n.LocalIPv4 = c.LocalAddr().(*net.UDPAddr).IP.String()
		c.Close()
	}
	if c, err := net.Dial("udp", "[2001:4860:4860::8888]:53"); err == nil {
		ip := c.LocalAddr().(*net.UDPAddr).IP
		if ip.IsGlobalUnicast() {
			n.IPv6 = ip.String()
		}
		c.Close()
	}
	client := &http.Client{Timeout: 6 * time.Second}
	if r, err := client.Get("https://api.ipify.org"); err == nil {
		b, _ := io.ReadAll(r.Body)
		r.Body.Close()
		n.PublicIPv4 = strings.TrimSpace(string(b))
	}
	return n
}

// ---------- DNS (public resolvers, not the local cache) ----------

func resolverFor(server string) *net.Resolver {
	return &net.Resolver{PreferGo: true, Dial: func(ctx context.Context, _, _ string) (net.Conn, error) {
		d := net.Dialer{Timeout: 3 * time.Second}
		return d.DialContext(ctx, "udp", server)
	}}
}

// LookupA asks Google then Cloudflare; the first that knows the name wins.
func LookupA(domain string) []string {
	for _, srv := range []string{"8.8.8.8:53", "1.1.1.1:53"} {
		ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
		ips, err := resolverFor(srv).LookupIP(ctx, "ip4", domain)
		cancel()
		if err == nil && len(ips) > 0 {
			var out []string
			for _, ip := range ips {
				out = append(out, ip.String())
			}
			sort.Strings(out)
			return out
		}
	}
	return nil
}

// ResolveHost: IP as is, else its A record.
func ResolveHost(host string) string {
	if net.ParseIP(host) != nil {
		return host
	}
	if a := LookupA(host); len(a) > 0 {
		return a[0]
	}
	return host
}

// ---------- checks ----------

type Check struct {
	OK    bool   `json:"ok"`
	State string `json:"state"` // ok | warning | failed | checking | unknown
	Text  string `json:"text"`
}

func ok() Check           { return Check{OK: true, State: "ok", Text: "OK"} }
func warn(t string) Check { return Check{State: "warning", Text: t} }
func fail(t string) Check { return Check{State: "failed", Text: t} }
func unknown() Check      { return Check{State: "unknown", Text: "Not checked"} }

func PortOpen(port int) bool {
	for _, addr := range []string{fmt.Sprintf("127.0.0.1:%d", port), fmt.Sprintf("[::1]:%d", port)} {
		if c, err := net.DialTimeout("tcp", addr, 1500*time.Millisecond); err == nil {
			c.Close()
			return true
		}
	}
	return false
}

// LiveCheck: HTTPS GET to the public DNS answer — goes out to the internet
// and back, so success means the whole chain works.
func LiveCheck(domain string) Check {
	ips := LookupA(domain)
	if len(ips) == 0 {
		return fail("Domain has no A record in public DNS")
	}
	ip := ips[0]
	tr := &http.Transport{
		DialContext: func(ctx context.Context, network, _ string) (net.Conn, error) {
			d := net.Dialer{Timeout: 8 * time.Second}
			return d.DialContext(ctx, network, net.JoinHostPort(ip, "443"))
		},
		TLSClientConfig: &tls.Config{ServerName: domain},
	}
	client := &http.Client{Transport: tr, Timeout: 12 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	resp, err := client.Get("https://" + domain + "/")
	if err != nil {
		var certErr *tls.CertificateVerificationError
		if errors.As(err, &certErr) || strings.Contains(err.Error(), "certificate") || strings.Contains(err.Error(), "tls") {
			return warn("HTTPS certificate not ready yet")
		}
		return fail(fmt.Sprintf("Server %s not reachable on port 443 (firewall?)", ip))
	}
	resp.Body.Close()
	switch {
	case resp.StatusCode == 502 || resp.StatusCode == 503 || resp.StatusCode == 504:
		return fail(fmt.Sprintf("Server can't reach this computer (HTTP %d) — tunnel or local app down", resp.StatusCode))
	case resp.StatusCode >= 500:
		return warn(fmt.Sprintf("Your app answered HTTP %d", resp.StatusCode))
	}
	return ok()
}

// ---------- ports listening on this computer ----------

type ListeningPort struct {
	Port    int    `json:"port"`
	Process string `json:"process"`
}

var ignoredProcs = []string{"ontutunnel", "cloudflared", "System", "svchost", "lsass", "wininit", "services", "spoolsv",
	"ControlCe", "rapportd", "launchd", "mDNSRespo", "systemd", "sshd", "cupsd", "avahi", "chronyd"}

func ScanPorts() []ListeningPort {
	ports := map[int]string{}
	switch runtime.GOOS {
	case "windows":
		names := windowsProcessNames()
		out, _ := run("netstat", "-ano", "-p", "TCP")
		re := regexp.MustCompile(`TCP\s+\S+:(\d+)\s+\S+\s+LISTENING\s+(\d+)`)
		for _, m := range re.FindAllStringSubmatch(out, -1) {
			p, _ := strconv.Atoi(m[1])
			if _, seen := ports[p]; !seen {
				ports[p] = names[m[2]]
			}
		}
		out6, _ := run("netstat", "-ano", "-p", "TCPv6")
		for _, m := range re.FindAllStringSubmatch(out6, -1) {
			p, _ := strconv.Atoi(m[1])
			if _, seen := ports[p]; !seen {
				ports[p] = names[m[2]]
			}
		}
	case "linux":
		out, err := run("ss", "-ltnpH")
		if err == nil {
			re := regexp.MustCompile(`:(\d+)\s+\S+(?:\s+users:\(\("([^"]+)")?`)
			for _, line := range strings.Split(out, "\n") {
				f := strings.Fields(line)
				if len(f) < 4 {
					continue
				}
				m := re.FindStringSubmatch(strings.Join(f[3:], " "))
				if m == nil {
					continue
				}
				p, _ := strconv.Atoi(m[1])
				if _, seen := ports[p]; !seen {
					ports[p] = m[2]
				}
			}
		}
	default: // macOS
		out, _ := run("lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-Fcn")
		cmd := ""
		for _, line := range strings.Split(out, "\n") {
			if strings.HasPrefix(line, "c") {
				cmd = line[1:]
			} else if strings.HasPrefix(line, "n") {
				parts := strings.Split(line, ":")
				p, _ := strconv.Atoi(parts[len(parts)-1])
				if _, seen := ports[p]; !seen {
					ports[p] = cmd
				}
			}
		}
	}
	var list []ListeningPort
	for p, name := range ports {
		if p == 0 || p >= 49152 {
			continue
		}
		skip := false
		for _, ig := range ignoredProcs {
			if strings.HasPrefix(strings.ToLower(name), strings.ToLower(ig)) {
				skip = true
			}
		}
		if !skip {
			if name == "" {
				name = "unknown"
			}
			list = append(list, ListeningPort{Port: p, Process: name})
		}
	}
	sort.Slice(list, func(i, j int) bool { return list[i].Port < list[j].Port })
	return list
}

func windowsProcessNames() map[string]string {
	out, _ := run("tasklist", "/FO", "CSV", "/NH")
	names := map[string]string{}
	for _, line := range strings.Split(out, "\n") {
		f := strings.Split(line, "\",\"")
		if len(f) >= 2 {
			names[strings.Trim(f[1], "\"")] = strings.TrimSuffix(strings.Trim(f[0], "\""), ".exe")
		}
	}
	return names
}

func run(name string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, name, args...)
	hideWindow(cmd)
	out, err := cmd.Output()
	return string(out), err
}

func expandHome(p string) string {
	if strings.HasPrefix(p, "~") {
		home, _ := os.UserHomeDir()
		return filepath.Join(home, strings.TrimPrefix(p, "~"))
	}
	return p
}

// DomainLabel: "shop.example.com" → "shop" (what DNS panels ask for).
func DomainLabel(d string) string {
	parts := strings.Split(d, ".")
	if len(parts) <= 2 {
		return "@"
	}
	keep := 2
	switch strings.Join(parts[len(parts)-2:], ".") {
	case "co.in", "org.in", "net.in", "gov.in", "ac.in", "co.uk", "com.au":
		keep = 3
	}
	if len(parts) <= keep {
		return "@"
	}
	return strings.Join(parts[:len(parts)-keep], ".")
}
