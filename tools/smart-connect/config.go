package main

import (
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

// No proxy credentials live here. The core owns the authenticated VPN outbound;
// all sockets in this file are restricted to loopback.
type Config struct {
	ListenAuto       string   `json:"listen_auto"`
	ListenZapret     string   `json:"listen_zapret"`
	DirectProxy      string   `json:"direct_proxy"`
	ZapretProxy      string   `json:"zapret_proxy"`
	VPNProxy         string   `json:"vpn_proxy"`
	DirectDNS        string   `json:"direct_dns"`
	ZapretDNS        string   `json:"zapret_dns"`
	ZapretBudgetMS   int      `json:"zapret_budget_ms"`
	DirectBudgetMS   int      `json:"direct_budget_ms"`
	CacheSeconds     int      `json:"cache_seconds"`
	RetrySeconds     int      `json:"retry_seconds"`
	CacheLimit       int      `json:"cache_limit"`
	MaxConnections   int      `json:"max_connections"`
	MaxProbes        int      `json:"max_probes"`
	ExcludedDomains  []string `json:"excluded_domains"`
	ExcludedKeywords []string `json:"excluded_keywords"`
	ExcludedRegex    []string `json:"excluded_regex"`
	StatusPath       string   `json:"status_path"`
	CAFile           string   `json:"ca_file,omitempty"`
	Generation       string   `json:"generation"`
}

func readConfig(path string) (Config, error) {
	var c Config
	b, err := os.ReadFile(path)
	if err != nil {
		return c, err
	}
	err = json.Unmarshal(b, &c)
	if err != nil {
		return c, err
	}
	return c, c.validate()
}

func (c *Config) validate() error {
	seen := map[string]bool{}
	for _, address := range []string{c.ListenAuto, c.ListenZapret, c.DirectProxy, c.ZapretProxy, c.VPNProxy, c.DirectDNS, c.ZapretDNS} {
		host, port, err := net.SplitHostPort(address)
		ip := net.ParseIP(host)
		p, perr := strconv.ParseUint(port, 10, 16)
		if err != nil || perr != nil || p == 0 || ip == nil || !ip.IsLoopback() {
			return fmt.Errorf("non-loopback or invalid endpoint %q", address)
		}
		if seen[address] {
			return fmt.Errorf("duplicate endpoint %q", address)
		}
		seen[address] = true
	}
	if c.ZapretBudgetMS == 0 {
		c.ZapretBudgetMS = 3000
	}
	if c.DirectBudgetMS == 0 {
		c.DirectBudgetMS = 1500
	}
	if c.CacheSeconds == 0 {
		c.CacheSeconds = 300
	}
	if c.RetrySeconds == 0 {
		c.RetrySeconds = 300
	}
	if c.CacheLimit == 0 {
		c.CacheLimit = 1024
	}
	if c.MaxConnections == 0 {
		c.MaxConnections = 128
	}
	if c.MaxProbes == 0 {
		c.MaxProbes = 4
	}
	if c.ZapretBudgetMS < 100 || c.ZapretBudgetMS > 10000 || c.DirectBudgetMS < 100 || c.DirectBudgetMS > 10000 ||
		c.CacheSeconds < 1 || c.CacheSeconds > 3600 || c.RetrySeconds < 1 || c.RetrySeconds > 3600 ||
		c.CacheLimit < 1 || c.CacheLimit > 4096 || c.MaxConnections < 1 || c.MaxConnections > 512 || c.MaxProbes < 1 || c.MaxProbes > 8 {
		return errors.New("smart-connect limits out of range")
	}
	for _, pattern := range c.ExcludedRegex {
		if _, err := regexp.Compile(pattern); err != nil {
			return fmt.Errorf("invalid exclusion expression: %w", err)
		}
	}
	return nil
}

var trustRoots struct {
	once sync.Once
	pool *x509.CertPool
	err  error
}

func systemRoots() (*x509.CertPool, error) {
	trustRoots.once.Do(func() { trustRoots.pool, trustRoots.err = x509.SystemCertPool() })
	return trustRoots.pool, trustRoots.err
}

func tlsConfig(c Config, host string) (*tls.Config, error) {
	// These independent reachability probes carry no user data. Avoid the
	// expensive default hybrid key exchange on soft-float router CPUs; the
	// browser's actual TLS bytes and negotiated cryptography remain untouched.
	t := &tls.Config{ServerName: host, MinVersion: tls.VersionTLS12,
		CurvePreferences: []tls.CurveID{tls.X25519, tls.CurveP256}}
	pool, err := systemRoots()
	if err != nil {
		return nil, err
	}
	t.RootCAs = pool
	if c.CAFile != "" {
		b, err := os.ReadFile(c.CAFile)
		if err != nil {
			return nil, err
		}
		pool = pool.Clone()
		if !pool.AppendCertsFromPEM(b) {
			return nil, errors.New("invalid CA file")
		}
		t.RootCAs = pool
	}
	return t, nil
}

func normalizeHost(h string) string {
	return strings.TrimSuffix(strings.ToLower(strings.TrimSpace(h)), ".")
}
func webHost(h string) bool {
	if len(h) > 253 || !strings.Contains(h, ".") || net.ParseIP(h) != nil {
		return false
	}
	for _, label := range strings.Split(h, ".") {
		if len(label) == 0 || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
			return false
		}
		for _, ch := range label {
			if !(ch >= 'a' && ch <= 'z' || ch >= '0' && ch <= '9' || ch == '-') {
				return false
			}
		}
	}
	for _, suffix := range []string{".local", ".localhost", ".lan", ".internal", ".home", ".invalid"} {
		if strings.HasSuffix(h, suffix) {
			return false
		}
	}
	return true
}

func durationMS(n int) time.Duration { return time.Duration(n) * time.Millisecond }
