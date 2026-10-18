package main

import (
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
