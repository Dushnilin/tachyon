package main

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"errors"
	"flag"
	"io"
	"log"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
)

func main() {
	path := flag.String("config", "/etc/tachyon-core/config.json.smart-connect.json", "configuration file")
	check := flag.Bool("check", false, "validate configuration without listening")
	flag.Parse()
	c, err := readConfig(*path)
	if err != nil {
		log.Fatal(err)
	}
	if *check {
		return
	}
	// Parsing the system trust store is expensive on soft-float MIPS. Do it
	// once before accepting requests, outside every site's search deadline.
	if _, err = tlsConfig(c, "startup.invalid"); err != nil {
		log.Fatal(err)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	s := newSelector(ctx, c)
	listeners := []net.Listener{}
	for _, endpoint := range []struct{ address, start string }{{c.ListenAuto, "direct"}, {c.ListenZapret, "zapret"}} {
		ln, err := net.Listen("tcp", endpoint.address)
		if err != nil {
			for _, l := range listeners {
				l.Close()
			}
			log.Fatal(err)
		}
		listeners = append(listeners, ln)
		go serve(ctx, ln, s, endpoint.start)
	}
	// Publish readiness only after trust initialization and both binds succeed.
	writeStatus(s)
	go func() {
		<-ctx.Done()
		for _, l := range listeners {
			l.Close()
		}
	}()
	tick := time.NewTicker(2 * time.Second)
	defer tick.Stop()
	lastNetwork := networkFingerprint()
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
			if current := networkFingerprint(); current != lastNetwork {
				lastNetwork = current
				s.mu.Lock()
				s.cache = map[string]*cacheEntry{}
				s.epoch++
				s.mu.Unlock()
			}
			if next, err := readConfig(*path); err == nil {
				if err := s.update(next); err != nil {
					log.Print(err)
				}
			}
			writeStatus(s)
		}
	}
}

func networkFingerprint() [32]byte {
	var b []byte
	for _, path := range []string{"/proc/net/route", "/proc/net/ipv6_route"} {
		if data, e := os.ReadFile(path); e == nil {
			b = append(b, []byte(stableRoutes(string(data), strings.HasSuffix(path, "ipv6_route")))...)
		}
	}
	if addresses, e := net.InterfaceAddrs(); e == nil {
		for _, a := range addresses {
			b = append(b, []byte(a.String())...)
		}
	}
	return sha256.Sum256(b)
}

func stableRoutes(data string, ipv6 bool) string {
	var rows []string
	for _, line := range strings.Split(data, "\n") {
		f := strings.Fields(line)
		if ipv6 && len(f) >= 10 {
			rows = append(rows, strings.Join(append(append([]string{}, f[:6]...), f[8:10]...), " "))
		}
		if !ipv6 && len(f) >= 8 && f[0] != "Iface" {
			rows = append(rows, strings.Join([]string{f[0], f[1], f[2], f[3], f[6], f[7]}, " "))
		}
	}
	sort.Strings(rows)
	return strings.Join(rows, "\n")
}

func writeStatus(s *selector) {
	path := s.config().StatusPath
	if path == "" {
		return
	}
	b, err := json.Marshal(s.snapshot())
	if err != nil {
		return
	}
	if err = os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return
	}
	tmp := path + ".tmp"
	if err = os.WriteFile(tmp, b, 0600); err == nil {
		os.Rename(tmp, path)
	}
}

func serve(ctx context.Context, ln net.Listener, s *selector, start string) {
	for {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		select {
		case s.connections <- struct{}{}:
			go func() { defer func() { <-s.connections }(); handle(ctx, conn, s, start) }()
		default:
			conn.Close()
		}
	}
}

func handle(root context.Context, client net.Conn, s *selector, start string) {
	defer client.Close()
	host, port, err := acceptSOCKS(client)
	if err != nil {
		return
	}
	original := host
	prefix := []byte(nil)
	replied := false
	// Some transparent inbounds retain the real destination IP after sniffing.
	// Recover the name from the actual first TLS/HTTP bytes in that case.
	if ip := net.ParseIP(host); ip != nil && publicIP(ip) && (port == 80 || port == 443) {
		if socksReply(client, 0) != nil {
			return
		}
		replied = true
		client.SetDeadline(time.Now().Add(3 * time.Second))
		prefix, host, err = peekName(client, port)
		if err != nil || !webHost(host) {
			host = original
		}
	}
	client.SetDeadline(time.Time{})
	ctx, cancel := context.WithTimeout(root, 12*time.Second)
	defer cancel()
	v := choice{Route: start, Reason: "original route"}
	if (port == 80 || port == 443) && webHost(host) && !s.excluded(host) {
		if candidate, e := s.choose(ctx, host, port, start); e == nil {
			v = candidate
		}
	}
	address := host
	if v.IP != "" {
		address = v.IP
	}
	upstream, err := dialSOCKS(ctx, proxyFor(s.config(), v.Route), address, port)
	if err != nil && (port == 80 || port == 443) && webHost(host) && !s.excluded(host) {
		s.invalidate(host, port, start, v)
		if replacement, e := s.choose(ctx, host, port, start); e == nil {
			v = replacement
			address = host
			if v.IP != "" {
				address = v.IP
			}
			upstream, err = dialSOCKS(ctx, proxyFor(s.config(), v.Route), address, port)
		}
	}
	if err != nil {
		s.invalidate(host, port, start, v)
		if !replied {
			socksReply(client, 4)
		}
		return
	}
	defer upstream.Close()
	if !replied && socksReply(client, 0) != nil {
		return
	}
	w := &firstWrite{Conn: upstream, tls: port == 443}
	if len(prefix) > 0 {
		if _, err = w.Write(prefix); err != nil {
			return
		}
	}
	// Only the winning route ever receives application bytes. No HTTP/POST or
	// TLS early-data replay is attempted after forwarding starts.
	go func() {
		io.Copy(w, client)
		if tcp, ok := upstream.(*net.TCPConn); ok {
			tcp.CloseWrite()
		}
	}()
	first := make([]byte, 32768)
	n, err := upstream.Read(first)
	upstream.SetReadDeadline(time.Time{})
	if n > 0 {
		if _, e := client.Write(first[:n]); e != nil {
			return
		}
	}
	if err != nil {
		if n == 0 {
			s.invalidate(host, port, start, v)
		}
		return
	}
	io.Copy(client, upstream)
}

type firstWrite struct {
	net.Conn
	once sync.Once
	tls  bool
}

func (w *firstWrite) Write(b []byte) (int, error) {
	if len(b) > 0 && w.tls {
		w.once.Do(func() { w.Conn.SetReadDeadline(time.Now().Add(8 * time.Second)) })
	}
	return w.Conn.Write(b)
}

// Return every byte read unchanged; never consume bytes from the user stream
// solely for inspection. ECH without a usable outer name falls back unchanged.
func peekName(c net.Conn, port uint16) ([]byte, string, error) {
	if port == 80 {
		r := bufio.NewReaderSize(c, 16384)
		b := []byte{}
		for len(b) < 16384 {
			line, err := r.ReadSlice('\n')
			b = append(b, line...)
			if err != nil && !errors.Is(err, bufio.ErrBufferFull) {
				return b, "", err
			}
			if string(line) == "\r\n" || string(line) == "\n" {
				break
			}
		}
		// ReadString may buffer application bytes beyond the header.
		if n := r.Buffered(); n > 0 {
			extra := make([]byte, n)
			io.ReadFull(r, extra)
			b = append(b, extra...)
		}
		for _, line := range strings.Split(string(b), "\n") {
			if strings.HasPrefix(strings.ToLower(line), "host:") {
				h := strings.TrimSpace(line[5:])
				if name, _, e := net.SplitHostPort(h); e == nil {
					h = name
				}
				return b, normalizeHost(h), nil
			}
		}
		return b, "", errors.New("HTTP Host absent")
	}
	var b, handshake []byte
	for records := 0; records < 8; records++ {
		var record [5]byte
		count, err := io.ReadFull(c, record[:])
		b = append(b, record[:count]...)
		if err != nil {
			return b, "", err
		}
		n := int(binary.BigEndian.Uint16(record[3:5]))
		if record[0] != 22 || n == 0 || n > 16384 {
			return b, "", errors.New("not a TLS handshake")
		}
		payload := make([]byte, n)
		count, err = io.ReadFull(c, payload)
		b = append(b, payload[:count]...)
		handshake = append(handshake, payload[:count]...)
		if err != nil {
			return b, "", err
		}
		if len(handshake) >= 4 {
			size := 4 + (int(handshake[1]) << 16) + (int(handshake[2]) << 8) + int(handshake[3])
			if size > 65536 {
				return b, "", errors.New("ClientHello exceeds inspection limit")
			}
			if len(handshake) >= size {
				return b, clientHelloName(handshake[:size]), nil
			}
		}
	}
	return b, "", errors.New("fragmented ClientHello exceeds inspection limit")
}

func clientHelloName(b []byte) string {
	if len(b) < 39 || b[0] != 1 {
		return ""
	}
	p := 38
	advance := func(n int) bool {
		if n < 0 || p+n > len(b) {
			return false
		}
		p += n
		return true
	}
	n := int(b[p])
	p++
	if !advance(n) || p+2 > len(b) {
		return ""
	}
	n = int(binary.BigEndian.Uint16(b[p : p+2]))
	p += 2
	if !advance(n) || p >= len(b) {
		return ""
	}
	n = int(b[p])
	p++
	if !advance(n) || p+2 > len(b) {
		return ""
	}
	end := p + 2 + int(binary.BigEndian.Uint16(b[p:p+2]))
	p += 2
	if end > len(b) {
		return ""
	}
	for p+4 <= end {
		kind := binary.BigEndian.Uint16(b[p : p+2])
		n = int(binary.BigEndian.Uint16(b[p+2 : p+4]))
		p += 4
		if p+n > end {
			return ""
		}
		if kind == 0 && n >= 5 {
			q := p + 2
			limit := p + n
			for q+3 <= limit {
				typ := b[q]
				size := int(binary.BigEndian.Uint16(b[q+1 : q+3]))
				q += 3
				if q+size > limit {
					return ""
				}
				if typ == 0 {
					return normalizeHost(string(b[q : q+size]))
				}
				q += size
			}
		}
		p += n
	}
	return ""
}
