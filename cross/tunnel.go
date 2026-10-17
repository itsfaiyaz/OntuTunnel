package main

import (
	"fmt"
	"io"
	"net"
	"sort"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/ssh"
)

var errKicked = fmt.Errorf("reconnect requested")

// Forward: the server's 127.0.0.1:Remote leads to this computer's 127.0.0.1:Local.
type Forward struct{ Remote, Local int }

// Tunnel keeps one SSH connection with a remote listener per forward,
// and reconnects with back-off if it drops.
type Tunnel struct {
	mu       sync.Mutex
	state    string // stopped | connecting | connected | failed
	detail   string
	since    time.Time
	stop     chan struct{}
	client   *ssh.Client
	log      func(string, bool)
	forwards []Forward
	kick     chan string // network changed / woke up: reconnect now
}

func NewTunnel(log func(string, bool)) *Tunnel {
	t := &Tunnel{state: "stopped", log: log, kick: make(chan string, 1)}
	go t.watchNetwork()
	return t
}

// watchNetwork notices a new Wi-Fi / IP / hotspot, or that the computer slept
// (the clock jumps), and asks the tunnel to reconnect at once.
func (t *Tunnel) watchNetwork() {
	last := networkSignature()
	tick := time.Now()
	for range time.Tick(3 * time.Second) {
		now := time.Now()
		reason := ""
		if sig := networkSignature(); sig != last {
			if sig != "" {
				reason = "Network changed"
			}
			last = sig
		} else if now.Sub(tick) > 20*time.Second {
			reason = "Computer woke up"
		}
		tick = now
		if reason != "" {
			select {
			case t.kick <- reason:
			default:
			}
		}
	}
}

// networkSignature: this computer's non-loopback IP addresses.
func networkSignature() string {
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return ""
	}
	var list []string
	for _, a := range addrs {
		if ipn, ok := a.(*net.IPNet); ok && !ipn.IP.IsLoopback() && !ipn.IP.IsLinkLocalUnicast() {
			list = append(list, ipn.IP.String())
		}
	}
	sort.Strings(list)
	return strings.Join(list, ",")
}

func (t *Tunnel) State() (string, string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.state, t.detail
}

func (t *Tunnel) set(state, detail string) {
	t.mu.Lock()
	t.state, t.detail = state, detail
	if state == "connected" {
		t.since = time.Now()
	}
	t.mu.Unlock()
}

func (t *Tunnel) Start(store *Store, forwards []Forward) {
	t.Stop()
	t.mu.Lock()
	t.stop = make(chan struct{})
	t.forwards = forwards
	stop := t.stop
	t.mu.Unlock()
	go t.loop(store, forwards, stop)
}

func (t *Tunnel) Stop() {
	t.mu.Lock()
	if t.stop != nil {
		close(t.stop)
		t.stop = nil
	}
	if t.client != nil {
		t.client.Close()
		t.client = nil
	}
	t.state, t.detail = "stopped", ""
	t.mu.Unlock()
}

func (t *Tunnel) loop(store *Store, forwards []Forward, stop chan struct{}) {
	delay := 3 * time.Second
	for {
		select {
		case <-stop:
			return
		default:
		}
		if len(forwards) == 0 {
			t.set("failed", "No services to tunnel yet.")
			return
		}
		t.set("connecting", "")
		err := t.session(store, forwards, stop)
		if err == errKicked {
			delay = 3 * time.Second
			time.Sleep(1500 * time.Millisecond) // let the new network settle
			continue
		}
		select {
		case <-stop:
			return
		default:
		}
		msg := "connection closed"
		if err != nil {
			msg = err.Error()
		}
		t.set("failed", msg)
		t.log(fmt.Sprintf("Tunnel dropped: %s — reconnecting in %d s", msg, int(delay.Seconds())), true)
		select {
		case <-stop:
			return
		case reason := <-t.kick:
			t.log(reason+" — reconnecting now", false)
			delay = 3 * time.Second
			continue
		case <-time.After(delay):
		}
		if delay < 30*time.Second {
			delay *= 2
		}
	}
}

func (t *Tunnel) session(store *Store, forwards []Forward, stop chan struct{}) error {
	client, err := Dial(store)
	if err != nil {
		return err
	}
	t.mu.Lock()
	t.client = client
	t.mu.Unlock()
	defer client.Close()

	// end the server's leftover session from before a network change
	ports := make([]int, 0, len(forwards))
	for _, f := range forwards {
		ports = append(ports, f.Remote)
	}
	if out, _, _ := runOn(client, freeStalePortsScript(ports), 15*time.Second); strings.Contains(out, "freed") {
		t.log("Closed the server's old connection from before the network change", false)
	}

	var listeners []net.Listener
	for _, f := range forwards {
		l, err := client.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", f.Remote))
		if err != nil {
			for _, x := range listeners {
				x.Close()
			}
			return fmt.Errorf("server port %d: %v", f.Remote, err)
		}
		listeners = append(listeners, l)
		go accept(l, f.Local)
	}
	var parts []string
	for _, f := range forwards {
		parts = append(parts, fmt.Sprintf("server:%d → local:%d", f.Remote, f.Local))
	}
	t.set("connected", "")
	t.log("Tunnel up: "+strings.Join(parts, ", "), false)

	// keep-alive: detect a dead connection within ~30 s
	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()
	failures := 0
	for {
		select {
		case <-stop:
			return nil
		case reason := <-t.kick:
			t.log(reason+" — reconnecting now", false)
			return errKicked
		case <-ticker.C:
			if _, _, err := client.SendRequest("keepalive@ontutunnel", true, nil); err != nil {
				failures++
				if failures >= 3 {
					return fmt.Errorf("server stopped answering")
				}
			} else {
				failures = 0
			}
		}
	}
}

func accept(l net.Listener, local int) {
	for {
		remote, err := l.Accept()
		if err != nil {
			return
		}
		go func() {
			defer remote.Close()
			c, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", local), 5*time.Second)
			if err != nil {
				c, err = net.DialTimeout("tcp", fmt.Sprintf("[::1]:%d", local), 5*time.Second)
				if err != nil {
					return
				}
			}
			defer c.Close()
			pipe(remote, c)
		}()
	}
}

func pipe(a, b net.Conn) {
	done := make(chan struct{}, 2)
	go func() { io.Copy(a, b); done <- struct{}{} }()
	go func() { io.Copy(b, a); done <- struct{}{} }()
	<-done
}
