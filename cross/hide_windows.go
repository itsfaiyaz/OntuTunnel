//go:build windows

package main

import (
	"os/exec"
	"syscall"
)

// hideWindow keeps helper programs (netstat, cloudflared…) from flashing a console.
func hideWindow(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: 0x08000000}
}
