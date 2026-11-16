package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/crypto/ssh"
)

func TestSSHConfigUpsert(t *testing.T) {
	dir := t.TempDir()
	sshConfigOverride = filepath.Join(dir, "config")
	defer func() { sshConfigOverride = "" }()
	orig := "Host other\n    HostName 10.0.0.1\n\nHost adimyra-vm\n    HostName 34.47.187.74\n    User faiyaz\n    IdentitiesOnly yes\n\nHost last\n    HostName 10.0.0.9\n"
	os.WriteFile(sshConfigOverride, []byte(orig), 0o600)

	if err := upsertSSHConfig("adimyra-vm", "34.47.187.75", "faiyaz", 22, "~/.ssh/id_ed25519_servers"); err != nil {
		t.Fatal(err)
	}
	got := readFileText(sshConfigOverride)
	if !strings.Contains(got, "HostName 34.47.187.75") || !strings.Contains(got, "IdentitiesOnly yes") || !strings.Contains(got, "Host other") || !strings.Contains(got, "Host last") {
		t.Fatalf("update lost something:\n%s", got)
	}
	if err := upsertSSHConfig("new-box", "203.0.113.9", "ubuntu", 2222, ""); err != nil {
		t.Fatal(err)
	}
	if err := upsertSSHConfig("new-box", "203.0.113.10", "ubuntu", 2222, ""); err != nil {
		t.Fatal(err)
	}
	got = readFileText(sshConfigOverride)
	if strings.Count(got, "Host new-box") != 1 || !strings.Contains(got, "Port 2222") || strings.Contains(got, "203.0.113.9") {
		t.Fatalf("new entry wrong:\n%s", got)
	}
	es := sshConfigEntries()
	if len(es) != 4 || es[1].Alias != "adimyra-vm" || es[1].HostName != "34.47.187.75" {
		t.Fatalf("entries: %+v", es)
	}
	if upsertSSHConfig("bad name", "x", "", 22, "") == nil || upsertSSHConfig("ok", "bad host;rm", "", 22, "") == nil {
		t.Fatal("bad input accepted")
	}
}

func TestAuthorizedKeys(t *testing.T) {
	authorizedKeysOverride = filepath.Join(t.TempDir(), "authorized_keys")
	defer func() { authorizedKeysOverride = "" }()
	pub, _, _ := ed25519.GenerateKey(rand.Reader)
	sp, _ := ssh.NewPublicKey(pub)
	line := strings.TrimSpace(string(ssh.MarshalAuthorizedKey(sp))) + " me@other-pc"
	if err := addAuthorizedKey(line); err != nil {
		t.Fatal(err)
	}
	if err := addAuthorizedKey(line); err == nil {
		t.Fatal("same key added twice")
	}
	if addAuthorizedKey("hello world") == nil || addAuthorizedKey("-----BEGIN OPENSSH PRIVATE KEY-----") == nil {
		t.Fatal("junk or private key accepted")
	}
	ks := authorizedKeys()
	if len(ks) != 1 || ks[0].Label != "me@other-pc" || ks[0].Type != "ED25519" {
		t.Fatalf("keys: %+v", ks)
	}
	if err := removeAuthorizedKey(ks[0].Line); err != nil || len(authorizedKeys()) != 0 {
		t.Fatalf("remove: %v", err)
	}
}
