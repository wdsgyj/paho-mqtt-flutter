package main

import (
	"bytes"
	"flag"
	"os"
	"strings"
	"testing"
)

func TestDoctorListsAllFailures(t *testing.T) {
	c := &buildConfig{Paths: map[string]string{}, Tools: map[string]string{}}
	var out bytes.Buffer
	err := doctorReport(&out, c, []requirement{{key: "paho_source", marker: "src/MQTTAsync.c"}, {key: "ndk", marker: "build/cmake/android.toolchain.cmake"}, {key: "make", tool: true}}, nil)
	if err == nil {
		t.Fatal("missing dependencies accepted")
	}
	for _, want := range []string{"paths.paho_source", "--paho-source", "paths.ndk", "--ndk", "tools.make", "--make"} {
		if !strings.Contains(out.String(), want) {
			t.Fatalf("missing %s in %s", want, out.String())
		}
	}
	if strings.Contains(out.String(), "Doctor passed") {
		t.Fatal(out.String())
	}
}
func TestDoctorPrintsPathsAndChecksEveryMarker(t *testing.T) {
	dir := t.TempDir()
	exe := join(dir, "tool with spaces")
	source := join(dir, "source")
	must(os.WriteFile(exe, []byte("#!/bin/sh\nexit 0\n"), 0755))
	must(write(join(source, "src/MQTTAsync.c"), "fixture"))
	c := &buildConfig{Paths: map[string]string{"paho_source": source}, Tools: map[string]string{"make": exe}}
	r := []requirement{{key: "paho_source", marker: "src/MQTTAsync.c"}, {key: "paho_source", marker: "CMakeLists.txt"}, {key: "make", tool: true}, {key: "make", tool: true}}
	var out bytes.Buffer
	if doctorReport(&out, c, r, nil) == nil || !strings.Contains(out.String(), "CMakeLists.txt") {
		t.Fatal(out.String())
	}
	must(write(join(source, "CMakeLists.txt"), "fixture"))
	out.Reset()
	if err := doctorReport(&out, c, r, nil); err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{exe, source, "Doctor passed"} {
		if !strings.Contains(out.String(), want) {
			t.Fatal(out.String())
		}
	}
	if strings.Count(out.String(), "[OK] tools.make") != 1 {
		t.Fatal(out.String())
	}
	must(os.Chmod(exe, 0644))
	out.Reset()
	if doctorReport(&out, c, r, nil) == nil || !strings.Contains(out.String(), "not an executable") {
		t.Fatal(out.String())
	}
}
func TestDoctorNativeTargetRequirements(t *testing.T) {
	has := func(r []requirement, key string) bool {
		for _, v := range r {
			if v.key == key {
				return true
			}
		}
		return false
	}
	for _, platform := range []string{"host", "ios"} {
		if has(nativeRequirements(platform), "ndk") {
			t.Fatal(platform, "requires NDK")
		}
	}
	if !has(nativeRequirements("android"), "ndk") || has(nativeRequirements("android"), "pod") {
		t.Fatal("invalid Android dependencies")
	}
	if has(appRequirements("ios"), "paho_source") || has(appRequirements("android"), "openssl_source") {
		t.Fatal("App check requires source builds")
	}
}
func TestDoctorRejectsInvalidScope(t *testing.T) {
	for _, args := range [][]string{{"--target", "unknown"}, {"--target", "native", "--platform", "unknown"}, {"--target", "ios-app", "--platform", "host"}} {
		if doctorCommand(args) == nil {
			t.Fatal("accepted", args)
		}
	}
	if err := doctorCommand([]string{"--help"}); err != flag.ErrHelp {
		t.Fatal(err)
	}
}
