package main

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"strconv"
	"time"
)

func readAddress(r io.Reader) (string, uint16, error) {
	var kind [1]byte
	if _, err := io.ReadFull(r, kind[:]); err != nil {
		return "", 0, err
	}
	atyp := kind[0]
	var b []byte
	switch kind[0] {
	case 1:
		b = make([]byte, 4)
	case 4:
		b = make([]byte, 16)
	case 3:
		if _, err := io.ReadFull(r, kind[:]); err != nil {
			return "", 0, err
		}
		if kind[0] == 0 {
			return "", 0, errors.New("empty SOCKS host")
		}
		b = make([]byte, int(kind[0]))
	default:
		return "", 0, errors.New("unsupported SOCKS address")
	}
	if _, err := io.ReadFull(r, b); err != nil {
		return "", 0, err
	}
	host := string(b)
	if atyp == 1 || atyp == 4 {
		host = net.IP(b).String()
	}
	var p [2]byte
	_, err := io.ReadFull(r, p[:])
	return host, binary.BigEndian.Uint16(p[:]), err
}

func address(host string, port uint16) ([]byte, error) {
	var b []byte
	ip := net.ParseIP(host)
	if ip4 := ip.To4(); ip4 != nil {
		b = append([]byte{1}, ip4...)
	} else if ip != nil {
		b = append([]byte{4}, ip.To16()...)
	} else {
		if len(host) == 0 || len(host) > 253 {
			return nil, errors.New("invalid SOCKS host")
		}
		b = append([]byte{3, byte(len(host))}, []byte(host)...)
	}
	return append(b, byte(port>>8), byte(port)), nil
}

func dialSOCKS(ctx context.Context, proxy, host string, port uint16) (net.Conn, error) {
	c, err := (&net.Dialer{}).DialContext(ctx, "tcp", proxy)
	if err != nil {
		return nil, err
	}
	ok := false
	defer func() {
		if !ok {
			c.Close()
		}
	}()
	deadline, hasDeadline := ctx.Deadline()
	if !hasDeadline {
		deadline = time.Now().Add(5 * time.Second)
	}
	c.SetDeadline(deadline)
	// Canceling a losing probe must close its socket, not leave it until timeout.
	stop := context.AfterFunc(ctx, func() { c.Close() })
	defer stop()
	if _, err = c.Write([]byte{5, 1, 0}); err != nil {
		return nil, err
	}
	var reply [2]byte
	if _, err = io.ReadFull(c, reply[:]); err != nil {
		return nil, err
	}
	if reply != [2]byte{5, 0} {
		return nil, errors.New("SOCKS authentication refused")
	}
	a, err := address(host, port)
	if err != nil {
		return nil, err
	}
	if _, err = c.Write(append([]byte{5, 1, 0}, a...)); err != nil {
		return nil, err
	}
	var head [3]byte
	if _, err = io.ReadFull(c, head[:]); err != nil {
		return nil, err
	}
	if head[0] != 5 || head[1] != 0 || head[2] != 0 {
		return nil, fmt.Errorf("SOCKS connect rejected: %d", head[1])
	}
	if _, _, err = readAddress(c); err != nil {
		return nil, err
	}
	if err = ctx.Err(); err != nil {
		return nil, err
	}
	c.SetDeadline(time.Time{})
	ok = true
	return c, nil
}

func acceptSOCKS(c net.Conn) (string, uint16, error) {
	c.SetDeadline(time.Now().Add(5 * time.Second))
	var hello [2]byte
	if _, err := io.ReadFull(c, hello[:]); err != nil {
		return "", 0, err
	}
	if hello[0] != 5 || hello[1] == 0 {
		return "", 0, errors.New("invalid SOCKS greeting")
	}
	methods := make([]byte, int(hello[1]))
	if _, err := io.ReadFull(c, methods); err != nil {
		return "", 0, err
	}
	noauth := false
	for _, m := range methods {
		if m == 0 {
			noauth = true
		}
	}
	if !noauth {
		c.Write([]byte{5, 255})
		return "", 0, errors.New("SOCKS no-auth required")
	}
	if _, err := c.Write([]byte{5, 0}); err != nil {
		return "", 0, err
	}
	var req [3]byte
	if _, err := io.ReadFull(c, req[:]); err != nil {
		return "", 0, err
	}
	if req != [3]byte{5, 1, 0} {
		socksReply(c, 7)
		return "", 0, errors.New("only SOCKS CONNECT is supported")
	}
	host, port, err := readAddress(c)
	if port == 0 {
		err = errors.New("invalid destination port")
	}
	return normalizeHost(host), port, err
}

func socksReply(c net.Conn, code byte) error {
	_, err := c.Write([]byte{5, code, 0, 1, 127, 0, 0, 1, 0, 0})
	return err
}
func portString(p uint16) string { return strconv.Itoa(int(p)) }
