package main

import (
	"bufio"
	"io"
	"os"
	"os/exec"
	"runtime"
	"sync"
	"time"
)

// Runner runs a service's start command (e.g. `npm run dev`) and can
// restart it when it exits on its own (keep alive).
type Runner struct {
	mu        sync.Mutex
	cmd       *exec.Cmd
	requested bool
	state     string // running | stopped | exited
}

func shellCommand(command string) *exec.Cmd {
	if runtime.GOOS == "windows" {
		return exec.Command("cmd", "/C", command)
	}
	sh := os.Getenv("SHELL")
	if sh == "" {
		sh = "/bin/sh"
	}
	return exec.Command(sh, "-lc", "exec "+command)
}

func (r *Runner) Running() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.state == "running"
}

func (r *Runner) State() string {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.state == "" {
		return "stopped"
	}
	return r.state
}

func (r *Runner) Start(s Service, log func(string, bool), onExit func(requested bool)) error {
	r.mu.Lock()
	if r.state == "running" {
		r.mu.Unlock()
		return nil
	}
	cmd := shellCommand(s.StartCommand)
	hideWindow(cmd)
	if s.WorkingDirectory != "" {
		cmd.Dir = expandHome(s.WorkingDirectory)
	}
	out, _ := cmd.StdoutPipe()
	errp, _ := cmd.StderrPipe()
	if err := cmd.Start(); err != nil {
		r.mu.Unlock()
		return err
	}
	r.cmd, r.requested, r.state = cmd, false, "running"
	r.mu.Unlock()
	stream := func(rd io.Reader, isErr bool) {
		sc := bufio.NewScanner(rd)
		for sc.Scan() {
			log(sc.Text(), isErr)
		}
	}
	go stream(out, false)
	go stream(errp, true)
	go func() {
		_ = cmd.Wait()
		r.mu.Lock()
		req := r.requested
		r.state = map[bool]string{true: "stopped", false: "exited"}[req]
		r.mu.Unlock()
		onExit(req)
	}()
	return nil
}

func (r *Runner) Stop() {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.cmd != nil && r.cmd.Process != nil && r.state == "running" {
		r.requested = true
		_ = r.cmd.Process.Signal(os.Interrupt)
		p := r.cmd.Process
		go func() { time.Sleep(6 * time.Second); _ = p.Kill() }()
	}
}
