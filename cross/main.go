// OntuTunnel for Windows and Linux (also runs on macOS): put your localhost
// on your own domain with HTTPS. Runs in the background and serves its
// dashboard at http://localhost:7777.
package main

import (
	"crypto/rand"
	"encoding/hex"
	"flag"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"runtime"
	"syscall"
	"time"
)

// Version is set at build time: -ldflags "-X main.Version=1.1.0".
var Version = "dev"

func openBrowser(url string) {
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "windows":
		cmd = exec.Command("rundll32", "url.dll,FileProtocolHandler", url)
	case "darwin":
		cmd = exec.Command("open", url)
	default:
		cmd = exec.Command("xdg-open", url)
	}
	hideWindow(cmd)
	_ = cmd.Start()
}

func main() {
	noBrowser := flag.Bool("no-browser", false, "don't open the dashboard in the browser")
	showVersion := flag.Bool("version", false, "print the version")
	hostsWrite := flag.String("hosts-write", "", "admin helper: check this file and make it the hosts file")
	flag.Parse()
	if *hostsWrite != "" {
		b, err := os.ReadFile(*hostsWrite)
		if err == nil {
			err = writeHostsContent(string(b))
		}
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}
	if *showVersion {
		fmt.Println("OntuTunnel", Version)
		return
	}

	store := OpenStore()
	cfg := store.Update(func(c *Config) {
		if c.Web.Key == "" {
			b := make([]byte, 8)
			_, _ = rand.Read(b)
			c.Web.Key = hex.EncodeToString(b)
		}
	})
	url := fmt.Sprintf("http://localhost:%d", cfg.Web.Port)

	// already running? ask it to show its window (or open its dashboard)
	if c, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", cfg.Web.Port), 500*time.Millisecond); err == nil {
		c.Close()
		if !*noBrowser {
			client := http.Client{Timeout: 3 * time.Second}
			resp, err := client.Post(fmt.Sprintf("http://127.0.0.1:%d/ui/show", cfg.Web.Port), "text/plain", nil)
			if err == nil {
				resp.Body.Close()
			}
			if err != nil || resp.StatusCode != http.StatusNoContent {
				openBrowser(url)
			}
		}
		return
	}

	app := NewApp(store)
	addr := fmt.Sprintf("127.0.0.1:%d", cfg.Web.Port)
	if cfg.Web.AllowLAN {
		addr = fmt.Sprintf(":%d", cfg.Web.Port)
	}
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		fmt.Fprintln(os.Stderr, "OntuTunnel: can't open the dashboard port:", err)
		os.Exit(1)
	}
	app.Log("OntuTunnel", fmt.Sprintf("Version %s — dashboard at %s", Version, url), false)
	app.ShowUI = func() { openBrowser(url) }
	app.Start()
	go func() { _ = http.Serve(ln, app.Handler()) }()
	if hasDesktop {
		// Windows: app window + tray icon; returns when "Quit" is chosen.
		// -no-browser (start with Windows) starts in the tray only.
		runDesktop(app, url, !*noBrowser)
		app.StopAll()
		return
	}
	if !*noBrowser {
		openBrowser(url)
	}

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	<-sig
	app.StopAll()
}
