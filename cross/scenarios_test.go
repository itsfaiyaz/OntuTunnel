//go:build linux

package main

import (
	"os"
	"os/exec"
	"strings"
	"testing"
)

// Real server scenarios, run on a throw-away Linux machine (GitHub Actions)
// with passwordless sudo: the same scripts OntuTunnel sends over SSH, run
// locally. Two or three "computers" share one server.
//
//	OT_SCENARIO=nginx  needs nginx running on 80/443
//	OT_SCENARIO=caddy  needs 80/443 free (downloads Caddy)

func runLocal(t *testing.T, script string) (string, int) {
	t.Helper()
	cmd := exec.Command("bash", "-s")
	cmd.Stdin = strings.NewReader("set -o pipefail\n" + script + "\n")
	out, err := cmd.CombinedOutput()
	code := 0
	if ee, ok := err.(*exec.ExitError); ok {
		code = ee.ExitCode()
	} else if err != nil {
		t.Fatal(err)
	}
	return string(out), code
}

func site(d string, port int) Service {
	return Service{ID: d, Name: d, Domain: d, LocalPort: 3000, Enabled: true, RemotePort: port}
}

func fileHas(t *testing.T, path, text string) bool {
	t.Helper()
	b, err := os.ReadFile(path)
	return err == nil && strings.Contains(string(b), text)
}

func mustOK(t *testing.T, what, script string) string {
	t.Helper()
	out, code := runLocal(t, script)
	if code != 0 {
		t.Fatalf("%s: exit %d\n%s", what, code, out)
	}
	return out
}

func sharedServer(t *testing.T, file func(string) string, apply func([]Service, []string) string) {
	a, b, c := "a.ot.test", "b.ot.test", "c.ot.test"

	// computer A and computer B each publish a site
	mustOK(t, "A publishes", apply([]Service{site(a, 31001)}, nil))
	mustOK(t, "B publishes", apply([]Service{site(b, 31002)}, nil))
	if !fileHas(t, file(a), "127.0.0.1:31001") || !fileHas(t, file(b), "127.0.0.1:31002") {
		t.Fatal("A's and B's sites should both be there")
	}

	// B syncing again must not touch A's site
	mustOK(t, "B syncs again", apply([]Service{site(b, 31002)}, []string{b}))
	if !fileHas(t, file(a), "127.0.0.1:31001") {
		t.Fatal("B's sync removed A's site")
	}

	// B tries to take A's domain: refused, A's file unchanged
	out, code := runLocal(t, apply([]Service{site(a, 31009), site(b, 31002)}, []string{b}))
	if code != 3 || !strings.Contains(out, "already published by another computer") {
		t.Fatalf("taking over A's domain should be refused, got exit %d\n%s", code, out)
	}
	if !fileHas(t, file(a), "127.0.0.1:31001") {
		t.Fatal("A's site was changed by B")
	}

	// the probe sees both computers' ports, so a new site of B never gets A's port
	f := parseFacts(mustOK(t, "probe", probeScript))
	if f.Reserved[a] == nil || f.Reserved[a][0] != 31001 || f.Reserved[b][0] != 31002 {
		t.Fatalf("reserved = %v", f.Reserved)
	}
	t.Setenv("ONTUTUNNEL_HOME", t.TempDir())
	store := OpenStore()
	store.Update(func(cfg *Config) { cfg.Services = []Service{site(b, 31002), site(c, 31001)} })
	(&App{store: store}).assignPorts(f.UsedPorts, f.Reserved)
	for _, s := range store.Get().Services {
		if s.NormalizedDomain() == c && s.RemotePort == 31001 {
			t.Fatal("B got A's port for a new site")
		}
	}

	// A deletes its site: only A's file goes
	mustOK(t, "A removes its site", apply(nil, []string{a}))
	if _, err := os.Stat(file(a)); err == nil {
		t.Fatal("A's removed site is still there")
	}
	if !fileHas(t, file(b), "127.0.0.1:31002") {
		t.Fatal("A's cleanup removed B's site")
	}

	// C joins; B leaves the server: C's site and the shared parts stay
	mustOK(t, "C publishes", apply([]Service{site(c, 31003)}, nil))
	out = mustOK(t, "B removes OntuTunnel", uninstallScript([]string{b}))
	if !strings.Contains(out, "OTHERS-REMAIN") || !fileHas(t, file(c), "127.0.0.1:31003") {
		t.Fatalf("B's uninstall should keep C's site\n%s", out)
	}
	if _, err := os.Stat(file(b)); err == nil {
		t.Fatal("B's site still there after uninstall")
	}

	// the last computer leaves: everything OntuTunnel added is gone
	out = mustOK(t, "C removes OntuTunnel", uninstallScript([]string{c}))
	if strings.Contains(out, "OTHERS-REMAIN") {
		t.Fatalf("nothing else should remain\n%s", out)
	}
	if _, err := os.Stat("/etc/ontutunnel"); err == nil {
		t.Fatal("/etc/ontutunnel still there")
	}
}

func TestScenarioNginx(t *testing.T) {
	if os.Getenv("OT_SCENARIO") != "nginx" {
		t.Skip("set OT_SCENARIO=nginx on a throw-away machine")
	}
	sharedServer(t, nginxFile, func(s []Service, pub []string) string {
		return applyNginxScript(s, "", pub) + "\nsudo nginx -t"
	})
	if out, code := runLocal(t, "sudo nginx -t"); code != 0 {
		t.Fatalf("nginx config broken at the end\n%s", out)
	}
}

func TestScenarioCaddy(t *testing.T) {
	if os.Getenv("OT_SCENARIO") != "caddy" {
		t.Skip("set OT_SCENARIO=caddy on a throw-away machine")
	}
	mustOK(t, "install Caddy", installCaddyScript())
	sharedServer(t, caddySiteFile, func(s []Service, pub []string) string {
		if s == nil && pub == nil {
			return "true"
		}
		// an install step runs before every apply, as a fresh computer would
		return installCaddyScript() + "\n" + applyCaddyScript(s, "", pub)
	})
	// Caddy with no sites at all (empty import) must still start
	mustOK(t, "install again", installCaddyScript())
	mustOK(t, "no sites", applyCaddyScript(nil, "", nil))
}

func TestScenarioStalePortsOnlySSH(t *testing.T) {
	if os.Getenv("OT_SCENARIO") == "" {
		t.Skip("set OT_SCENARIO on a throw-away machine")
	}
	// a non-ssh program listening on a "tunnel port" must never be killed
	cmd := exec.Command("python3", "-m", "http.server", "31555", "--bind", "127.0.0.1")
	if err := cmd.Start(); err != nil {
		t.Skip("python3 missing")
	}
	defer cmd.Process.Kill()
	mustOK(t, "wait", "sleep 1")
	out := mustOK(t, "free stale ports", freeStalePortsScript([]int{31555}))
	if strings.Contains(out, "freed") || cmd.ProcessState != nil {
		t.Fatalf("killed a program that isn't an SSH session\n%s", out)
	}
	if _, code := runLocal(t, "ss -ltn | grep -q 127.0.0.1:31555"); code != 0 {
		t.Fatal("the listener is gone")
	}
}
