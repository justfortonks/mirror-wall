package main

import (
	"bufio"
	"encoding/json"
	"net"
	"testing"
	"time"
)

func startRelay(t *testing.T) (*relay, string) {
	t.Helper()
	r := newRelay("secret", time.Minute)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go r.serve(c)
		}
	}()
	t.Cleanup(func() { ln.Close() })
	return r, ln.Addr().String()
}

func dial(t *testing.T, addr string, m message) (net.Conn, *bufio.Reader, message) {
	t.Helper()
	c, err := net.Dial("tcp", addr)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	data, _ := json.Marshal(m)
	c.Write(append(data, '\n'))
	reader := bufio.NewReader(c)
	c.SetReadDeadline(time.Now().Add(2 * time.Second))
	line, err := reader.ReadString('\n')
	if err != nil {
		t.Fatalf("no reply to %v: %v", m, err)
	}
	c.SetReadDeadline(time.Time{})
	var reply message
	if err := json.Unmarshal([]byte(line), &reply); err != nil {
		t.Fatal(err)
	}
	return c, reader, reply
}

func readLine(t *testing.T, r *bufio.Reader) message {
	t.Helper()
	line, err := r.ReadString('\n')
	if err != nil {
		t.Fatal(err)
	}
	var m message
	json.Unmarshal([]byte(line), &m)
	return m
}

func TestPairsAndPipesBothWays(t *testing.T) {
	_, addr := startRelay(t)
	mac, macReader, codeMsg := dial(t, addr, message{Type: "open", Token: "secret", Slot: "Mirror Wall 1", Device: "mac-a"})
	if codeMsg.Type != "code" || len(codeMsg.Code) != 6 {
		t.Fatalf("expected a six-digit code, got %+v", codeMsg)
	}
	phone, phoneReader, joined := dial(t, addr, message{Type: "join", Code: codeMsg.Code})
	if joined.Type != "joined" {
		t.Fatalf("phone expected joined, got %+v", joined)
	}
	if m := readLine(t, macReader); m.Type != "joined" {
		t.Fatalf("mac expected joined, got %+v", m)
	}
	// Phone speaks first (hello), then the Mac answers (welcome): raw bytes, untouched.
	phone.Write([]byte{0x01, 0, 0, 0, 2, 'h', 'i'})
	buf := make([]byte, 7)
	mac.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, err := macReader.Read(buf); err != nil || string(buf) != "\x01\x00\x00\x00\x02hi" {
		t.Fatalf("mac got %q, %v", buf, err)
	}
	mac.Write([]byte{0x81, 0, 0, 0, 1, 'w'})
	buf = make([]byte, 6)
	phone.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, err := phoneReader.Read(buf); err != nil || string(buf) != "\x81\x00\x00\x00\x01w" {
		t.Fatalf("phone got %q, %v", buf, err)
	}
	// The code is spent; the next phone with it is refused until the Mac opens again.
	_, _, again := dial(t, addr, message{Type: "join", Code: codeMsg.Code})
	if again.Type != "error" {
		t.Fatalf("expected the used code to be refused, got %+v", again)
	}
	// The Mac reopening the same slot gets the same code back.
	_, _, reopened := dial(t, addr, message{Type: "open", Token: "secret", Slot: "Mirror Wall 1", Device: "mac-a"})
	if reopened.Code != codeMsg.Code {
		t.Fatalf("expected the same code on reopen, got %s vs %s", reopened.Code, codeMsg.Code)
	}
}

func TestRefusesBadTokenAndUnknownCode(t *testing.T) {
	_, addr := startRelay(t)
	if _, _, m := dial(t, addr, message{Type: "open", Token: "wrong", Slot: "S", Device: "d"}); m.Type != "error" {
		t.Fatalf("expected bad token to be refused, got %+v", m)
	}
	if _, _, m := dial(t, addr, message{Type: "join", Code: "000000"}); m.Type != "error" {
		t.Fatalf("expected unknown code to be refused, got %+v", m)
	}
	if _, _, m := dial(t, addr, message{Type: "nonsense"}); m.Type != "error" {
		t.Fatalf("expected unknown type to be refused, got %+v", m)
	}
}

func TestLimiterBurnsOutOnGuessing(t *testing.T) {
	r, addr := startRelay(t)
	r.limiter = newLimiter(3, time.Hour)
	var last message
	for i := 0; i < 4; i++ {
		_, _, last = dial(t, addr, message{Type: "join", Code: "123456"})
	}
	if last.Reason != "too many attempts, try again in a minute" {
		t.Fatalf("expected the limiter to kick in, got %+v", last)
	}
}
