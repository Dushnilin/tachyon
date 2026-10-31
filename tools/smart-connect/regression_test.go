package main

import (
	"context"
	"encoding/binary"
	"io"
	"net"
	"testing"
	"time"
)

func TestProbeEarlyDNSFamilyWhileOtherHangs(t *testing.T) {
	for _, address := range []string{"1.1.1.1", "2606:4700::1111"} {
		t.Run(address, func(t *testing.T) {
			f := newFixture(t)
			f.allow("direct", address)
			ctx, cancel := context.WithTimeout(f.ctx, time.Second)
			defer cancel()
			replies := make(chan dnsResult, 2)
			replies <- dnsResult{IPs: []net.IP{net.ParseIP(address)}, TTL: 30 * time.Second}
			// The other family never finishes, just as a blackholed DNS query.
			ip, ttl, resolved, err := f.sel.probeDNSReplies(ctx, f.cfg, "direct", "site.example", 443, replies)
			if err != nil || !resolved || ip != address || ttl != 30*time.Second || ctx.Err() != nil {
				t.Fatalf("usable DNS family was starved: ip=%s ttl=%s resolved=%v err=%v context=%v", ip, ttl, resolved, err, ctx.Err())
			}
		})
	}
}

func TestProbeLateWorkingDNSFamily(t *testing.T) {
	f := newFixture(t)
	f.allow("direct", "2606:4700::1111")
	f.stall["direct"] = true
	ctx, cancel := context.WithTimeout(f.ctx, time.Second)
	defer cancel()
	replies := make(chan dnsResult, 2)
	replies <- dnsResult{IPs: []net.IP{net.ParseIP("1.1.1.1"), net.ParseIP("1.1.1.2")}, TTL: time.Minute}
	go func() {
		time.Sleep(25 * time.Millisecond)
		replies <- dnsResult{IPs: []net.IP{net.ParseIP("2606:4700::1111")}, TTL: 10 * time.Second}
		close(replies)
	}()
	ip, ttl, _, err := f.sel.probeDNSReplies(ctx, f.cfg, "direct", "site.example", 443, replies)
	if err != nil || ip != "2606:4700::1111" || ttl != 10*time.Second {
		t.Fatalf("late working family lost behind blackholes: %s %s %v", ip, ttl, err)
	}
}

func TestMaximumZapretBudgetCanReachVPN(t *testing.T) {
	f := newFixture(t)
	f.allow("vpn", "site.example")
	f.stall["direct"], f.stall["zapret"] = true, true
	f.delay = 1200 * time.Millisecond
	dns, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer dns.Close()
	go func() {
		for {
			conn, err := dns.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				var size [2]byte
				if _, err := io.ReadFull(conn, size[:]); err != nil {
					return
				}
				q := make([]byte, binary.BigEndian.Uint16(size[:]))
				if _, err := io.ReadFull(conn, q); err != nil || len(q) < 12 {
					return
				}
				time.Sleep(8500 * time.Millisecond)
				b := append([]byte(nil), q...)
				b[2], b[3] = 0x81, 0x80
				if binary.BigEndian.Uint16(q[len(q)-4:]) == 1 {
					b[7] = 3
					for _, ip := range []byte{1, 2, 3} {
						b = append(b, 0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 30, 0, 4, 1, 1, 1, ip)
					}
				}
				conn.Write(append([]byte{byte(len(b) >> 8), byte(len(b))}, b...))
			}()
		}
	}()
	f.cfg.DirectBudgetMS, f.cfg.ZapretBudgetMS = 1500, 10000
	f.cfg.ZapretDNS = dns.Addr().String()
	f.sel = newSelector(f.ctx, f.cfg)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go serve(f.ctx, ln, f.sel, "direct")
	ctx, cancel := context.WithTimeout(f.ctx, 20*time.Second)
	defer cancel()
	conn, err := dialSOCKS(ctx, ln.Addr().String(), "site.example", 443)
	if err != nil {
		t.Fatalf("allowed search budgets expired before verified VPN could connect: %v", err)
	}
	conn.Close()
	f.sel.mu.Lock()
	defer f.sel.mu.Unlock()
	if v := f.sel.cache[cacheKey("site.example", 443, "direct")]; v == nil || v.Route != "vpn" {
		t.Fatalf("expected verified VPN choice, got %+v", v)
	}
}
