package main

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"
)

// Cloudflare Tunnel via the official cloudflared tool:
// install → `tunnel login` (browser, once) → `tunnel create` →
// `tunnel route dns` per domain → `tunnel run` (kept alive).

func cfHome() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".cloudflared")
}

func cfBundled() string {
	name := "cloudflared"
	if runtime.GOOS == "windows" {
		name += ".exe"
	}
	return filepath.Join(DataDir(), "bin", name)
}

func cfBinary() string {
	if p, err := exec.LookPath("cloudflared"); err == nil {
		return p
	}
	for _, p := range []string{"/opt/homebrew/bin/cloudflared", "/usr/local/bin/cloudflared", cfBundled()} {
		if st, err := os.Stat(p); err == nil && !st.IsDir() {
			return p
		}
	}
	return ""
}

func cfLoggedIn() bool {
	_, err := os.Stat(filepath.Join(cfHome(), "cert.pem"))
	return err == nil
}

// InstallCloudflared downloads the official release for this OS/CPU.
func InstallCloudflared() (string, error) {
	if b := cfBinary(); b != "" {
		return b, nil
	}
	arch := runtime.GOARCH
	var url string
	switch runtime.GOOS {
	case "windows":
		url = fmt.Sprintf("https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-%s.exe", arch)
	case "linux":
		url = fmt.Sprintf("https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-%s", arch)
	case "darwin":
		url = fmt.Sprintf("https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-%s.tgz", arch)
	default:
		return "", fmt.Errorf("unsupported system %s", runtime.GOOS)
	}
	dest := cfBundled()
	_ = os.MkdirAll(filepath.Dir(dest), 0o755)
	resp, err := http.Get(url)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return "", fmt.Errorf("download failed: HTTP %d", resp.StatusCode)
	}
	var src io.Reader = resp.Body
	if strings.HasSuffix(url, ".tgz") {
		gz, err := gzip.NewReader(resp.Body)
		if err != nil {
			return "", err
		}
		tr := tar.NewReader(gz)
		for {
			h, err := tr.Next()
			if err != nil {
				return "", fmt.Errorf("cloudflared not found in archive")
			}
			if filepath.Base(h.Name) == "cloudflared" {
				src = tr
				break
			}
		}
	}
	f, err := os.OpenFile(dest, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o755)
	if err != nil {
		return "", err
	}
	if _, err := io.Copy(f, src); err != nil {
		f.Close()
		return "", err
	}
	f.Close()
	return dest, nil
}

func cfExec(bin string, timeout time.Duration, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, bin, args...)
	hideWindow(cmd)
	out, err := cmd.CombinedOutput()
	return string(out), err
}

func CloudflareLogin(bin string) (string, error) {
	return cfExec(bin, 10*time.Minute, "tunnel", "login")
}

func CloudflareEnsureTunnel(bin, name string) (string, error) {
	find := func() string {
		out, err := cfExec(bin, time.Minute, "tunnel", "list", "--output", "json")
		if err != nil {
			return ""
		}
		var list []map[string]any
		if json.Unmarshal([]byte(out), &list) != nil {
			return ""
		}
		for _, t := range list {
			if t["name"] == name {
				if id, ok := t["id"].(string); ok {
					return id
				}
			}
		}
		return ""
	}
	if id := find(); id != "" {
		return id, nil
	}
	out, _ := cfExec(bin, time.Minute, "tunnel", "create", name)
	if id := find(); id != "" {
		return id, nil
	}
	return "", fmt.Errorf("could not create the tunnel: %s", strings.TrimSpace(out))
}

func CloudflareRouteDNS(bin, tunnelID, domain string) error {
	out, err := cfExec(bin, time.Minute, "tunnel", "route", "dns", "--overwrite-dns", tunnelID, domain)
	if err != nil && !strings.Contains(strings.ToLower(out), "already") {
		if strings.Contains(out, "not found") || strings.Contains(strings.ToLower(out), "zone") {
			return fmt.Errorf("%s: its domain isn't in the Cloudflare account you logged in with", domain)
		}
		return fmt.Errorf("%s: %s", domain, strings.TrimSpace(out))
	}
	return nil
}

func cfConfigFile() string { return filepath.Join(DataDir(), "cloudflared.yml") }

func CloudflareWriteConfig(tunnelID string, proxyPort int) error {
	creds := filepath.Join(cfHome(), tunnelID+".json")
	yml := fmt.Sprintf("# Written by OntuTunnel — replaced on every sync.\ntunnel: %s\ncredentials-file: %s\ningress:\n  - service: http://127.0.0.1:%d\n", tunnelID, creds, proxyPort)
	return os.WriteFile(cfConfigFile(), []byte(yml), 0o600)
}

// CFRunner keeps `cloudflared tunnel run` alive.
type CFRunner struct {
	mu     sync.Mutex
	cmd    *exec.Cmd
	wanted bool
	state  string
	detail string
	log    func(string, bool)
}

func NewCFRunner(log func(string, bool)) *CFRunner { return &CFRunner{state: "stopped", log: log} }

func (c *CFRunner) State() (string, string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.state, c.detail
}

func (c *CFRunner) Start(bin string) {
	c.Stop()
	c.mu.Lock()
	c.wanted = true
	c.mu.Unlock()
	go c.loop(bin)
}

func (c *CFRunner) Stop() {
	c.mu.Lock()
	c.wanted = false
	if c.cmd != nil && c.cmd.Process != nil {
		_ = c.cmd.Process.Kill()
	}
	c.cmd = nil
	c.state, c.detail = "stopped", ""
	c.mu.Unlock()
}

func (c *CFRunner) loop(bin string) {
	delay := 3 * time.Second
	for {
		c.mu.Lock()
		if !c.wanted {
			c.mu.Unlock()
			return
		}
		cmd := exec.Command(bin, "tunnel", "--no-autoupdate", "--config", cfConfigFile(), "run")
		hideWindow(cmd)
		c.cmd = cmd
		c.state = "connecting"
		c.mu.Unlock()

		pr, pw := io.Pipe()
		cmd.Stdout, cmd.Stderr = pw, pw
		if err := cmd.Start(); err != nil {
			c.mu.Lock()
			c.state, c.detail = "failed", err.Error()
			c.mu.Unlock()
			return
		}
		go func() {
			buf := make([]byte, 4096)
			for {
				n, err := pr.Read(buf)
				if n > 0 {
					for _, line := range strings.Split(string(buf[:n]), "\n") {
						if strings.Contains(line, "Registered tunnel connection") {
							c.mu.Lock()
							c.state = "connected"
							c.mu.Unlock()
							c.log(strings.TrimSpace(line), false)
						} else if strings.Contains(line, " ERR ") {
							c.log(strings.TrimSpace(line), true)
						}
					}
				}
				if err != nil {
					return
				}
			}
		}()
		err := cmd.Wait()
		pw.Close()
		c.mu.Lock()
		if !c.wanted {
			c.mu.Unlock()
			return
		}
		c.state, c.detail = "failed", fmt.Sprintf("cloudflared exited (%v) — restarting", err)
		c.mu.Unlock()
		c.log(fmt.Sprintf("cloudflared exited, restarting in %d s", int(delay.Seconds())), true)
		time.Sleep(delay)
		if delay < time.Minute {
			delay *= 2
		}
	}
}
