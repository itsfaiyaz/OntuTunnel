package main

import (
	"errors"
	"math/rand/v2"
	"net"
	"sort"
	"strings"
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

// LookupA asks Google then Cloudflare directly over UDP; the first that
// knows the name wins. It never reads this computer's hosts file or DNS
// cache, so it shows what the rest of the internet sees.
func LookupA(domain string) []string {
	for _, srv := range []string{"8.8.8.8:53", "1.1.1.1:53"} {
		if ips, err := queryA(srv, domain); err == nil && len(ips) > 0 {
			return ips
		}
	}
	return nil
}

func queryA(server, domain string) ([]string, error) {
	name, err := dnsmessage.NewName(strings.TrimSuffix(domain, ".") + ".")
	if err != nil {
		return nil, err
	}
	id := uint16(rand.IntN(1 << 16))
	msg := dnsmessage.Message{
		Header:    dnsmessage.Header{ID: id, RecursionDesired: true},
		Questions: []dnsmessage.Question{{Name: name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET}},
	}
	packet, err := msg.Pack()
	if err != nil {
		return nil, err
	}
	conn, err := net.DialTimeout("udp", server, 3*time.Second)
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(4 * time.Second))
	if _, err := conn.Write(packet); err != nil {
		return nil, err
	}
	buf := make([]byte, 1500)
	for {
		n, err := conn.Read(buf)
		if err != nil {
			return nil, err
		}
		var reply dnsmessage.Message
		if reply.Unpack(buf[:n]) != nil || reply.Header.ID != id {
			continue // not our answer
		}
		if reply.Header.RCode != dnsmessage.RCodeSuccess {
			return nil, errors.New(reply.Header.RCode.String())
		}
		var out []string
		for _, ans := range reply.Answers {
			// CNAME chains come back with their A records in the same answer
			if a, ok := ans.Body.(*dnsmessage.AResource); ok {
				out = append(out, net.IP(a.A[:]).String())
			}
		}
		sort.Strings(out)
		return out, nil
	}
}
