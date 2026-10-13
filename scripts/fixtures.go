package main

import (
	"bufio"
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"
)

type brokerProcess struct {
	cmd                           *exec.Cmd
	log                           *os.File
	uri, ca, dir, config, address string
}

func freePort() int {
	l, e := net.Listen("tcp", "127.0.0.1:0")
	must(e)
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port
}
func startBroker(dir string, tls, persist bool) *brokerProcess {
	must(mkdir(dir))
	port := freePort()
	config := fmt.Sprintf("listener %d 127.0.0.1\nallow_anonymous true\n", port)
	b := &brokerProcess{dir: dir, config: join(dir, "broker.conf"), address: fmt.Sprintf("127.0.0.1:%d", port), uri: fmt.Sprintf("tcp://127.0.0.1:%d", port)}
	if persist {
		config += "persistence true\npersistence_location " + dir + "/\n"
	}
	if tls {
		b.ca = join(dir, "ca.pem")
		key := join(dir, "key.pem")
		cmd(root, nil, "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", b.ca, "-days", "1", "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost")
		config += "certfile " + b.ca + "\nkeyfile " + key + "\n"
		b.uri = fmt.Sprintf("ssl://localhost:%d", port)
	}
	must(write(b.config, config))
	b.start()
	return b
}
func (b *brokerProcess) start() {
	if b.cmd != nil {
		return
	}
	exe := tool("mosquitto")
	var e error
	b.log, e = os.OpenFile(join(b.dir, "broker.log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
	must(e)
	b.cmd = exec.Command(exe, "-c", b.config)
	b.cmd.Env = envMerge(nil)
	b.cmd.Stdout = b.log
	b.cmd.Stderr = b.log
	must(b.cmd.Start())
	for i := 0; i < 100; i++ {
		c, e := net.DialTimeout("tcp", b.address, 100*time.Millisecond)
		if e == nil {
			c.Close()
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	b.stop()
	panic("broker startup timed out")
}
func (b *brokerProcess) stop() {
	if b.cmd == nil {
		return
	}
	_ = b.cmd.Process.Signal(os.Interrupt)
	done := make(chan error, 1)
	go func() { done <- b.cmd.Wait() }()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		_ = b.cmd.Process.Kill()
		<-done
	}
	b.log.Close()
	b.cmd = nil
}
func hostRelease() string { return join(dist, "test/macos-arm64/release") }

var hostTestDirectory string

func hostTestLibrary() string {
	if hostTestDirectory != "" {
		return join(hostTestDirectory, "libmqtt_sdk.dylib")
	}
	return join(hostRelease(), "libmqtt_sdk.dylib")
}
func dartTest(env map[string]string, files ...string) {
	env["MQTT_TEST_LIBRARY"] = hostTestLibrary()
	cmd(join(src, "flutter"), env, append([]string{"flutter", "test", "--reporter", "expanded"}, files...)...)
}
func testCommand(args []string) error {
	f := flag.NewFlagSet("test", flag.ContinueOnError)
	config := addConfigFlags(f)
	suite := f.String("suite", "all", "runtime, errors, reconnect, subscribe, trust, all")
	device := f.String("ios-runtime", "", "create a disposable trust simulator using this iOS runtime")
	if e := f.Parse(args); e != nil {
		return e
	}
	if *device != "" && !strings.HasPrefix(*device, "com.apple.CoreSimulator.SimRuntime.") {
		return fmt.Errorf("--ios-runtime must be a CoreSimulator runtime identifier")
	}
	c, err := config.load(f)
	if err != nil {
		return err
	}
	switch *suite {
	case "all", "runtime", "errors":
		err = c.requireTools("flutter", "mosquitto", "openssl")
	case "reconnect":
		err = c.requireTools("flutter", "mosquitto")
	case "subscribe":
		err = c.requireTools("flutter")
	case "trust":
		err = c.requireTools("openssl")
	default:
		return fmt.Errorf("unknown suite: %s", *suite)
	}
	if err != nil {
		return err
	}
	if *device != "" {
		if *suite != "trust" && *suite != "all" {
			return fmt.Errorf("--ios-runtime requires trust or all suite")
		}
		if err = c.requireApp("ios"); err != nil {
			return err
		}
		if err = c.requireTools("mosquitto"); err != nil {
			return err
		}
	}
	if err = nativePlatformError("host"); err != nil {
		return err
	}
	needsNative := *suite == "all" || *suite == "runtime" || *suite == "errors" || *suite == "trust"
	if needsNative {
		if err = c.requireAll(nativeRequirements("host")); err != nil {
			return err
		}
	} else if !exists(hostTestLibrary()) {
		return fmt.Errorf("missing host library: run native --platform host first")
	}
	activeConfig = c
	nativeWork := ""
	if needsNative {
		nativeWork, hostTestDirectory = buildHost(nativeOptions{platform: "host", paho: c.Paths["paho_source"], openssl: c.Paths["openssl_source"], dart: c.Paths["dart_sdk_include"]})
		defer func() { hostTestDirectory = "" }()
	}
	suites := []string{*suite}
	if *suite == "all" {
		suites = []string{"runtime", "errors", "reconnect", "subscribe", "trust"}
	}
	for _, s := range suites {
		switch s {
		case "runtime":
			testRuntime()
		case "errors":
			testErrors()
		case "reconnect":
			testReconnect()
		case "subscribe":
			testSubscribe()
		case "trust":
			testTrust(*device)
		default:
			return fmt.Errorf("unknown suite: %s", s)
		}
	}
	if exists(join(src, "flutter/build")) {
		must(os.RemoveAll(join(src, "flutter/build")))
	}
	if nativeWork != "" {
		must(clean(nativeWork))
	}
	return nil
}
func testRuntime() {
	work := get(workspace("test-runtime"))
	b := startBroker(work, true, false)
	func() {
		defer b.stop()
		lib := hostTestDirectory
		cmd(root, nil, join(lib, "mqtt_runtime_check"), b.uri, b.ca)
		cmd(root, nil, join(lib, "mqtt_v2_check"), b.uri, b.ca)
		cmd(root, nil, join(lib, "mqtt_runtime_check"), b.uri, "-", "reject")
		cmd(root, nil, join(lib, "mqtt_runtime_check"), strings.Replace(b.uri, "localhost", "127.0.0.1", 1), b.ca, "reject")
		dartTest(map[string]string{"MQTT_TEST_BROKER": b.uri, "MQTT_TEST_CA": b.ca})
	}()
	must(clean(work))
}

// Fixture servers track connections so teardown cannot leave blocked goroutines.
type fixtureServer struct {
	net.Listener
	mu          sync.Mutex
	connections map[net.Conn]bool
	wg          sync.WaitGroup
	errors      []error
}

func serve(handler func(net.Conn) error) *fixtureServer {
	l, e := net.Listen("tcp", "127.0.0.1:0")
	must(e)
	s := &fixtureServer{Listener: l, connections: map[net.Conn]bool{}}
	s.wg.Add(1)
	go func() {
		defer s.wg.Done()
		for {
			c, e := l.Accept()
			if e != nil {
				return
			}
			s.mu.Lock()
			s.connections[c] = true
			s.mu.Unlock()
			s.wg.Add(1)
			go func() {
				defer s.wg.Done()
				defer c.Close()
				e := handler(c)
				s.mu.Lock()
				delete(s.connections, c)
				if e != nil && e != io.EOF && !strings.Contains(e.Error(), "use of closed network connection") {
					s.errors = append(s.errors, e)
				}
				s.mu.Unlock()
			}()
		}
	}()
	return s
}
func (s *fixtureServer) close() {
	s.Listener.Close()
	s.mu.Lock()
	for c := range s.connections {
		c.Close()
	}
	s.mu.Unlock()
	s.wg.Wait()
}
func (s *fixtureServer) uri() string { return "tcp://" + s.Addr().String() }
func testErrors() {
	work := get(workspace("test-errors"))
	func() {
		b := startBroker(work, true, false)
		defer b.stop()
		reject := serve(func(c net.Conn) error {
			_ = c.SetDeadline(time.Now().Add(10 * time.Second))
			buf := make([]byte, 4096)
			if n, _ := c.Read(buf); n > 0 {
				_, _ = c.Write([]byte{0x20, 2, 0, 5})
			}
			return nil
		})
		defer reject.close()
		stall := serve(func(c net.Conn) error {
			_ = c.SetDeadline(time.Now().Add(10 * time.Second))
			_, _ = io.Copy(io.Discard, c)
			return nil
		})
		defer stall.close()
		fixture := map[string]string{"badTls": strings.Replace(reject.uri(), "tcp:", "ssl:", 1), "refused": fmt.Sprintf("tcp://127.0.0.1:%d", freePort()), "dns": "tcp://mqtt-sdk-does-not-exist.invalid:1883", "tls": b.uri, "mismatch": strings.Replace(b.uri, "localhost", "127.0.0.1", 1), "ca": b.ca, "reject": reject.uri(), "stall": stall.uri()}
		env := map[string]string{}
		for k, v := range fixture {
			env["MQTT_ERROR_"+strings.ToUpper(k)] = v
		}
		cmd(root, env, join(hostTestDirectory, "mqtt_error_matrix_check"))
		data, e := json.Marshal(fixture)
		must(e)
		env["MQTT_ERROR_FIXTURE"] = string(data)
		dartTest(env, "test/typed_errors_test.dart", "test/errors_test.dart")
	}()
	must(clean(work))
}
func testReconnect() {
	work := get(workspace("test-reconnect"))
	func() {
		b := startBroker(work, false, true)
		defer b.stop()
		var mu sync.Mutex
		control := serve(func(c net.Conn) error {
			_ = c.SetDeadline(time.Now().Add(10 * time.Second))
			line, e := bufio.NewReader(c).ReadString('\n')
			if e != nil {
				return e
			}
			mu.Lock()
			defer mu.Unlock()
			switch strings.TrimSpace(line) {
			case "stop":
				b.stop()
			case "start":
				_ = os.Remove(join(work, "mosquitto.db"))
				b.start()
			case "resume":
				b.start()
			default:
				return fmt.Errorf("invalid broker command")
			}
			_, e = c.Write([]byte("ok\n"))
			return e
		})
		defer control.close()
		_, port, _ := net.SplitHostPort(control.Addr().String())
		dartTest(map[string]string{"MQTT_TEST_BROKER": b.uri, "MQTT_TEST_CONTROL": port}, "test/reconnect_test.dart")
	}()
	must(clean(work))
}

type topicQos struct {
	Topic string
	Qos   byte
}
type wireRecord struct {
	subs   [][]topicQos
	unsubs [][]string
}

func readPacket(c net.Conn) (byte, []byte, error) {
	head := make([]byte, 1)
	if _, e := io.ReadFull(c, head); e != nil {
		return 0, nil, e
	}
	size := 0
	for n := 0; n < 4; n++ {
		b := make([]byte, 1)
		if _, e := io.ReadFull(c, b); e != nil {
			return 0, nil, e
		}
		size += int(b[0]&127) << (7 * n)
		if b[0] < 128 {
			if size > 1024*1024 {
				return 0, nil, fmt.Errorf("fixture packet too large")
			}
			body := make([]byte, size)
			_, e := io.ReadFull(c, body)
			return head[0], body, e
		}
	}
	return 0, nil, fmt.Errorf("invalid remaining length")
}
func packet(head byte, body []byte) []byte {
	b := []byte{head}
	n := len(body)
	for {
		v := byte(n % 128)
		n /= 128
		if n > 0 {
			v |= 128
		}
		b = append(b, v)
		if n == 0 {
			break
		}
	}
	return append(b, body...)
}
func testSubscribe() {
	records := []*wireRecord{}
	var mu sync.Mutex
	s := serve(func(c net.Conn) error {
		r := &wireRecord{}
		mu.Lock()
		records = append(records, r)
		mu.Unlock()
		var held, heldUnsub []byte
		_ = c.SetDeadline(time.Now().Add(60 * time.Second))
		for {
			head, body, e := readPacket(c)
			if e != nil {
				return e
			}
			switch head {
			case 0x10:
				if len(body) < 7 || string(body[:7]) != "\x00\x04MQTT\x04" {
					return fmt.Errorf("invalid CONNECT")
				}
				_, e = c.Write([]byte{0x20, 2, 0, 0})
			case 0x82, 0xa2:
				if len(body) < 2 {
					return fmt.Errorf("missing packet ID")
				}
				pos := 2
				items := []topicQos{}
				topics := []string{}
				codes := []byte{}
				for pos < len(body) {
					if pos+2 > len(body) {
						return fmt.Errorf("short topic")
					}
					size := int(binary.BigEndian.Uint16(body[pos:]))
					pos += 2
					if pos+size > len(body) {
						return fmt.Errorf("short UTF8")
					}
					topic := string(body[pos : pos+size])
					pos += size
					topics = append(topics, topic)
					if head == 0x82 {
						if pos >= len(body) || body[pos] > 2 {
							return fmt.Errorf("invalid QoS")
						}
						q := body[pos]
						pos++
						items = append(items, topicQos{topic, q})
						code := q
						if strings.HasSuffix(topic, "deny") {
							code = 128
						} else if strings.HasSuffix(topic, "down") {
							code = 1
						}
						codes = append(codes, code)
					}
				}
				if len(topics) == 0 {
					return fmt.Errorf("empty batch")
				}
				if head == 0x82 {
					r.subs = append(r.subs, items)
					reply := packet(0x90, append(append([]byte{}, body[:2]...), codes...))
					switch topics[0] {
					case "async/a":
						held = reply
					case "async/b":
						if held == nil {
							return fmt.Errorf("no held SUBACK")
						}
						_, e = c.Write(append(reply, held...))
						held = nil
					case "pending/close":
					default:
						_, e = c.Write(reply)
					}
				} else {
					r.unsubs = append(r.unsubs, topics)
					reply := packet(0xb0, body[:2])
					switch topics[0] {
					case "unsub/async/a":
						heldUnsub = reply
					case "unsub/async/b":
						if heldUnsub == nil {
							return fmt.Errorf("no held UNSUBACK")
						}
						_, e = c.Write(append(reply, heldUnsub...))
						heldUnsub = nil
					case "unsub/pending":
					default:
						_, e = c.Write(reply)
					}
				}
			case 0xc0:
				_, e = c.Write([]byte{0xd0, 0})
			case 0xe0:
				return nil
			default:
				return fmt.Errorf("unexpected packet %x", head)
			}
			if e != nil {
				return e
			}
		}
	})
	func() {
		defer s.close()
		dartTest(map[string]string{"MQTT_TEST_BATCH": "1", "MQTT_TEST_BROKER": s.uri()}, "test/subscribe_many_test.dart")
	}()
	if len(s.errors) > 0 {
		panic(s.errors[0])
	}
	if len(records) != 1 {
		panic("expected exactly one connection")
	}
	eq := func(a, b any) {
		x, _ := json.Marshal(a)
		y, _ := json.Marshal(b)
		if string(x) != string(y) {
			panic(fmt.Sprintf("wire mismatch: %s != %s", x, y))
		}
	}
	r := records[0]
	if len(r.subs) < 7 || len(r.subs) > 8 || len(r.unsubs) < 5 || len(r.unsubs) > 6 {
		panic("batch packet count mismatch")
	}
	eq(r.subs[0], []topicQos{{"batch/中文", 0}, {"batch/deny", 1}, {"batch/down", 2}})
	eq(r.subs[1], []topicQos{{"batch/deny", 1}})
	eq(r.subs[2], r.subs[1])
	eq(r.subs[3], []topicQos{{"batch/dup", 0}, {"batch/dup", 2}})
	many := []topicQos{}
	unsub := []string{}
	for i := 0; i < 256; i++ {
		many = append(many, topicQos{fmt.Sprintf("max/%d", i), byte(i % 3)})
		unsub = append(unsub, fmt.Sprintf("max/%d", i))
	}
	eq(r.subs[4], many)
	eq(r.subs[5:7], [][]topicQos{{{"async/a", 1}}, {{"async/b", 2}}})
	if len(r.subs) == 8 {
		eq(r.subs[7], []topicQos{{"pending/close", 1}})
	}
	eq(r.unsubs[0], []string{"batch/中文", "devices/+/status", "missing/#", "batch/中文"})
	eq(r.unsubs[1], []string{"single/missing"})
	eq(r.unsubs[2], unsub)
	eq(r.unsubs[3:5], [][]string{{"unsub/async/a"}, {"unsub/async/b"}})
	if len(r.unsubs) == 6 {
		eq(r.unsubs[5], []string{"unsub/pending"})
	}
	fmt.Println("Wire batch order, QoS, refusals, duplicates and packet counts verified")
}
