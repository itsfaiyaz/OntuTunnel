package main

import (
	"fmt"
	"io"
	"net/http"
	"os"
	"testing"
	"time"
)

// Live checks against a real server — only run when OT_TEST_HOST is set:
//
//	OT_TEST_HOST=1.2.3.4 OT_TEST_USER=ubuntu OT_TEST_KEY=~/.ssh/id_ed25519 go test -run Live -v
func liveStore(t *testing.T) *Store {
	host := os.Getenv("OT_TEST_HOST")
	if host == "" {
		t.Skip("OT_TEST_HOST not set")
	}
	os.Setenv("ONTUTUNNEL_HOME", t.TempDir())
	s := OpenStore()
	s.Update(func(c *Config) {
		c.Server = ServerConfig{Host: host, User: os.Getenv("OT_TEST_USER"), Port: 22, KeyPath: os.Getenv("OT_TEST_KEY")}
	})
	return s
}

func TestLiveProbe(t *testing.T) {
	s := liveStore(t)
	f, err := Probe(s)
	if err != nil {
		t.Fatal(err)
	}
	plan, err := f.Plan()
	t.Logf("os=%s sudo=%v port80=%q port443=%q plan=%s err=%v used=%d", f.OS, f.Sudo, f.Port80, f.Port443, plan, err, len(f.UsedPorts))
}

func TestLiveTunnel(t *testing.T) {
	s := liveStore(t)
	local := 8001
	remote := freePort(map[int]bool{})
	tun := NewTunnel(func(m string, e bool) { t.Log(m) })
	tun.Start(s, []Forward{{remote, local}})
	defer tun.Stop()
	for i := 0; i < 15; i++ {
		if st, _ := tun.State(); st == "connected" {
			break
		}
		time.Sleep(time.Second)
	}
	out, _, err := Run(s, fmt.Sprintf("curl -s -o /dev/null -m 10 -w '%%{http_code}' http://127.0.0.1:%d/", remote), 30*time.Second)
	if err != nil || out != "200" {
		t.Fatalf("through tunnel: %q %v", out, err)
	}
	t.Logf("server 127.0.0.1:%d → local:%d answered %s", remote, local, out)
}

func TestProxyRouting(t *testing.T) {
	if !PortOpen(8001) {
		t.Skip("nothing on 8001")
	}
	p := NewProxy(func(string, bool) {})
	p.SetRoutes([]Service{{Domain: "shop.test", LocalPort: 8001, SocketPort: 9001, Enabled: true}})
	p.StartLoopback(18999)
	defer p.Stop()
	time.Sleep(300 * time.Millisecond)
	for _, path := range []string{"/", "/socket.io/?EIO=4&transport=polling"} {
		req, _ := http.NewRequest("GET", "http://127.0.0.1:18999"+path, nil)
		req.Host = "shop.test"
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		io.Copy(io.Discard, resp.Body)
		resp.Body.Close()
		t.Logf("%s → %d", path, resp.StatusCode)
	}
	req, _ := http.NewRequest("GET", "http://127.0.0.1:18999/", nil)
	req.Host = "unknown.test"
	resp, _ := http.DefaultClient.Do(req)
	if resp.StatusCode != 404 {
		t.Fatalf("unknown host gave %d", resp.StatusCode)
	}
}

func TestSystemInfo(t *testing.T) {
	n := GetNetwork()
	t.Logf("network: %+v", n)
	t.Logf("ports: %+v", ScanPorts())
	t.Logf("A(example.com)=%v  label=%s", LookupA("example.com"), DomainLabel("shop.dev.example.co.in"))
}
