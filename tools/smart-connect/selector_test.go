package main

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/binary"
	"encoding/pem"
	"io"
	"log"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type fixture struct {
	cfg       Config
	sel       *selector
	ctx       context.Context
	mu        sync.Mutex
	allowed   map[string]map[string]bool
	stall     map[string]bool
	delay     time.Duration
	dnsFailed bool
	calls     map[string][]string
	dnsCalls  atomic.Int32
	requests  atomic.Int32
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	f := &fixture{allowed: map[string]map[string]bool{}, calls: map[string][]string{}, stall: map[string]bool{}}
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	f.ctx = ctx
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	template := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "site.example"}, DNSNames: []string{"site.example"}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), KeyUsage: x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}, IsCA: true, BasicConstraintsValid: true}
	der, err := x509.CreateCertificate(rand.Reader, template, template, pub, priv)
	if err != nil {
		t.Fatal(err)
	}
	cert := tls.Certificate{Certificate: [][]byte{der}, PrivateKey: priv}
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { f.requests.Add(1); io.WriteString(w, "working site") }))
	server.TLS = &tls.Config{Certificates: []tls.Certificate{cert}}
	server.Config.ErrorLog = log.New(io.Discard, "", 0)
	server.StartTLS()
	t.Cleanup(server.Close)
	ca := filepath.Join(t.TempDir(), "ca.pem")
	os.WriteFile(ca, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0600)
	for _, route := range []string{"direct", "zapret", "vpn"} {
		ln, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { ln.Close() })
		address := ln.Addr().String()
		switch route {
		case "direct":
			f.cfg.DirectProxy = address
		case "zapret":
			f.cfg.ZapretProxy = address
		case "vpn":
			f.cfg.VPNProxy = address
		}
		go func(route string) {
			for {
				conn, e := ln.Accept()
				if e != nil {
					return
				}
				go func() {
					defer conn.Close()
					host, _, err := acceptSOCKS(conn)
					if err != nil {
						return
					}
					f.mu.Lock()
					f.calls[route] = append(f.calls[route], host)
					ok := f.allowed[route][host]
					stall := f.stall[route]
					delay := f.delay
					f.mu.Unlock()
					if !ok {
						if stall {
							socksReply(conn, 0)
							conn.SetDeadline(time.Time{})
							io.Copy(io.Discard, conn)
							return
						}
						socksReply(conn, 4)
						return
					}
					if delay > 0 {
						time.Sleep(delay)
					}
					up, err := net.Dial("tcp", server.Listener.Addr().String())
					if err != nil {
						return
					}
					defer up.Close()
					socksReply(conn, 0)
					conn.SetDeadline(time.Time{})
					go io.Copy(up, conn)
					io.Copy(conn, up)
				}()
			}
		}(route)
	}
	for _, route := range []string{"direct", "zapret"} {
		ln, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { ln.Close() })
		if route == "direct" {
			f.cfg.DirectDNS = ln.Addr().String()
		} else {
			f.cfg.ZapretDNS = ln.Addr().String()
		}
		go func() {
			for {
				conn, e := ln.Accept()
				if e != nil {
					return
				}
				go func() {
					defer conn.Close()
					conn.SetDeadline(time.Now().Add(time.Second))
					var size [2]byte
					if _, e := io.ReadFull(conn, size[:]); e != nil {
						return
					}
					q := make([]byte, binary.BigEndian.Uint16(size[:]))
					if _, e := io.ReadFull(conn, q); e != nil {
						return
					}
					f.dnsCalls.Add(1)
					b := append([]byte(nil), q...)
					b[2] = 0x81
					b[3] = 0x80
					f.mu.Lock()
					failed := f.dnsFailed
					f.mu.Unlock()
					if failed {
						b[3] = 0x82
					}
					kind := binary.BigEndian.Uint16(q[len(q)-4 : len(q)-2])
					if kind == 1 && !failed {
						b[7] = 3
						for _, ip := range []byte{1, 2, 3} {
							b = append(b, 0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 30, 0, 4, 1, 1, 1, ip)
						}
					}
					packet := append([]byte{byte(len(b) >> 8), byte(len(b))}, b...)
					conn.Write(packet)
				}()
			}
		}()
	}
	f.cfg.ListenAuto = "127.0.0.1:14700"
	f.cfg.ListenZapret = "127.0.0.1:14701"
	f.cfg.CAFile = ca
	f.cfg.ZapretBudgetMS = 600
	f.cfg.DirectBudgetMS = 300
	f.cfg.Generation = "a"
	if err := f.cfg.validate(); err != nil {
		t.Fatal(err)
	}
	f.sel = newSelector(ctx, f.cfg)
	return f
}
func (f *fixture) allow(route string, hosts ...string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.allowed[route] = map[string]bool{}
	for _, host := range hosts {
		f.allowed[route][host] = true
	}
}
func (f *fixture) count(route string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.calls[route])
}

func TestChooseWorkingIPAndCache(t *testing.T) {
	f := newFixture(t)
	f.allow("zapret", "1.1.1.3")
	v, err := f.sel.choose(f.ctx, "site.example", 443, "direct")
	if err != nil {
		t.Fatal(err)
	}
	if v.Route != "zapret" || v.IP != "1.1.1.3" {
		t.Fatalf("wrong decision %+v", v)
	}
	before := f.dnsCalls.Load()
	for i := 0; i < 10; i++ {
		next, e := f.sel.choose(f.ctx, "site.example", 443, "direct")
		if e != nil || next.IP != v.IP {
			t.Fatal(next, e)
		}
	}
	if f.dnsCalls.Load() != before {
		t.Fatal("warm cache made DNS/probe requests")
	}
	if f.count("vpn") != 0 {
		t.Fatal("VPN used despite working Zapret IP")
	}
	if v.Expires.Sub(v.Checked) > 31*time.Second {
		t.Fatal("DNS TTL ignored")
	}
}

func TestVPNOnlyAfterZapretAndRecovery(t *testing.T) {
	f := newFixture(t)
	f.allow("vpn", "site.example")
	v, err := f.sel.choose(f.ctx, "site.example", 443, "zapret")
	if err != nil || v.Route != "vpn" {
		t.Fatal(v, err)
	}
	if f.count("direct") != 0 || f.count("zapret") != 3 {
		t.Fatal("forced Zapret stage/order changed")
	}
	f.allow("zapret", "1.1.1.2")
	key := cacheKey("site.example", 443, "zapret")
	for round := 0; round < 2; round++ {
		f.sel.mu.Lock()
		f.sel.cache[key].Expires = time.Now().Add(-time.Second)
		f.sel.mu.Unlock()
		v, err = f.sel.choose(f.ctx, "site.example", 443, "zapret")
		if err != nil || v.Route != "vpn" {
			t.Fatal("refresh must not block/change current VPN flow", v, err)
		}
		f.sel.mu.Lock()
		flight := f.sel.flights[key]
		f.sel.mu.Unlock()
		if flight != nil {
			select {
			case <-flight.done:
			case <-time.After(3 * time.Second):
				t.Fatal("background recovery stuck")
			}
		}
		f.sel.mu.Lock()
		route := f.sel.cache[key].Route
		f.sel.mu.Unlock()
		if round == 0 && route != "vpn" {
			t.Fatal("recovery needs two confirmations")
		}
		if round == 1 && route != "zapret" {
			t.Fatal("did not recover from VPN")
		}
	}
}

func TestDirectPriorityAndRouteIsolation(t *testing.T) {
	f := newFixture(t)
	f.allow("direct", "1.1.1.2")
	f.allow("zapret", "1.1.1.3")
	v, e := f.sel.choose(f.ctx, "site.example", 443, "direct")
	if e != nil || v.Route != "direct" {
		t.Fatal(v, e)
	}
	v, e = f.sel.choose(f.ctx, "site.example", 443, "zapret")
	if e != nil || v.Route != "zapret" {
		t.Fatal("Direct cache leaked into forced Zapret", v, e)
	}
}

func TestSingleFlightAndGenerationInvalidation(t *testing.T) {
	f := newFixture(t)
	f.allow("direct", "1.1.1.1", "1.1.1.2", "1.1.1.3")
	var wg sync.WaitGroup
	for i := 0; i < 30; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, e := f.sel.choose(f.ctx, "site.example", 443, "direct"); e != nil {
				t.Error(e)
			}
		}()
	}
	wg.Wait()
	wantDNS := int32(1)
	if ipv6Available() {
		wantDNS = 2
	}
	if f.dnsCalls.Load() != wantDNS {
		t.Fatalf("duplicate DNS jobs: %d", f.dnsCalls.Load())
	}
	c := f.cfg
	c.Generation = "b"
	if err := f.sel.update(c); err != nil {
		t.Fatal(err)
	}
	f.sel.mu.Lock()
	n := len(f.sel.cache)
	f.sel.mu.Unlock()
	if n != 0 {
		t.Fatal("generation retained old cache")
	}
}

func TestEndToEndSOCKSAndNoUserRequestDuplication(t *testing.T) {
	f := newFixture(t)
	f.allow("zapret", "1.1.1.3")
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go serve(f.ctx, ln, f.sel, "direct")
	ctx, cancel := context.WithTimeout(f.ctx, 5*time.Second)
	defer cancel()
	c, err := dialSOCKS(ctx, ln.Addr().String(), "site.example", 443)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	tc, _ := tlsConfig(f.cfg, "site.example")
	conn := tls.Client(c, tc)
	if err = conn.HandshakeContext(ctx); err != nil {
		t.Fatal(err)
	}
	io.WriteString(conn, "POST /user-action HTTP/1.1\r\nHost: site.example\r\nContent-Length: 3\r\nConnection: close\r\n\r\nabc")
	b, err := io.ReadAll(conn)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), "working site") || f.requests.Load() != 1 {
		t.Fatalf("user request lost/duplicated: requests=%d body=%s", f.requests.Load(), b)
	}
}

func TestSOCKSAddressAndHostValidation(t *testing.T) {
	for _, host := range []string{"abcd", "abcdefghijklmnop", "site.example", "1.1.1.1", "2001:4860:4860::8888"} {
		b, e := address(host, 443)
		if e != nil {
			t.Fatal(e)
		}
		h, p, e := readAddress(strings.NewReader(string(b)))
		if e != nil || h != host || p != 443 {
			t.Fatalf("address %s -> %s:%d (%v)", host, h, p, e)
		}
	}
	for _, host := range []string{"localhost", "site.local", "bad..example", "-bad.example", "bad.example:443", "1.1.1.1"} {
		if webHost(host) {
			t.Fatal("unsafe/invalid name", host)
		}
	}
	f := newFixture(t)
	c := f.cfg
	c.ListenAuto = "0.0.0.0:1234"
	if c.validate() == nil {
		t.Fatal("public listener accepted")
	}
	for _, ip := range []string{"198.18.0.1", "127.0.0.1", "10.0.0.1", "100.64.0.1", "::1", "fd00::1"} {
		if publicIP(net.ParseIP(ip)) {
			t.Fatal("reserved IP accepted", ip)
		}
	}
}

func TestAllRoutesFailWithoutCachingFailure(t *testing.T) {
	f := newFixture(t)
	if _, err := f.sel.choose(f.ctx, "site.example", 443, "direct"); err == nil {
		t.Fatal("all routes failed but success reported")
	}
	f.sel.mu.Lock()
	defer f.sel.mu.Unlock()
	if len(f.sel.cache) != 0 {
		t.Fatal("failure permanently cached")
	}
}

func TestTLSBlackholeBudgetAndVPN(t *testing.T) {
	f := newFixture(t)
	f.mu.Lock()
	f.stall["direct"] = true
	f.stall["zapret"] = true
	f.mu.Unlock()
	f.allow("vpn", "site.example")
	start := time.Now()
	v, err := f.sel.choose(f.ctx, "site.example", 443, "direct")
	if err != nil || v.Route != "vpn" {
		t.Fatal("TCP success without TLS response must fall back", v, err)
	}
	if elapsed := time.Since(start); elapsed > 2*time.Second {
		t.Fatal("stage budgets not bounded", elapsed)
	}
}

func TestThirdIPAfterTwoTLSBlackholes(t *testing.T) {
	f := newFixture(t)
	f.mu.Lock()
	f.stall["zapret"] = true
	f.mu.Unlock()
	f.allow("zapret", "1.1.1.3")
	start := time.Now()
	v, err := f.sel.choose(f.ctx, "site.example", 443, "zapret")
	if err != nil || v.Route != "zapret" || v.IP != "1.1.1.3" {
		t.Fatal("first two TLS stalls starved the third DNS address", v, err)
	}
	if time.Since(start) > time.Second {
		t.Fatal("IP search exceeded its stage budget")
	}
	if f.count("vpn") != 0 {
		t.Fatal("VPN used despite a reachable third IP")
	}
}

func TestLargeDNSSetKeepsUsablePerIPTimeout(t *testing.T) {
	f := newFixture(t)
	f.allow("direct", "1.1.1.1", "1.1.1.2")
	f.mu.Lock()
	f.delay = 250 * time.Millisecond
	f.mu.Unlock()
	c := f.cfg
	c.DirectBudgetMS = 1500
	ctx, cancel := context.WithTimeout(f.ctx, 1500*time.Millisecond)
	defer cancel()
	ips := []net.IP{}
	for i := 1; i <= 16; i++ {
		ips = append(ips, net.IPv4(1, 1, 1, byte(i)))
	}
	ip, err := f.sel.race(ctx, c, "direct", "site.example", 443, ips)
	if err != nil || ip == "" {
		t.Fatal("large DNS set made healthy addresses time out", ip, err)
	}
}

func TestDNSFailureAndCertificateErrorDoNotLearnVPN(t *testing.T) {
	t.Run("DNS", func(t *testing.T) {
		f := newFixture(t)
		f.mu.Lock()
		f.dnsFailed = true
		f.mu.Unlock()
		f.allow("vpn", "site.example")
		if _, err := f.sel.choose(f.ctx, "site.example", 443, "direct"); err == nil {
			t.Fatal("DNS failure reported as a route decision")
		}
		if f.count("vpn") != 0 {
			t.Fatal("DNS failure must not migrate sites to VPN")
		}
	})
	t.Run("certificate", func(t *testing.T) {
		f := newFixture(t)
		f.allow("direct", "1.1.1.1", "1.1.1.2", "1.1.1.3")
		c := f.cfg
		c.CAFile = ""
		c.Generation = "untrusted"
		f.sel.update(c)
		if _, err := f.sel.choose(f.ctx, "site.example", 443, "direct"); err == nil {
			t.Fatal("certificate verification disabled")
		}
		if f.count("vpn") != 0 {
			t.Fatal("certificate error caused VPN migration")
		}
	})
}

func TestTransparentIPRequestRecoversSNI(t *testing.T) {
	f := newFixture(t)
	f.allow("zapret", "1.1.1.3")
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go serve(f.ctx, ln, f.sel, "zapret")
	ctx, cancel := context.WithTimeout(f.ctx, 5*time.Second)
	defer cancel()
	raw, err := dialSOCKS(ctx, ln.Addr().String(), "1.1.1.1", 443)
	if err != nil {
		t.Fatal(err)
	}
	defer raw.Close()
	tc, _ := tlsConfig(f.cfg, "site.example")
	conn := tls.Client(raw, tc)
	if err = conn.HandshakeContext(ctx); err != nil {
		t.Fatal("SNI recovery from an IP-form core request failed", err)
	}
	io.WriteString(conn, "GET / HTTP/1.1\r\nHost: site.example\r\nConnection: close\r\n\r\n")
	b, err := io.ReadAll(conn)
	if err != nil || !strings.Contains(string(b), "working site") {
		t.Fatal(string(b), err)
	}
}

func TestFragmentedClientHelloPreservesEveryByte(t *testing.T) {
	client, wire := net.Pipe()
	defer client.Close()
	defer wire.Close()
	go func() { tls.Client(client, &tls.Config{ServerName: "site.example"}).Handshake() }()
	wire.SetReadDeadline(time.Now().Add(time.Second))
	header := make([]byte, 5)
	if _, err := io.ReadFull(wire, header); err != nil {
		t.Fatal(err)
	}
	payload := make([]byte, binary.BigEndian.Uint16(header[3:5]))
	if _, err := io.ReadFull(wire, payload); err != nil {
		t.Fatal(err)
	}
	var records []byte
	for _, part := range [][]byte{payload[:2], payload[2:25], payload[25:]} {
		records = append(records, 22, 3, 1, byte(len(part)>>8), byte(len(part)))
		records = append(records, part...)
	}
	sender, receiver := net.Pipe()
	defer sender.Close()
	defer receiver.Close()
	go sender.Write(records)
	prefix, host, err := peekName(receiver, 443)
	if err != nil || host != "site.example" || string(prefix) != string(records) {
		t.Fatal("fragmented handshake changed", host, err)
	}
}

func TestCacheLimitAndExclusions(t *testing.T) {
	f := newFixture(t)
	c := f.cfg
	c.CacheLimit = 1
	c.ExcludedDomains = []string{"bank.example"}
	c.ExcludedKeywords = []string{"private"}
	c.ExcludedRegex = []string{`^login\.`}
	c.Generation = "small"
	f.sel.update(c)
	for _, host := range []string{"bank.example", "api.bank.example", "private.example", "login.example"} {
		if !f.sel.excluded(host) {
			t.Fatal("exclusion lost", host)
		}
	}
	f.sel.mu.Lock()
	f.sel.cache["old"] = &cacheEntry{used: time.Now().Add(-time.Hour)}
	f.sel.evictLocked()
	n := len(f.sel.cache)
	f.sel.mu.Unlock()
	if n != 0 {
		t.Fatal("LRU did not evict")
	}
}

func TestNetworkFingerprintIgnoresTrafficCounters(t *testing.T) {
	a := "wan 00000000 0100000A 0003 0 1 100 00000000\n"
	b := "wan 00000000 0100000A 0003 4 999 100 00000000\n"
	if stableRoutes(a, false) != stableRoutes(b, false) {
		t.Fatal("ordinary traffic invalidates the cache")
	}
	if stableRoutes(a, false) == stableRoutes(strings.Replace(a, "0100000A", "0200000A", 1), false) {
		t.Fatal("gateway change not detected")
	}
	a = "00000000000000000000000000000000 00 00000000000000000000000000000000 00 fe800000000000000000000000000001 00000400 00000001 00000002 00000003 wan\n"
	b = strings.Replace(a, "00000001 00000002", "00000100 00000999", 1)
	if stableRoutes(a, true) != stableRoutes(b, true) {
		t.Fatal("IPv6 usage counters invalidated the cache")
	}
}
