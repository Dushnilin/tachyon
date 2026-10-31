package main

import (
	"bufio"
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"net"
	"os"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

type choice struct {
	Route   string    `json:"route"`
	IP      string    `json:"ip,omitempty"`
	Reason  string    `json:"reason"`
	Expires time.Time `json:"expires"`
	Checked time.Time `json:"checked"`
}
type cacheEntry struct {
	choice
	used          time.Time
	recovering    string
	confirmations int
}
type flight struct {
	done   chan struct{}
	result choice
	err    error
}
type selector struct {
	mu          sync.Mutex
	cfg         Config
	cache       map[string]*cacheEntry
	flights     map[string]*flight
	probes      chan struct{}
	connections chan struct{}
	root        context.Context
	epoch       uint64
}

func newSelector(ctx context.Context, c Config) *selector {
	return &selector{cfg: c, cache: map[string]*cacheEntry{}, flights: map[string]*flight{}, probes: make(chan struct{}, c.MaxProbes), connections: make(chan struct{}, c.MaxConnections), root: ctx}
}
func (s *selector) config() Config { s.mu.Lock(); defer s.mu.Unlock(); return s.cfg }
func (s *selector) update(c Config) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if c.ListenAuto != s.cfg.ListenAuto || c.ListenZapret != s.cfg.ListenZapret || c.MaxConnections != s.cfg.MaxConnections || c.MaxProbes != s.cfg.MaxProbes {
		return errors.New("listener/limit changes require helper restart")
	}
	// Reordering sections can change marks. Invalidate all observations when
	// their route, strategy, DNS, exclusions or network generation changes.
	if c.Generation != s.cfg.Generation {
		s.cache = map[string]*cacheEntry{}
		s.epoch++
	}
	s.cfg = c
	return nil
}
func (s *selector) excluded(host string) bool {
	c := s.config()
	for _, d := range c.ExcludedDomains {
		if host == d || strings.HasSuffix(host, "."+d) {
			return true
		}
	}
	for _, k := range c.ExcludedKeywords {
		if strings.Contains(host, k) {
			return true
		}
	}
	for _, r := range c.ExcludedRegex {
		if yes, _ := regexp.MatchString(r, host); yes {
			return true
		}
	}
	return false
}
func cacheKey(host string, port uint16, start string) string {
	return start + "|" + net.JoinHostPort(host, portString(port))
}

func (s *selector) choose(ctx context.Context, host string, port uint16, start string) (choice, error) {
	key := cacheKey(host, port, start)
	s.mu.Lock()
	if e := s.cache[key]; e != nil {
		e.used = time.Now()
		if time.Now().Before(e.Expires) {
			v := e.choice
			s.mu.Unlock()
			return v, nil
		}
		// A VPN choice has no pinned IP: keep using it while a bounded worker
		// checks whether the cheaper route recovered. Existing flows stay put.
		if e.Route == "vpn" {
			v := e.choice
			if s.flights[key] == nil {
				f := &flight{done: make(chan struct{})}
				s.flights[key] = f
				go s.runFlight(key, host, port, start, f, true)
			}
			s.mu.Unlock()
			return v, nil
		}
	}
	f := s.flights[key]
	if f == nil {
		f = &flight{done: make(chan struct{})}
		s.flights[key] = f
		go s.runFlight(key, host, port, start, f, false)
	}
	s.mu.Unlock()
	select {
	case <-f.done:
		return f.result, f.err
	case <-ctx.Done():
		return choice{}, ctx.Err()
	}
}

func (s *selector) runFlight(key, host string, port uint16, start string, f *flight, background bool) {
	s.mu.Lock()
	c := s.cfg
	epoch := s.epoch
	s.mu.Unlock()
	ctx, cancel := context.WithTimeout(s.root, selectionBudget(c, start))
	defer cancel()
	v, err := s.selectRoute(ctx, c, host, port, start)
	s.mu.Lock()
	defer s.mu.Unlock()
	if epoch != s.epoch {
		err = errors.New("routing generation changed during probe")
	}
	if err == nil {
		old := s.cache[key]
		if background && old != nil && old.Route == "vpn" && v.Route != "vpn" {
			recovery := v.Route + "|" + v.IP
			if old.recovering == recovery {
				old.confirmations++
			} else {
				old.recovering = recovery
				old.confirmations = 1
			}
			if old.confirmations < 2 {
				old.Expires = time.Now().Add(30 * time.Second)
				v = old.choice
			}
		}
		if old == nil || !background || v.Route != "vpn" || v.Checked.After(old.Checked) {
			if len(s.cache) >= c.CacheLimit && old == nil {
				s.evictLocked()
			}
			s.cache[key] = &cacheEntry{choice: v, used: time.Now()}
		}
	} else if background && s.cache[key] != nil {
		// DNS or WAN failure is not evidence that another route works.
		s.cache[key].Expires = time.Now().Add(30 * time.Second)
		s.cache[key].Reason = "recovery deferred: " + err.Error()
	}
	f.result = v
	f.err = err
	delete(s.flights, key)
	close(f.done)
}
func (s *selector) evictLocked() {
	var oldest string
	var stamp time.Time
	for k, e := range s.cache {
		if oldest == "" || e.used.Before(stamp) {
			oldest = k
			stamp = e.used
		}
	}
	delete(s.cache, oldest)
}
func (s *selector) invalidate(host string, port uint16, start string, failed choice) {
	s.mu.Lock()
	defer s.mu.Unlock()
	k := cacheKey(host, port, start)
	if e := s.cache[k]; e != nil && e.Route == failed.Route && e.IP == failed.IP {
		delete(s.cache, k)
	}
}

func proxyFor(c Config, route string) string {
	switch route {
	case "direct":
		return c.DirectProxy
	case "zapret":
		return c.ZapretProxy
	case "vpn":
		return c.VPNProxy
	}
	return ""
}

func selectionBudget(c Config, start string) time.Duration {
	budget := c.ZapretBudgetMS
	if start != "zapret" {
		budget += c.DirectBudgetMS
	}
	return durationMS(budget) + 5*time.Second // VPN check plus scheduling margin
}

type dnsProbeResult struct {
	ip  string
	ttl time.Duration
	err error
}

// Probe usable answers immediately while the other DNS family is still pending.
// Both batches share two local probe slots and the existing global limit.
func (s *selector) probeDNSReplies(ctx context.Context, c Config, route, host string, port uint16, replies <-chan dnsResult) (string, time.Duration, bool, error) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	results := make(chan dnsProbeResult, 2)
	slots := make(chan struct{}, 2)
	pending, candidates := 0, 0
	var dnsErr, uncertain error
	resolved := false
	for replies != nil || pending > 0 {
		select {
		case dns, ok := <-replies:
			if !ok {
				replies = nil
				continue
			}
			if dns.err != nil {
				dnsErr = dns.err
			}
			if len(dns.IPs) == 0 {
				continue
			}
			resolved = true
			// Leave room for a later answer from the other family.
			limit := 16
			if ipv6Available() {
				limit = 8
			}
			if len(dns.IPs) > limit {
				dns.IPs = dns.IPs[:limit]
			}
			if len(dns.IPs) > 16-candidates {
				dns.IPs = dns.IPs[:16-candidates]
			}
			if len(dns.IPs) == 0 {
				continue
			}
			candidates += len(dns.IPs)
			pending++
			go func(dns dnsResult) {
				ip, err := s.raceWithSlots(ctx, c, route, host, port, dns.IPs, slots)
				results <- dnsProbeResult{ip, dns.TTL, err}
			}(dns)
		case result := <-results:
			pending--
			if result.ip != "" {
				return result.ip, result.ttl, true, nil
			}
			if result.err != nil {
				uncertain = result.err
			}
		case <-ctx.Done():
			if resolved {
				return "", 0, true, uncertain
			}
			return "", 0, false, ctx.Err()
		}
	}
	if resolved {
		return "", 0, true, uncertain
	}
	if dnsErr == nil {
		dnsErr = errors.New("no public DNS addresses")
	}
	return "", 0, false, dnsErr
}

func (s *selector) selectRoute(ctx context.Context, c Config, host string, port uint16, start string) (choice, error) {
	stages := []string{"direct", "zapret"}
	if start == "zapret" {
		stages = []string{"zapret"}
	}
	resolved := false
	var dnsError error
	for _, route := range stages {
		budget, server := c.DirectBudgetMS, c.DirectDNS
		if route == "zapret" {
			budget, server = c.ZapretBudgetMS, c.ZapretDNS
		}
		leg, cancel := context.WithTimeout(ctx, durationMS(budget))
		// DNS and TLS share the stage budget. A small artificial DNS-only
		// deadline can discard a valid slower A answer while only unusable AAAA
		// records have arrived, incorrectly forcing healthy sites onto VPN.
		ip, ttl, hasAddresses, probeErr := s.probeDNSReplies(leg, c, route, host, port, resolveForNetwork(leg, server, host))
		if !hasAddresses {
			dnsError = probeErr
			cancel()
			continue
		}
		resolved = true
		cancel()
		if ip != "" {
			if max := time.Duration(c.CacheSeconds) * time.Second; ttl > max {
				ttl = max
			}
			return choice{Route: route, IP: ip, Reason: "verified TLS/HTTP response", Checked: time.Now(), Expires: time.Now().Add(ttl)}, nil
		}
		if probeErr != nil {
			return choice{}, probeErr
		}
	}
	if !resolved {
		return choice{}, fmt.Errorf("DNS unavailable; preserve original route: %w", dnsError)
	}
	// Domain-form SOCKS lets the selected VPN resolve at its own endpoint.
	leg, cancel := context.WithTimeout(ctx, 4*time.Second)
	defer cancel()
	select {
	case s.probes <- struct{}{}:
		defer func() { <-s.probes }()
	case <-leg.Done():
		return choice{}, leg.Err()
	}
	if err := s.probe(leg, c, "vpn", host, host, port); err != nil {
		return choice{}, fmt.Errorf("no verified route: %w", err)
	}
	return choice{Route: "vpn", Reason: "no working Zapret IP found within budget; VPN verified", Checked: time.Now(), Expires: time.Now().Add(time.Duration(c.RetrySeconds) * time.Second)}, nil
}

type probeResult struct {
	ip  string
	err error
}

func (s *selector) race(ctx context.Context, c Config, route, host string, port uint16, ips []net.IP) (string, error) {
	return s.raceWithSlots(ctx, c, route, host, port, ips, nil)
}

func (s *selector) raceWithSlots(ctx context.Context, c Config, route, host string, port uint16, ips []net.IP, slots chan struct{}) (string, error) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	// DNS order rotates, and IPv4/IPv6 records are interleaved so an unusable
	// family cannot occupy both slots for the complete probing budget.
	var v4, v6 []net.IP
	for _, ip := range ips {
		if ip.To4() != nil {
			v4 = append(v4, ip)
		} else {
			v6 = append(v6, ip)
		}
	}
	ordered := []net.IP{}
	for i := 0; i < len(v4) || i < len(v6); i++ {
		if i < len(v4) {
			ordered = append(ordered, v4[i])
		}
		if i < len(v6) {
			ordered = append(ordered, v6[i])
		}
	}
	if len(ordered) > 16 {
		ordered = ordered[:16]
	}
	results := make(chan probeResult, len(ordered))
	jobs := make(chan string, len(ordered))
	for _, ip := range ordered {
		jobs <- ip.String()
	}
	close(jobs)
	// Two blackholed candidates must leave time for the next DNS addresses.
	// Divide the remaining stage budget into bounded waves, rather than letting
	// the first two probes occupy both slots until the stage itself expires.
	attempt := 1500 * time.Millisecond
	if deadline, ok := ctx.Deadline(); ok {
		share := time.Until(deadline) / time.Duration(max(1, (len(ordered)+1)/2))
		// Another DNS family can arrive after this batch. Its candidates must
		// get a turn even if both current workers are TLS blackholes.
		if slots != nil && share > time.Until(deadline)/2 {
			share = time.Until(deadline) / 2
		}
		if share < attempt {
			attempt = share
		}
	}
	minimum := 100 * time.Millisecond
	if route == "direct" && c.DirectBudgetMS >= 1000 || route == "zapret" && c.ZapretBudgetMS >= 1000 {
		// Large CDN answer sets must not reduce every otherwise healthy TLS
		// attempt below an ordinary network RTT. The parent stage still bounds
		// the whole search when there are too many candidates to try them all.
		minimum = time.Second
	}
	if attempt < minimum {
		attempt = minimum
	}
	for worker := 0; worker < 2; worker++ {
		go func() {
			for ip := range jobs {
				if slots != nil {
					select {
					case slots <- struct{}{}:
					case <-ctx.Done():
						return
					}
				}
				select {
				case s.probes <- struct{}{}:
				case <-ctx.Done():
					if slots != nil {
						<-slots
					}
					return
				}
				leg, stop := context.WithTimeout(ctx, attempt)
				err := s.probe(leg, c, route, ip, host, port)
				stop()
				<-s.probes
				if slots != nil {
					<-slots
				}
				results <- probeResult{ip: ip, err: err}
				if ctx.Err() != nil {
					return
				}
			}
		}()
	}
	var uncertain error
	for range ordered {
		select {
		case r := <-results:
			if r.err == nil {
				return r.ip, nil
			}
			var certificate *tls.CertificateVerificationError
			if errors.As(r.err, &certificate) {
				uncertain = fmt.Errorf("TLS certificate probe %s: %w", r.ip, r.err)
			}
		case <-ctx.Done():
			return "", uncertain
		}
	}
	return "", uncertain
}

func (s *selector) probe(ctx context.Context, c Config, route, address, host string, port uint16) error {
	conn, err := dialSOCKS(ctx, proxyFor(c, route), address, port)
	if err != nil {
		return err
	}
	defer conn.Close()
	stop := context.AfterFunc(ctx, func() { conn.Close() })
	defer stop()
	if d, ok := ctx.Deadline(); ok {
		conn.SetDeadline(d)
	}
	if port == 443 {
		tc, err := tlsConfig(c, host)
		if err != nil {
			return err
		}
		t := tls.Client(conn, tc)
		defer t.Close()
		if err := t.HandshakeContext(ctx); err != nil {
			return err
		}
		return ctx.Err()
	}
	// No cookies, authentication, request bodies or user URL paths are copied.
	_, err = fmt.Fprintf(conn, "HEAD / HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n", host)
	if err != nil {
		return err
	}
	line, _, err := bufio.NewReaderSize(conn, 4096).ReadLine()
	if err != nil {
		return err
	}
	if !strings.HasPrefix(string(line), "HTTP/1.") {
		return errors.New("invalid HTTP response")
	}
	return nil // 403/404/5xx responses are not transport failures.
}

func (s *selector) snapshot() any {
	s.mu.Lock()
	defer s.mu.Unlock()
	keys := make([]string, 0, len(s.cache))
	for k := range s.cache {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	rows := make([]any, 0, len(keys))
	for _, k := range keys {
		rows = append(rows, struct {
			Key string `json:"key"`
			choice
		}{k, s.cache[k].choice})
	}
	return struct {
		PID        int       `json:"pid"`
		Generation string    `json:"generation"`
		Entries    []any     `json:"entries"`
		Pending    int       `json:"pending"`
		At         time.Time `json:"at"`
	}{os.Getpid(), s.cfg.Generation, rows, len(s.flights), time.Now()}
}
