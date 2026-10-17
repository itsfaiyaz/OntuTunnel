package main

import (
	"context"
	"crypto/tls"
	"fmt"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/acme/autocert"
)

// Proxy is OntuTunnel's own web front for "My static IP" (ports 80/443 with
// Let's Encrypt) and "Cloudflare Tunnel" (loopback port behind cloudflared).
// It routes by host name to each service's local port.
type Proxy struct {
	mu      sync.Mutex
	routes  map[string]Service
	servers []*http.Server
	state   string
	detail  string
	httpsOn bool
	certMgr *autocert.Manager
	log     func(string, bool)
}

func NewProxy(log func(string, bool)) *Proxy {
	return &Proxy{routes: map[string]Service{}, state: "stopped", log: log}
}

func (p *Proxy) State() (string, string, bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.state, p.detail, p.httpsOn
}

func (p *Proxy) SetRoutes(services []Service) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.routes = map[string]Service{}
	for _, s := range services {
		if s.Enabled && s.NormalizedDomain() != "" {
			p.routes[s.NormalizedDomain()] = s
		}
	}
}

func (p *Proxy) route(host string) (Service, bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	h := strings.ToLower(host)
	if i := strings.LastIndex(h, ":"); i > 0 && !strings.Contains(h[i:], "]") {
		h = h[:i]
	}
	s, ok := p.routes[h]
	return s, ok
}

// handler: forwards to localhost:<port>, /socket.io to the realtime port.
func (p *Proxy) handler(forwardedProto string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		s, ok := p.route(r.Host)
		if !ok {
			http.Error(w, "OntuTunnel has no service for "+r.Host, http.StatusNotFound)
			return
		}
		port := s.LocalPort
		if s.SocketPort > 0 && strings.HasPrefix(r.URL.Path, "/socket.io") {
			port = s.SocketPort
		}
		target, _ := url.Parse(fmt.Sprintf("http://127.0.0.1:%d", port))
		rp := httputil.NewSingleHostReverseProxy(target)
		orig := rp.Director
		rp.Director = func(req *http.Request) {
			host := req.Host
			orig(req)
			req.Host = host
			req.Header.Del("X-Frappe-Site-Name")
			if s.FrappeSite != "" {
				req.Header.Set("X-Frappe-Site-Name", s.FrappeSite)
			}
			proto := forwardedProto
			if proto == "" {
				proto = "http"
				if r.TLS != nil {
					proto = "https"
				}
			}
			req.Header.Set("X-Forwarded-Proto", proto)
			req.Header.Set("X-Forwarded-Host", host)
		}
		rp.ErrorHandler = func(w http.ResponseWriter, _ *http.Request, _ error) {
			http.Error(w, fmt.Sprintf("The local app on port %d is not running.", port), http.StatusBadGateway)
		}
		rp.ServeHTTP(w, r)
	})
}

func (p *Proxy) Stop() {
	p.mu.Lock()
	servers := p.servers
	p.servers = nil
	p.state, p.detail, p.httpsOn = "stopped", "", false
	p.mu.Unlock()
	for _, s := range servers {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		_ = s.Shutdown(ctx)
		cancel()
	}
}

func (p *Proxy) serve(addr string, h http.Handler, tlsCfg *tls.Config) error {
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return err
	}
	srv := &http.Server{Handler: h, TLSConfig: tlsCfg, ReadHeaderTimeout: 20 * time.Second}
	p.mu.Lock()
	p.servers = append(p.servers, srv)
	p.mu.Unlock()
	go func() {
		if tlsCfg != nil {
			_ = srv.Serve(tls.NewListener(ln, tlsCfg))
		} else {
			_ = srv.Serve(ln)
		}
	}()
	return nil
}

// StartStatic: port 80 (+ 443 with automatic certificates).
func (p *Proxy) StartStatic(cfg StaticIPConfig) {
	p.Stop()
	allowed := func(_ context.Context, host string) error {
		if _, ok := p.route(host); ok {
			return nil
		}
		return fmt.Errorf("no service for %s", host)
	}
	mgr := &autocert.Manager{
		Prompt:     autocert.AcceptTOS,
		Cache:      autocert.DirCache(filepath.Join(DataDir(), "certs")),
		HostPolicy: allowed,
		Email:      cfg.Email,
	}
	p.mu.Lock()
	p.certMgr = mgr
	p.mu.Unlock()

	app := p.handler("")
	var httpHandler http.Handler = app
	if cfg.HTTPSEnabled && cfg.RedirectToHTTPS {
		httpHandler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if _, ok := p.route(r.Host); ok {
				http.Redirect(w, r, "https://"+strings.Split(r.Host, ":")[0]+r.URL.RequestURI(), http.StatusMovedPermanently)
				return
			}
			app.ServeHTTP(w, r)
		})
	}
	if err := p.serve(":80", mgr.HTTPHandler(httpHandler), nil); err != nil {
		p.setState("failed", "Port 80: "+portError(err))
		return
	}
	if cfg.HTTPSEnabled {
		if err := p.serve(":443", app, mgr.TLSConfig()); err != nil {
			p.setState("failed", "Port 443: "+portError(err))
			return
		}
		p.mu.Lock()
		p.httpsOn = true
		p.mu.Unlock()
	}
	p.setState("listening", "80"+map[bool]string{true: " + 443 (HTTPS)", false: ""}[cfg.HTTPSEnabled])
	p.log("Serving on port 80"+map[bool]string{true: " and 443 with automatic HTTPS", false: ""}[cfg.HTTPSEnabled], false)
}

// StartLoopback: plain HTTP on 127.0.0.1 for cloudflared.
func (p *Proxy) StartLoopback(port int) {
	p.Stop()
	if err := p.serve(fmt.Sprintf("127.0.0.1:%d", port), p.handler("https"), nil); err != nil {
		p.setState("failed", portError(err))
		return
	}
	p.setState("listening", fmt.Sprintf("127.0.0.1:%d", port))
}

func (p *Proxy) setState(s, d string) {
	p.mu.Lock()
	p.state, p.detail = s, d
	p.mu.Unlock()
}

func portError(err error) string {
	m := err.Error()
	if strings.Contains(m, "address already in use") || strings.Contains(m, "Only one usage") {
		return "already used by another program"
	}
	if strings.Contains(m, "permission denied") {
		return "permission denied (on Linux run once: sudo setcap cap_net_bind_service=+ep $(which ontutunnel))"
	}
	return m
}
