//go:build !windows

package main

import (
	"fmt"
	"os"
	"os/exec"
	"runtime"
)

var awakeCmd *exec.Cmd

func keepAwakeOn() bool { return awakeCmd != nil }

// Linux: systemd-inhibit holds a sleep lock; macOS: caffeinate. Both are
// tied to this process, so the lock goes away if OntuTunnel quits.
func setKeepAwake(on bool) error {
	if !on {
		_ = awakeCmd.Process.Kill()
		_ = awakeCmd.Wait()
		awakeCmd = nil
		return nil
	}
	pid := fmt.Sprint(os.Getpid())
	var cmd *exec.Cmd
	if runtime.GOOS == "darwin" {
		cmd = exec.Command("caffeinate", "-i", "-w", pid)
	} else {
		if _, err := exec.LookPath("systemd-inhibit"); err != nil {
			return fmt.Errorf("systemd-inhibit not found")
		}
		cmd = exec.Command("systemd-inhibit", "--what=idle:sleep", "--who=OntuTunnel",
			"--why=Serving your sites", "--mode=block", "tail", "--pid="+pid, "-f", "/dev/null")
	}
	if err := cmd.Start(); err != nil {
		return err
	}
	awakeCmd = cmd
	return nil
}
