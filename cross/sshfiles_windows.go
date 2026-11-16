//go:build windows

package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// isWindowsAdmin: the user is in the Administrators group (SID S-1-5-32-544).
func isWindowsAdmin() bool {
	out, _ := run("whoami", "/groups")
	return strings.Contains(out, "S-1-5-32-544")
}

func adminKeysPath() string {
	return filepath.Join(os.Getenv("ProgramData"), "ssh", "administrators_authorized_keys")
}

// writeAdminKeys writes administrators_authorized_keys with the permissions
// OpenSSH requires (only Administrators and SYSTEM). Needs admin rights.
func writeAdminKeys(content string) error {
	for _, l := range strings.Split(content, "\n") {
		l = strings.TrimSpace(l)
		if l == "" || strings.HasPrefix(l, "#") {
			continue
		}
		if !strings.HasPrefix(l, "ssh-") && !strings.HasPrefix(l, "ecdsa-") && !strings.HasPrefix(l, "sk-") {
			return fmt.Errorf("not a public key line: %q", l)
		}
	}
	p := adminKeysPath()
	_ = os.MkdirAll(filepath.Dir(p), 0o755)
	if err := os.WriteFile(p, []byte(strings.ReplaceAll(content, "\n", "\r\n")), 0o600); err != nil {
		return err
	}
	cmd := exec.Command("icacls", p, "/inheritance:r", "/grant", "*S-1-5-32-544:F", "/grant", "*S-1-5-18:F")
	hideWindow(cmd)
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("icacls: %s", strings.TrimSpace(string(out)))
	}
	return nil
}

// writeAdminKeysAsAdmin: direct if OntuTunnel already runs elevated, else the
// usual Windows "Yes/No" prompt for ontutunnel.exe -adminkeys-write <file>.
func writeAdminKeysAsAdmin(content string) error {
	if err := writeAdminKeys(content); err == nil {
		return nil
	}
	tmp := filepath.Join(DataDir(), "admin_keys.new")
	if err := os.WriteFile(tmp, []byte(content), 0o600); err != nil {
		return err
	}
	defer os.Remove(tmp)
	self, err := os.Executable()
	if err != nil {
		return err
	}
	return runElevated(self, "-adminkeys-write", `"`+tmp+`"`)
}

// runElevated runs a program with admin rights (Windows asks Yes/No).
func runElevated(exe string, args ...string) error {
	q := func(s string) string { return "'" + strings.ReplaceAll(s, "'", "''") + "'" }
	var qa []string
	for _, a := range args {
		qa = append(qa, q(a))
	}
	argList := ""
	if len(qa) > 0 {
		argList = " -ArgumentList " + strings.Join(qa, ",")
	}
	ps := fmt.Sprintf("$p = Start-Process -FilePath %s%s -Verb RunAs -WindowStyle Hidden -Wait -PassThru; exit $p.ExitCode", q(exe), argList)
	cmd := exec.Command("powershell", "-NoProfile", "-Command", ps)
	hideWindow(cmd)
	if out, err := cmd.CombinedOutput(); err != nil {
		msg := strings.TrimSpace(string(out))
		if msg == "" {
			msg = "admin permission was not given"
		}
		return fmt.Errorf("%s", msg)
	}
	return nil
}

// InstallSSHServer turns on Windows' own OpenSSH Server (asks for admin).
func InstallSSHServer() error {
	script := "Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null; Set-Service -Name sshd -StartupType Automatic; Start-Service sshd"
	return runElevated("powershell", "-NoProfile", "-Command", script)
}

func openRemoteDesktopSettings() error {
	cmd := exec.Command("cmd", "/c", "start", "ms-settings:remotedesktop")
	hideWindow(cmd)
	return cmd.Start()
}
