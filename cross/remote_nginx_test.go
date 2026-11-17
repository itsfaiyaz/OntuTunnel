package main

import (
	"strings"
	"testing"
)

// A WebSocket handshake only reaches the local app if nginx forwards the
// visitor's Upgrade and Connection headers in the main location block.
func TestNginxConfForwardsWebSocketUpgrade(t *testing.T) {
	s := Service{Domain: "app.example.com", RemotePort: 32041}
	for _, tls := range []bool{false, true} {
		conf := nginxConf(s, tls)
		start := strings.LastIndex(conf, "location / {\n        proxy_pass")
		if start < 0 {
			t.Fatalf("tls=%v: no proxy location block in:\n%s", tls, conf)
		}
		block := conf[start:]
		block = block[:strings.Index(block, "}")]
		for _, want := range []string{
			"proxy_http_version 1.1;",
			"proxy_set_header Upgrade $http_upgrade;",
			"proxy_set_header Connection $http_connection;",
		} {
			if !strings.Contains(block, want) {
				t.Errorf("tls=%v: location / is missing %q", tls, want)
			}
		}
	}
}
