//go:build !windows

package main

import "fmt"

func isWindowsAdmin() bool               { return false }
func writeAdminKeys(string) error        { return fmt.Errorf("Windows only") }
func writeAdminKeysAsAdmin(string) error { return fmt.Errorf("Windows only") }
func InstallSSHServer() error {
	return fmt.Errorf("install the OpenSSH server with your system's package manager (e.g. sudo apt install openssh-server)")
}
func openRemoteDesktopSettings() error { return fmt.Errorf("Windows only") }
