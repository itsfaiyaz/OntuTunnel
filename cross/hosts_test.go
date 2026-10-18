package main

import (
	"os"
	"strings"
	"testing"
)

func TestHostsBlock(t *testing.T) {
	orig := "# comment\n192.168.1.5\tnas.local\n"
	out := buildHosts(orig, []string{"meet.example.com", "shop.example.com"})
	out = strings.ReplaceAll(out, "\r\n", "\n")
	rest, ours := splitHosts(out)
	if rest != orig {
		t.Fatalf("user lines changed:\n%q", rest)
	}
	if strings.Join(ours, ",") != "meet.example.com,shop.example.com" {
		t.Fatalf("block = %v", ours)
	}
	// removing the block gives the original file back
	if back := strings.ReplaceAll(buildHosts(rest, nil), "\r\n", "\n"); back != orig {
		t.Fatalf("not restored: %q", back)
	}
	if !validHost.MatchString("meet.adimyra.in") || validHost.MatchString("bad host;rm") {
		t.Fatal("domain check")
	}
}

func TestLookupAIgnoresHostsFile(t *testing.T) {
	ips := LookupA("one.one.one.one")
	if len(ips) == 0 {
		t.Skip("no internet")
	}
	if !contains(ips, "1.1.1.1") {
		t.Fatalf("one.one.one.one = %v", ips)
	}
}

func TestHostEdits(t *testing.T) {
	dir := t.TempDir()
	hostsPathOverride = dir + "/hosts"
	defer func() { hostsPathOverride = "" }()
	orig := "# comment\n127.0.0.1\tlocalhost\n192.168.29.104   meet.example.com\n\n" + hostsBegin + "\n127.0.0.1\tshop.example.com\n" + hostsEnd + "\n"
	if err := writeHostsContent(orig); err != nil {
		t.Fatal(err)
	}
	es := hostEntries()
	if len(es) != 3 || es[0].Source != "system" || es[1].Source != "you" || es[2].Source != "ontutunnel" {
		t.Fatalf("entries: %+v", es)
	}
	// change the user's line
	c, err := applyHostEdit(HostEdit{Op: "update", Line: es[1].Line, Raw: es[1].Raw, IP: "127.0.0.1", Names: "meet.example.com"})
	if err != nil || !strings.Contains(c, "127.0.0.1\tmeet.example.com") || strings.Contains(c, "192.168.29.104") {
		t.Fatalf("update: %v\n%s", err, c)
	}
	// add goes before OntuTunnel's block
	_ = writeHostsContent(c)
	c, err = applyHostEdit(HostEdit{Op: "add", Line: -1, IP: "10.0.0.5", Names: "nas.example.com"})
	if err != nil || strings.Index(c, "nas.example.com") > strings.Index(c, hostsBegin) {
		t.Fatalf("add: %v\n%s", err, c)
	}
	// delete; a stale line is refused
	_ = writeHostsContent(c)
	es = hostEntries()
	if _, err := applyHostEdit(HostEdit{Op: "delete", Line: es[1].Line, Raw: "something else"}); err == nil {
		t.Fatal("stale edit accepted")
	}
	c, err = applyHostEdit(HostEdit{Op: "delete", Line: es[1].Line, Raw: es[1].Raw})
	if err != nil || strings.Contains(c, "meet.example.com") || !strings.Contains(c, "shop.example.com") {
		t.Fatalf("delete: %v\n%s", err, c)
	}
	// bad input and a non-hosts file are refused
	if _, err := applyHostEdit(HostEdit{Op: "add", Line: -1, IP: "not-ip", Names: "x.example.com"}); err == nil {
		t.Fatal("bad IP accepted")
	}
	if validateHosts("hello world\n") == nil {
		t.Fatal("garbage accepted")
	}
}

func TestCreateKey(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("USERPROFILE", os.Getenv("HOME"))
	p, err := createKey("Faiyaz")
	if err != nil {
		t.Fatal(err)
	}
	ks := sshKeyInfos()
	if len(ks) != 1 || ks[0].Path != p || ks[0].CloudUser != "faiyaz" || ks[0].Type != "ED25519" {
		t.Fatalf("keys: %+v", ks)
	}
	if _, err := createKey("bad user!"); err == nil {
		t.Fatal("bad user accepted")
	}
	p2, _ := createKey("faiyaz")
	if p2 == p {
		t.Fatal("overwrote an existing key")
	}
}
