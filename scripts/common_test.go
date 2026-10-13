package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestCleanupBoundary(t *testing.T) {
	saved := build
	t.Cleanup(func() { build = saved })
	base := t.TempDir()
	build = join(base, "build")
	must(mkdir(build))
	external := join(base, "external")
	must(mkdir(external))
	must(write(join(external, "keep"), "data"))
	must(os.Symlink(external, join(build, "link")))
	for _, p := range []string{build, external, join(build, "link")} {
		if clean(p) == nil {
			t.Fatalf("clean allowed %s", p)
		}
	}
	owned := join(build, "job")
	must(write(join(owned, "tmp"), "temporary"))
	must(clean(owned))
	if exists(owned) || read(join(external, "keep")) != "data" {
		t.Fatal("incorrect cleanup")
	}
}
func TestPublishMismatchPreservesPrevious(t *testing.T) {
	base := t.TempDir()
	from := join(base, "new")
	to := join(base, "dist")
	must(write(join(from, "release/lib"), "new"))
	must(manifest(from, map[string]any{}))
	must(write(join(to, "release/lib"), "old"))
	must(write(join(from, "release/lib"), "damaged"))
	if publish(from, to) == nil {
		t.Fatal("published mismatched checksum")
	}
	if read(join(to, "release/lib")) != "old" {
		t.Fatal("lost previous artifact")
	}
	must(write(join(from, "release/lib"), "new"))
	must(publish(from, to))
	if read(join(to, "release/lib")) != "new" {
		t.Fatal("not published")
	}
}
func TestNativeFlags(t *testing.T) {
	checkFlags("clang -Os -g -DNDEBUG -fPIC")
	for _, s := range []string{"-Os", "-O0 -g", "-Os -g -O2"} {
		func() {
			defer func() {
				if recover() == nil {
					t.Errorf("accepted invalid flags: %s", s)
				}
			}()
			checkFlags(s)
		}()
	}
}
func TestWirePreparation(t *testing.T) {
	saved := src
	t.Cleanup(func() { src = saved })
	src = join(t.TempDir(), "src")
	must(write(join(src, "flutter/test/mqtt_v2_test.dart"), "import 'support/native_bootstrap.dart';\nimport 'package:flutter_test/flutter_test.dart';\nvoid main() {\n  TestWidgetsFlutterBinding.ensureInitialized();\n  setUpAll(() => setUpMqttHostTests());\n  test('x', () async {});\n}\n"))
	host := join(filepath.Dir(src), "host")
	prepareWire(host)
	s := read(join(host, "integration_test/mqtt_v2_test.dart"))
	if strings.Contains(s, "setUpMqttHostTests") || !strings.Contains(s, "IntegrationTestWidgetsFlutterBinding") || !strings.Contains(s, "testWidgets") {
		t.Fatal(s)
	}
}

// Keep the Go replacement table byte-for-byte equivalent to the reviewed patch.
// The configured checkout is read only; all patch application happens in TempDir.
func TestOverlayMatchesReviewedPatch(t *testing.T) {
	repo, err := filepath.Abs("..")
	if err != nil {
		t.Fatal(err)
	}
	c, err := readBuildConfig(join(repo, "scripts/config/build.yaml"), false)
	if err != nil {
		t.Fatal(err)
	}
	source := c.Paths["paho_source"]
	if !exists(join(source, "src/MQTTAsync.c")) {
		t.Skip("configure paths.paho_source in scripts/config/build.yaml for overlay parity")
	}
	base := t.TempDir()
	patched, generated := join(base, "patched"), join(base, "generated")
	if err = copyTree(join(source, "src"), join(patched, "src")); err != nil {
		t.Fatal(err)
	}
	if _, err = output(patched, "patch", "-p1", "-i", join(repo, "src/patches/paho-mqtt5-sdk.patch")); err != nil {
		t.Fatal(err)
	}
	if err = overlay(source, generated); err != nil {
		t.Fatal(err)
	}
	names := map[string]bool{}
	for _, edit := range pahoEdits {
		names[edit.name] = true
	}
	for name := range names {
		if read(join(patched, "src", name)) != read(join(generated, "src", name)) {
			t.Errorf("overlay differs from reviewed patch: %s", name)
		}
	}
}

func TestNativeChangeDetected(t *testing.T) {
	dir := t.TempDir()
	must(write(join(dir, "release/lib"), "first"))
	must(manifest(dir, map[string]any{}))
	before := get(hashFile(join(dir, "build-info.json")))
	assertNativeUnchanged(dir, before)
	must(write(join(dir, "release/lib"), "second"))
	must(manifest(dir, map[string]any{}))
	defer func() {
		if recover() == nil {
			t.Fatal("native rebuild during App compilation was not detected")
		}
	}()
	assertNativeUnchanged(dir, before)
}

func TestHostPublicationKeepsOnlyDylib(t *testing.T) {
	dir := t.TempDir()
	stage := join(dir, "stage")
	destination := join(dir, "test")
	must(write(join(stage, hostLibraryRelative), "new library"))
	must(write(join(destination, hostLibraryRelative), "old library"))
	must(write(join(destination, "macos-arm64/symbols/library.dSYM"), "obsolete symbols"))
	must(write(join(destination, "macos-arm64/build-info.json"), "obsolete manifest"))
	must(publishHostLibrary(stage, destination))
	files, err := fileHashes(destination)
	if err != nil || len(files) != 1 || read(join(destination, hostLibraryRelative)) != "new library" {
		t.Fatal(files, err)
	}
	must(write(join(stage, "mqtt_abi_check"), "unexpected test executable"))
	if publishHostLibrary(stage, destination) == nil {
		t.Fatal("published extra test artifact")
	}
	if read(join(destination, hostLibraryRelative)) != "new library" {
		t.Fatal("lost previous library")
	}
}
