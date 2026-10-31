package main

import (
	"context"
	"crypto/tls"
	"net"
	"testing"
	"time"
)

func TestTransparentOriginalDestinationPreserved(t *testing.T) {
	for _, mode := range []string{"excluded", "dns-failed"} {
		t.Run(mode, func(t *testing.T) {
			f := newFixture(t)
			f.allow("direct", "1.1.1.1")
			if mode == "excluded" {
				f.cfg.ExcludedDomains = []string{"site.example"}
			} else {
				f.dnsFailed = true
			}
			f.sel = newSelector(f.ctx, f.cfg)
			ctx, cancel := context.WithTimeout(f.ctx, 3*time.Second)
			defer cancel()
			tc, err := tlsConfig(f.cfg, "site.example")
			if err != nil {
				t.Fatal(err)
			}
			baseline, err := dialSOCKS(ctx, f.cfg.DirectProxy, "1.1.1.1", 443)
			if err != nil {
				t.Fatal(err)
			}
			baselineTLS := tls.Client(baseline, tc)
			if err = baselineTLS.HandshakeContext(ctx); err != nil {
				t.Fatalf("baseline original IP failed: %v", err)
			}
			baselineTLS.Close()
			ln, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			defer ln.Close()
			go serve(f.ctx, ln, f.sel, "direct")
			conn, err := dialSOCKS(ctx, ln.Addr().String(), "1.1.1.1", 443)
			if err != nil {
				t.Fatal(err)
			}
			defer conn.Close()
			secured := tls.Client(conn, tc)
			err = secured.HandshakeContext(ctx)
			f.mu.Lock()
			calls := append([]string(nil), f.calls["direct"]...)
			f.mu.Unlock()
			if err != nil {
				t.Fatalf("baseline original destination 1.1.1.1 is healthy but helper relay failed: %v; direct dial destinations=%v", err, calls)
			}
		})
	}
}
