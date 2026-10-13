package main

import (
	"encoding/json"
	"fmt"
	"time"
)

func testTrust(device string) {
	work := get(workspace("test-trust"))
	opensslCmd := func(args ...string) { cmd(root, nil, append([]string{"openssl"}, args...)...) }
	rootCA := func(name string) {
		opensslCmd("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", join(work, name+".key"), "-out", join(work, name+".pem"), "-days", "5", "-subj", "/CN=MQTT Test "+name, "-addext", "basicConstraints=critical,CA:TRUE,pathlen:1", "-addext", "keyUsage=critical,keyCertSign,cRLSign")
	}
	signed := func(name, issuer string, intermediate bool, days, purpose string) {
		opensslCmd("req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", join(work, name+".key"), "-out", join(work, name+".csr"), "-subj", "/CN="+name)
		extensions := "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=" + purpose + "\nsubjectAltName=DNS:localhost\n"
		if intermediate {
			extensions = "basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\n"
		}
		ext := join(work, name+".ext")
		must(write(ext, extensions))
		opensslCmd("x509", "-req", "-in", join(work, name+".csr"), "-CA", join(work, issuer+".pem"), "-CAkey", join(work, issuer+".key"), "-CAcreateserial", "-days", days, "-sha256", "-extfile", ext, "-out", join(work, name+".pem"))
	}
	rootCA("root_a")
	rootCA("root_b")
	signed("intermediate", "root_a", true, "1", "serverAuth")
	signed("leaf_a", "intermediate", false, "1", "serverAuth")
	signed("direct_a", "root_a", false, "1", "serverAuth")
	signed("leaf_b", "root_b", false, "1", "serverAuth")
	signed("expired", "root_a", false, "0", "serverAuth")
	signed("wrong_purpose", "root_a", false, "1", "clientAuth")
	must(write(join(work, "chain_a.pem"), read(join(work, "leaf_a.pem"))+read(join(work, "intermediate.pem"))))
	for _, name := range []string{"preferred", "legacy", "empty"} {
		must(mkdir(join(work, name)))
	}
	must(copyFile(join(work, "root_a.pem"), join(work, "preferred/not-an-openssl-hash")))
	must(copyFile(join(work, "root_a.pem"), join(work, "preferred/duplicate.pem")))
	must(write(join(work, "preferred/unrelated-file"), "not a certificate"))
	must(copyFile(join(work, "root_b.pem"), join(work, "legacy/old-root")))
	must(write(join(work, "empty/invalid.pem"), "not a certificate"))
	cmd(root, nil, join(hostTestDirectory, "tls_roots_check"), join(work, "preferred"), join(work, "legacy"), join(work, "empty"), join(work, "direct_a.pem"), join(work, "leaf_b.pem"), join(work, "root_b.pem"))
	if device != "" { // Never install test roots into the caller's existing simulator.
		runtime := device

		func() {
			id := capture(root, "xcrun", "simctl", "create", "MQTT disposable trust check", "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro", runtime)
			defer func() {
				_ = run(root, nil, "xcrun", "simctl", "shutdown", id)
				_ = run(root, nil, "xcrun", "simctl", "delete", id)
			}()
			cmd(root, nil, "xcrun", "simctl", "boot", id)
			cmd(root, nil, "xcrun", "simctl", "bootstatus", id, "-b")
			cmd(root, nil, "xcrun", "simctl", "keychain", id, "add-root-cert", join(work, "root_a.pem"))
			brokers := []*brokerProcess{}
			defer func() {
				for _, b := range brokers {
					b.stop()
				}
			}()
			matrix := map[string]string{}
			for _, v := range []struct{ key, name, cert string }{{"uriA", "leaf_a", "chain_a.pem"}, {"uriB", "leaf_b", "leaf_b.pem"}, {"uriExpired", "expired", "expired.pem"}, {"uriWrongPurpose", "wrong_purpose", "wrong_purpose.pem"}} {
				port := freePort()
				dir := join(work, v.name)
				must(mkdir(dir))
				b := &brokerProcess{dir: dir, config: join(dir, "broker.conf"), address: fmt.Sprintf("127.0.0.1:%d", port), uri: fmt.Sprintf("ssl://localhost:%d", port)}
				must(write(b.config, fmt.Sprintf("listener %d 127.0.0.1\nallow_anonymous true\ncertfile %s\nkeyfile %s\n", port, join(work, v.cert), join(work, v.name+".key"))))
				b.start()
				brokers = append(brokers, b)
				matrix[v.key] = b.uri
			}
			matrix["pemA"] = read(join(work, "root_a.pem"))
			matrix["pemB"] = read(join(work, "root_b.pem"))
			data, e := json.Marshal(matrix)
			must(e)
			data, e = json.Marshal(map[string]string{"MQTT_TRUST_JSON": string(data)})
			must(e)
			defines := join(work, "defines.json")
			must(write(defines, string(data)))
			time.Sleep(time.Second)
			iosApp(appOptions{device: id, flutter: tool("flutter"), suite: "trust", trust: defines, run: true})
		}()
	}
	must(clean(work))
}
