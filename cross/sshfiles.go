package main

import (
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"

	"golang.org/x/crypto/ssh"
)

// ---------- ~/.ssh/config: short names for servers ----------

// sshConfigOverride / authorizedKeysOverride are used by tests.
var sshConfigOverride, authorizedKeysOverride string

func sshConfigPath() string {
	if sshConfigOverride != "" {
		return sshConfigOverride
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".ssh", "config")
}

type SSHConfigEntry struct {
	Alias        string `json:"alias"`
	HostName     string `json:"hostName"`
	User         string `json:"user"`
	Port         string `json:"port"`
	IdentityFile string `json:"identityFile"`
}

func readFileText(p string) string {
	b, _ := os.ReadFile(p)
	return strings.ReplaceAll(string(b), "\r\n", "\n")
}

func sshFields(line string) []string {
	return strings.FieldsFunc(line, func(r rune) bool { return r == ' ' || r == '\t' || r == '=' })
}

// sshConfigEntries: Host blocks with a single name (wildcards/lists skipped).
func sshConfigEntries() []SSHConfigEntry {
	var out []SSHConfigEntry
	var cur *SSHConfigEntry
	flush := func() {
		if cur != nil {
			out = append(out, *cur)
		}
		cur = nil
	}
	for _, raw := range strings.Split(readFileText(sshConfigPath()), "\n") {
		line := strings.TrimSpace(raw)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		f := sshFields(line)
		if len(f) < 2 {
			continue
		}
		key, value := strings.ToLower(f[0]), strings.Join(f[1:], " ")
		switch key {
		case "host", "match":
			flush()
			if key == "host" && len(f) == 2 && !strings.ContainsAny(value, "*?") {
				cur = &SSHConfigEntry{Alias: value}
			}
		case "hostname":
			if cur != nil {
				cur.HostName = value
			}
		case "user":
			if cur != nil {
				cur.User = value
			}
		case "port":
			if cur != nil {
				cur.Port = value
			}
		case "identityfile":
			if cur != nil {
				cur.IdentityFile = value
			}
		}
	}
	flush()
	return out
}

var validAlias = regexp.MustCompile(`^[A-Za-z0-9._-]{1,64}$`)
var validSSHHost = regexp.MustCompile(`^[A-Za-z0-9.:_-]{1,253}$`)

func sshConfigBlock(alias, hostName, user string, port int, identityFile string) string {
	b := "Host " + alias + "\n    HostName " + hostName + "\n"
	if user != "" {
		b += "    User " + user + "\n"
	}
	if port != 0 && port != 22 {
		b += fmt.Sprintf("    Port %d\n", port)
	}
	if identityFile != "" {
		b += "    IdentityFile " + identityFile + "\n"
	}
	return b
}

// upsertSSHConfig adds "Host alias" or updates HostName/User/Port/IdentityFile
// in that block; the block's other settings and the rest of the file stay.
func upsertSSHConfig(alias, hostName, user string, port int, identityFile string) error {
	if !validAlias.MatchString(alias) {
		return fmt.Errorf("name: letters, numbers, . _ - only (e.g. adimyra-vm)")
	}
	if !validSSHHost.MatchString(hostName) {
		return fmt.Errorf("%q is not a valid server address", hostName)
	}
	if user != "" && !validUser.MatchString(strings.ToLower(user)) {
		return fmt.Errorf("%q is not a valid user name", user)
	}
	newLines := strings.Split(strings.TrimSuffix(sshConfigBlock(alias, hostName, user, port, identityFile), "\n"), "\n")
	old := readFileText(sshConfigPath())
	lines := strings.Split(old, "\n")
	isHeader := func(l string) bool {
		f := sshFields(strings.TrimSpace(l))
		return len(f) > 0 && (strings.EqualFold(f[0], "host") || strings.EqualFold(f[0], "match"))
	}
	start := -1
	for i, l := range lines {
		f := sshFields(strings.TrimSpace(l))
		if len(f) == 2 && strings.EqualFold(f[0], "host") && f[1] == alias {
			start = i
			break
		}
	}
	if start >= 0 {
		end := start + 1
		for end < len(lines) && !isHeader(lines[end]) {
			end++
		}
		for end > start+1 && strings.TrimSpace(lines[end-1]) == "" {
			end--
		}
		managed := map[string]bool{"hostname": true, "user": true, "port": true, "identityfile": true}
		var others []string
		for _, l := range lines[start+1 : end] {
			f := sshFields(strings.TrimSpace(l))
			if len(f) == 0 || !managed[strings.ToLower(f[0])] {
				others = append(others, l)
			}
		}
		repl := append(append([]string{}, newLines...), others...)
		lines = append(lines[:start], append(repl, lines[end:]...)...)
	} else {
		for len(lines) > 0 && strings.TrimSpace(lines[len(lines)-1]) == "" {
			lines = lines[:len(lines)-1]
		}
		if len(lines) > 0 {
			lines = append(lines, "")
		}
		lines = append(lines, newLines...)
	}
	content := strings.Join(lines, "\n")
	if !strings.HasSuffix(content, "\n") {
		content += "\n"
	}
	return writeSSHFile(sshConfigPath(), content, old, "config.ontutunnel-backup", func() error {
		// ssh must accept the file; if ssh isn't installed the check is skipped
		bin, err := exec.LookPath("ssh")
		if err != nil {
			return nil
		}
		cmd := exec.Command(bin, "-G", "-F", sshConfigPath(), alias)
		hideWindow(cmd)
		if out, err := cmd.CombinedOutput(); err != nil {
			return fmt.Errorf("ssh didn't accept the file, so it was put back: %s", strings.TrimSpace(string(out)))
		}
		return nil
	})
}

// writeSSHFile writes with a backup and checks it; the old file comes back if the check fails.
func writeSSHFile(path, content, old, backupName string, check func() error) error {
	_ = os.MkdirAll(filepath.Dir(path), 0o700)
	if old != "" {
		_ = os.WriteFile(filepath.Join(filepath.Dir(path), backupName), []byte(old), 0o600)
	}
	if runtime.GOOS == "windows" {
		content = strings.ReplaceAll(content, "\n", "\r\n")
	}
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		return err
	}
	if err := check(); err != nil {
		_ = os.WriteFile(path, []byte(old), 0o600)
		return err
	}
	return nil
}

// openForEditing opens a file in a text editor (Windows: Notepad; macOS:
// TextEdit; Linux: the desktop's editor, or nano in a terminal).
func openForEditing(path string) error {
	_ = os.MkdirAll(filepath.Dir(path), 0o700)
	if _, err := os.Stat(path); err != nil {
		_ = os.WriteFile(path, nil, 0o600)
	}
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "windows":
		cmd = exec.Command("notepad.exe", path)
	case "darwin":
		cmd = exec.Command("open", "-e", path)
	default:
		if t, err := exec.LookPath("x-terminal-emulator"); err == nil {
			cmd = exec.Command(t, "-e", "nano", path)
		} else {
			cmd = exec.Command("xdg-open", path)
		}
	}
	return cmd.Start()
}

func thisComputerAlias() string {
	h, _ := os.Hostname()
	h = strings.ToLower(strings.TrimSuffix(h, ".local"))
	var b strings.Builder
	for _, r := range h {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') || r == '-' {
			b.WriteRune(r)
		} else {
			b.WriteRune('-')
		}
	}
	s := strings.Trim(b.String(), "-")
	if s == "" {
		return "my-pc"
	}
	return s
}

func currentUserName() string {
	if u, err := user.Current(); err == nil {
		name := u.Username
		if i := strings.LastIndex(name, `\`); i >= 0 { // DOMAIN\user on Windows
			name = name[i+1:]
		}
		return name
	}
	return "user"
}

// ---------- authorized keys: computers allowed in without a password ----------

// authorizedKeysPath: ~/.ssh/authorized_keys. On Windows an administrator's
// keys live in C:\ProgramData\ssh\administrators_authorized_keys (that is
// where Windows' OpenSSH server looks for them).
func authorizedKeysPath() (path string, needsAdmin bool) {
	if authorizedKeysOverride != "" {
		return authorizedKeysOverride, false
	}
	if runtime.GOOS == "windows" && isWindowsAdmin() {
		return filepath.Join(os.Getenv("ProgramData"), "ssh", "administrators_authorized_keys"), true
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".ssh", "authorized_keys"), false
}

type AuthorizedKey struct {
	Line  string `json:"line"`
	Type  string `json:"type"`
	Label string `json:"label"`
}

func authorizedKeys() []AuthorizedKey {
	p, _ := authorizedKeysPath()
	var out []AuthorizedKey
	for _, l := range strings.Split(readFileText(p), "\n") {
		l = strings.TrimSpace(l)
		if l == "" || strings.HasPrefix(l, "#") {
			continue
		}
		k := AuthorizedKey{Line: l, Type: "key", Label: l}
		if pub, comment, _, _, err := ssh.ParseAuthorizedKey([]byte(l)); err == nil {
			k.Type = strings.ToUpper(strings.TrimPrefix(pub.Type(), "ssh-"))
			k.Label = comment
			if k.Label == "" {
				fp := ssh.FingerprintSHA256(pub)
				k.Label = "…" + fp[len(fp)-12:]
			}
		}
		out = append(out, k)
	}
	return out
}

func addAuthorizedKey(text string) error {
	line := strings.TrimSpace(text)
	if strings.Contains(line, "PRIVATE KEY") {
		return fmt.Errorf("that's a private key — never share it. Paste the .pub file (it starts with ssh-ed25519 or ssh-rsa)")
	}
	if strings.Contains(line, "\n") {
		return fmt.Errorf("paste one key at a time (one line)")
	}
	pub, _, _, _, err := ssh.ParseAuthorizedKey([]byte(line))
	if err != nil {
		return fmt.Errorf("that isn't an SSH public key; it starts with ssh-ed25519 (or ssh-rsa) and comes from a .pub file")
	}
	var lines []string
	for _, k := range authorizedKeys() {
		if other, _, _, _, err := ssh.ParseAuthorizedKey([]byte(k.Line)); err == nil && ssh.FingerprintSHA256(other) == ssh.FingerprintSHA256(pub) {
			return fmt.Errorf("this key is already allowed")
		}
		lines = append(lines, k.Line)
	}
	return writeAuthorizedKeys(append(lines, line))
}

func removeAuthorizedKey(line string) error {
	var lines []string
	for _, k := range authorizedKeys() {
		if k.Line != line {
			lines = append(lines, k.Line)
		}
	}
	return writeAuthorizedKeys(lines)
}

func writeAuthorizedKeys(lines []string) error {
	p, needsAdmin := authorizedKeysPath()
	var comments []string
	for _, l := range strings.Split(readFileText(p), "\n") {
		if strings.HasPrefix(l, "#") {
			comments = append(comments, l)
		}
	}
	content := strings.Join(append(comments, lines...), "\n") + "\n"
	if needsAdmin {
		return writeAdminKeysAsAdmin(content)
	}
	return writeSSHFile(p, content, readFileText(p), "authorized_keys.ontutunnel-backup", func() error { return nil })
}
