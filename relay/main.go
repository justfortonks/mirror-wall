// Mirror Wall Relay: a byte pump for Mirror Wall Cast on networks where the phone can't reach
// the Mac. Both ends dial out to this server; it pairs a phone's code with the Mac's waiting
// connection and pipes bytes verbatim from then on. It never parses the Cast protocol.
//
//	Mac:   {"type":"open","token":T,"slot":"Mirror Wall 1","device":ID}\n
//	       <- {"type":"code","code":"482913","expiresIn":1800}\n
//	       ... waits; when a phone joins: <- {"type":"joined"}\n, then raw bytes both ways
//	Phone: {"type":"join","code":"482913"}\n
//	       <- {"type":"joined"}\n (then raw bytes) | {"type":"error","reason":R}\n (then close)
//
// A Mac that reconnects for the same token, slot and device gets the same code while it lives.
// One waiting Mac connection per slot: a new "open" replaces the old one. Codes live CODE_TTL
// (default 30m) from the last "open"; a wrong code costs the guesser a slot in a global limiter,
// so a six-digit code can't be enumerated.
package main

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"
)

type message struct {
	Type      string `json:"type"`
	Token     string `json:"token,omitempty"`
	Slot      string `json:"slot,omitempty"`
	Device    string `json:"device,omitempty"`
	Code      string `json:"code,omitempty"`
	ExpiresIn int    `json:"expiresIn,omitempty"`
	Reason    string `json:"reason,omitempty"`
}

// A Mac's slot waiting for a phone.
type waiting struct {
	key     string // device+slot
	code    string
	conn    net.Conn
	paired  chan *phone // join() hands the phone to the goroutine that owns the Mac connection
	expires time.Time
}

type phone struct {
	conn   net.Conn
	reader *bufio.Reader
}

type relay struct {
	token   string
	codeTTL time.Duration

	mu      sync.Mutex
	byCode  map[string]*waiting
	byKey   map[string]*waiting
	limiter *limiter
}

func newRelay(token string, codeTTL time.Duration) *relay {
	return &relay{
		token:   token,
		codeTTL: codeTTL,
		byCode:  map[string]*waiting{},
		byKey:   map[string]*waiting{},
		limiter: newLimiter(30, time.Minute),
	}
}

func main() {
	token := os.Getenv("RELAY_TOKEN")
	if token == "" {
		log.Fatal("RELAY_TOKEN is not set")
	}
	port := os.Getenv("PORT")
	if port == "" {
		port = "7000"
	}
	ttl := 30 * time.Minute
	if v := os.Getenv("CODE_TTL"); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil {
			log.Fatalf("CODE_TTL: %v", err)
		}
		ttl = d
	}
	r := newRelay(token, ttl)
	ln, err := net.Listen("tcp", ":"+port)
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("relay listening on :%s (code ttl %s)", port, ttl)
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go func() { <-ctx.Done(); ln.Close() }()
	go r.sweep(ctx)
	for {
		c, err := ln.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			log.Printf("accept: %v", err)
			continue
		}
		go r.serve(c)
	}
}

func (r *relay) serve(c net.Conn) {
	// The first line says who this is. Anything slow or malformed is dropped.
	_ = c.SetReadDeadline(time.Now().Add(10 * time.Second))
	reader := bufio.NewReaderSize(c, 4096)
	line, err := reader.ReadString('\n')
	if err != nil {
		c.Close()
		return
	}
	_ = c.SetReadDeadline(time.Time{})
	var m message
	if err := json.Unmarshal([]byte(strings.TrimSpace(line)), &m); err != nil {
		reply(c, message{Type: "error", Reason: "not a relay message"})
		c.Close()
		return
	}
	switch m.Type {
	case "open":
		r.open(c, reader, m)
	case "join":
		r.join(c, reader, m)
	default:
		reply(c, message{Type: "error", Reason: "unknown message type"})
		c.Close()
	}
}

// A Mac offering a slot. The connection stays open, idle, until a phone joins.
func (r *relay) open(c net.Conn, reader *bufio.Reader, m message) {
	if subtle.ConstantTimeCompare([]byte(m.Token), []byte(r.token)) != 1 {
		reply(c, message{Type: "error", Reason: "bad token"})
		c.Close()
		log.Printf("open refused from %s: bad token", c.RemoteAddr())
		return
	}
	if m.Slot == "" || m.Device == "" {
		reply(c, message{Type: "error", Reason: "slot and device are required"})
		c.Close()
		return
	}
	key := m.Device + "\x00" + m.Slot
	r.mu.Lock()
	w, ok := r.byKey[key]
	if ok {
		// The same slot again (a reconnect): keep its code, drop the old connection.
		if w.conn != nil && w.conn != c {
			w.conn.Close()
		}
	} else {
		w = &waiting{key: key, code: r.newCodeLocked()}
		r.byKey[key] = w
		r.byCode[w.code] = w
	}
	w.conn = c
	w.paired = make(chan *phone, 1)
	w.expires = time.Now().Add(r.codeTTL)
	code, expires, paired := w.code, w.expires, w.paired
	r.mu.Unlock()
	log.Printf("slot %q on %s waiting with code %s", m.Slot, c.RemoteAddr(), code)
	if err := reply(c, message{Type: "code", Code: code, ExpiresIn: int(time.Until(expires).Seconds())}); err != nil {
		r.drop(w, c)
		return
	}

	// Wait for a phone, while noticing if the Mac goes away. The Mac sends nothing until it has
	// been told a phone joined, so the first byte this read returns is the first byte of the Cast
	// stream (forwarded below), or EOF.
	type first struct {
		b   byte
		err error
	}
	firstByte := make(chan first, 1)
	go func() {
		b, err := reader.ReadByte()
		firstByte <- first{b, err}
	}()
	var p *phone
	select {
	case p = <-paired:
	case f := <-firstByte:
		if f.err == nil {
			reply(c, message{Type: "error", Reason: "unexpected data before a phone joined"})
		}
		r.drop(w, c)
		return
	}

	if err := reply(c, message{Type: "joined"}); err != nil {
		reply(p.conn, message{Type: "error", Reason: "the computer went away"})
		p.conn.Close()
		c.Close()
		return
	}
	if err := reply(p.conn, message{Type: "joined"}); err != nil {
		p.conn.Close()
		r.drop(w, c)
		return
	}
	log.Printf("paired phone %s with slot %q", p.conn.RemoteAddr(), m.Slot)

	// Phone → Mac straight away (the phone speaks first: hello). Mac → phone once the first byte
	// the watcher read is forwarded.
	done := make(chan struct{}, 2)
	go func() { io.Copy(c, p.reader); done <- struct{}{} }()
	go func() {
		f := <-firstByte
		if f.err == nil {
			if _, err := p.conn.Write([]byte{f.b}); err == nil {
				io.Copy(p.conn, reader)
			}
		}
		done <- struct{}{}
	}()
	<-done
	c.Close()
	p.conn.Close()
	<-done
}

// A phone with a code. Hands it to the slot's waiting Mac, which pipes until either side hangs up.
func (r *relay) join(c net.Conn, reader *bufio.Reader, m message) {
	if !r.limiter.allow() {
		reply(c, message{Type: "error", Reason: "too many attempts, try again in a minute"})
		c.Close()
		return
	}
	code := strings.ReplaceAll(strings.TrimSpace(m.Code), " ", "")
	r.mu.Lock()
	w, ok := r.byCode[code]
	var paired chan *phone
	if ok && time.Now().Before(w.expires) && w.conn != nil {
		paired = w.paired
		w.conn = nil // taken; the Mac opens a fresh one for the next phone
	}
	r.mu.Unlock()
	if paired == nil {
		r.limiter.spend()
		reply(c, message{Type: "error", Reason: "no slot is waiting with that code"})
		c.Close()
		log.Printf("join refused from %s: code %q", c.RemoteAddr(), code)
		return
	}
	paired <- &phone{conn: c, reader: reader}
}

func (r *relay) drop(w *waiting, c net.Conn) {
	r.mu.Lock()
	if w.conn == c {
		w.conn = nil
	}
	r.mu.Unlock()
	c.Close()
}

// Forgets expired codes.
func (r *relay) sweep(ctx context.Context) {
	t := time.NewTicker(time.Minute)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			now := time.Now()
			r.mu.Lock()
			for code, w := range r.byCode {
				if now.After(w.expires) {
					if w.conn != nil {
						w.conn.Close()
					}
					delete(r.byCode, code)
					delete(r.byKey, w.key)
				}
			}
			r.mu.Unlock()
		}
	}
}

// A six-digit code no live slot has. Caller holds r.mu.
func (r *relay) newCodeLocked() string {
	for {
		var b [4]byte
		if _, err := rand.Read(b[:]); err != nil {
			panic(err)
		}
		n := (uint32(b[0])<<24 | uint32(b[1])<<16 | uint32(b[2])<<8 | uint32(b[3])) % 1_000_000
		code := fmt.Sprintf("%06d", n)
		if _, taken := r.byCode[code]; !taken {
			return code
		}
	}
}

func reply(c net.Conn, m message) error {
	data, _ := json.Marshal(m)
	_ = c.SetWriteDeadline(time.Now().Add(10 * time.Second))
	_, err := c.Write(append(data, '\n'))
	_ = c.SetWriteDeadline(time.Time{})
	return err
}

// A token bucket for failed joins across all clients: `burst` failures a window, refilling
// evenly. Successful joins are free.
type limiter struct {
	mu     sync.Mutex
	tokens float64
	burst  float64
	rate   float64 // tokens per second
	last   time.Time
}

func newLimiter(burst int, window time.Duration) *limiter {
	return &limiter{tokens: float64(burst), burst: float64(burst), rate: float64(burst) / window.Seconds(), last: time.Now()}
}

func (l *limiter) refill() {
	now := time.Now()
	l.tokens += now.Sub(l.last).Seconds() * l.rate
	if l.tokens > l.burst {
		l.tokens = l.burst
	}
	l.last = now
}

func (l *limiter) allow() bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.refill()
	return l.tokens >= 1
}

func (l *limiter) spend() {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.refill()
	l.tokens--
}
