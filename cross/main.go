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
	flag.Parse()
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

	// already running? just open its dashboard
	if c, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", cfg.Web.Port), 500*time.Millisecond); err == nil {
		c.Close()
		if !*noBrowser {
			openBrowser(url)
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
	app.Start()
	go func() { _ = http.Serve(ln, app.Handler()) }()
	if !*noBrowser {
		openBrowser(url)
	}

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	<-sig
	app.StopAll()
}
