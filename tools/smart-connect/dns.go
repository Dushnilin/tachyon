package main

import (
	"context"
	"crypto/rand"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"time"
)

type dnsResult struct {
	IPs []net.IP
	TTL time.Duration
	err error
}

// Use the section's forced core DNS listener, never the system resolver (which
// may return FakeIP). Keep the record TTL so a cached preference cannot pin an
// address beyond its DNS lifetime. Both A and AAAA are queried.
func resolve(ctx context.Context, server, host string) dnsResult {
	return resolveTypes(ctx, server, host, []uint16{1, 28})
}

func ipv6Available() bool {
	addresses, err := net.InterfaceAddrs()
	if err != nil {
		return false
	}
	for _, address := range addresses {
		ip, _, err := net.ParseCIDR(address.String())
		if err == nil && ip.To4() == nil && ip.IsGlobalUnicast() && !ip.IsPrivate() {
			return true
		}
	}
	return false
}

func resolveForNetwork(ctx context.Context, server, host string) dnsResult {
	kinds := []uint16{1}
	if ipv6Available() {
		kinds = append(kinds, 28)
	}
	return resolveTypes(ctx, server, host, kinds)
}

func resolveTypes(ctx context.Context, server, host string, kinds []uint16) dnsResult {
	ch := make(chan dnsResult, len(kinds))
	for _, kind := range kinds {
		go func(k uint16) { ch <- dnsQuery(ctx, server, host, k) }(kind)
	}
	r := dnsResult{TTL: time.Hour}
	for i := 0; i < len(kinds); i++ {
		select {
		case a := <-ch:
			r.IPs = append(r.IPs, a.IPs...)
			if len(a.IPs) > 0 && a.TTL < r.TTL {
				r.TTL = a.TTL
			}
			if a.err != nil {
				r.err = a.err
			}
		case <-ctx.Done():
			if len(r.IPs) > 0 {
				r.err = nil
				return r
			}
			r.err = ctx.Err()
			return r
		}
	}
	if len(r.IPs) > 0 {
		r.err = nil
	} else if r.err == nil {
		r.err = errors.New("no public DNS addresses")
	}
	return r
}

func dnsQuery(ctx context.Context, server, host string, kind uint16) dnsResult {
	q := make([]byte, 12)
	rand.Read(q[:2])
	q[2] = 1
	q[5] = 1
	for _, s := range splitLabels(host) {
		q = append(q, byte(len(s)))
		q = append(q, []byte(s)...)
	}
	q = append(q, 0, byte(kind>>8), byte(kind), 0, 1)
	c, err := (&net.Dialer{}).DialContext(ctx, "tcp", server)
	if err != nil {
		return dnsResult{err: err}
	}
	defer c.Close()
	stop := context.AfterFunc(ctx, func() { c.Close() })
	defer stop()
	if deadline, ok := ctx.Deadline(); ok {
		c.SetDeadline(deadline)
	}
	packet := append([]byte{byte(len(q) >> 8), byte(len(q))}, q...)
	if _, err = c.Write(packet); err != nil {
		return dnsResult{err: err}
	}
	var size [2]byte
	if _, err = io.ReadFull(c, size[:]); err != nil {
		return dnsResult{err: err}
	}
	b := make([]byte, binary.BigEndian.Uint16(size[:]))
	if _, err = io.ReadFull(c, b); err != nil {
		return dnsResult{err: err}
	}
	return parseDNS(b, q[:2], kind)
}

func splitLabels(host string) []string {
	var out []string
	start := 0
	for i := 0; i < len(host); i++ {
		if host[i] == '.' {
			out = append(out, host[start:i])
			start = i + 1
		}
	}
	return append(out, host[start:])
}

func skipName(b []byte, p int) (int, error) {
	for count := 0; count < 128 && p < len(b); count++ {
		n := int(b[p])
		p++
		if n == 0 {
			return p, nil
		}
		if n&0xc0 == 0xc0 {
			if p < len(b) {
				return p + 1, nil
			}
			break
		}
		if n > 63 || p+n > len(b) {
			break
		}
		p += n
	}
	return 0, errors.New("invalid DNS name")
}

func publicIP(ip net.IP) bool {
	if !ip.IsGlobalUnicast() || ip.IsPrivate() || ip.IsLoopback() || ip.IsLinkLocalUnicast() {
		return false
	}
	if v := ip.To4(); v != nil {
		return !(v[0] == 198 && (v[1] == 18 || v[1] == 19) || v[0] == 100 && v[1] >= 64 && v[1] <= 127 || v[0] == 0)
	}
	return true
}

func parseDNS(b, id []byte, kind uint16) dnsResult {
	bad := dnsResult{err: errors.New("invalid DNS response")}
	if len(b) < 12 || b[0] != id[0] || b[1] != id[1] || b[2]&0x80 == 0 || b[3]&15 != 0 {
		return bad
	}
	p := 12
	for i := 0; i < int(binary.BigEndian.Uint16(b[4:6])); i++ {
		n, err := skipName(b, p)
		if err != nil || n+4 > len(b) {
			return bad
		}
		p = n + 4
	}
	r := dnsResult{TTL: time.Hour}
	seen := map[string]bool{}
	for i := 0; i < int(binary.BigEndian.Uint16(b[6:8])); i++ {
		n, err := skipName(b, p)
		if err != nil || n+10 > len(b) {
			return bad
		}
		typ := binary.BigEndian.Uint16(b[n : n+2])
		class := binary.BigEndian.Uint16(b[n+2 : n+4])
		ttl := time.Duration(binary.BigEndian.Uint32(b[n+4:n+8])) * time.Second
		length := int(binary.BigEndian.Uint16(b[n+8 : n+10]))
		p = n + 10
		if p+length > len(b) {
			return bad
		}
		if class == 1 && (typ == 5 || typ == kind) && ttl < r.TTL {
			r.TTL = ttl
		}
		if class == 1 && typ == kind && (typ == 1 && length == 4 || typ == 28 && length == 16) {
			ip := net.IP(append([]byte(nil), b[p:p+length]...))
			if publicIP(ip) && !seen[ip.String()] {
				r.IPs = append(r.IPs, ip)
				seen[ip.String()] = true
			}
		}
		p += length
	}
	return r
}
