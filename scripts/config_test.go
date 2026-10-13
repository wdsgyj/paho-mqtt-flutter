package main

import (
	"flag"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestConfigPrecedenceAndRelativePaths(t *testing.T) {
	dir := t.TempDir()
	file := join(dir, "build.yaml")
	must(write(file, "paths:\n  paho_source: ../sources with spaces/paho\n  openssl_source: ssl\ntools:\n  cmake: ./bin/cmake\n"))
	f := flag.NewFlagSet("test", flag.ContinueOnError)
	options := addConfigFlags(f)
	must(f.Parse([]string{"--config", file, "--openssl-source", "./override ssl", "--cmake", "./override cmake"}))
	c, err := options.load(f)
	if err != nil {
		t.Fatal(err)
	}
	if c.Paths["paho_source"] != join(filepath.Dir(dir), "sources with spaces/paho") {
		t.Fatal(c.Paths)
	}
	cwd, _ := os.Getwd()
	if c.Paths["openssl_source"] != join(cwd, "override ssl") || c.Tools["cmake"] != join(cwd, "override cmake") {
		t.Fatal(c)
	}
}
func TestConfigRejectsMalformedOrUnknownInput(t *testing.T) {
	for _, input := range []string{"paths: [", "path: {}", "paths:\n  ndkk: /tmp", "tools:\n  cmakke: /tmp", "paths:\n  ndk: a\n  ndk: b", "paths: {}\n---\npaths: {}"} {
		t.Run(input, func(t *testing.T) {
			file := join(t.TempDir(), "build.yaml")
			must(write(file, input))
			if _, err := readBuildConfig(file, true); err == nil {
				t.Fatal("accepted invalid YAML")
			}
		})
	}
}
func TestConfigMissingSourceInputs(t *testing.T) {
	t.Setenv("OPENSSL_SOURCE_DIR", t.TempDir())
	file := join(t.TempDir(), "missing.yaml")
	c, err := readBuildConfig(file, false)
	if err != nil {
		t.Fatal(err)
	}
	if err = c.requirePath("openssl_source", "Configure"); err == nil || !strings.Contains(err.Error(), "--openssl-source") {
		t.Fatal(err)
	}
	if _, err = readBuildConfig(file, true); err == nil {
		t.Fatal("explicit missing config accepted")
	}
	// A missing default configuration is allowed when CLI supplies the inputs.
	f := flag.NewFlagSet("test", flag.ContinueOnError)
	options := addConfigFlags(f)
	*options.file = file
	must(f.Parse([]string{"--openssl-source", os.Getenv("OPENSSL_SOURCE_DIR")}))
	c, err = options.load(f)
	if err != nil {
		t.Fatal(err)
	}
	if err = c.requirePath("openssl_source", ""); err != nil {
		t.Fatal(err)
	}
}
func TestConfigValidationIsTargetSpecific(t *testing.T) {
	dir := t.TempDir()
	exe := join(dir, "tool")
	must(os.WriteFile(exe, []byte("#!/bin/sh\nexit 0\n"), 0755))
	must(write(join(dir, "usr/bin/xcodebuild"), "fixture"))
	c := &buildConfig{Paths: map[string]string{"developer_dir": dir}, Tools: map[string]string{"flutter": exe, "pod": exe, "xcrun": exe, "xcodebuild": exe}}
	if err := c.requireApp("ios"); err != nil {
		t.Fatal(err)
	}
	if err := c.requireApp("android"); err == nil {
		t.Fatal("Android SDK missing")
	}
	c.Tools["flutter"] = dir
	if err := c.requireTools("flutter"); err == nil {
		t.Fatal("directory accepted as executable")
	}
}
func TestConfiguredToolExecution(t *testing.T) {
	saved := activeConfig
	t.Cleanup(func() { activeConfig = saved })
	dir := t.TempDir()
	exe := join(dir, "fake cmake")
	must(os.WriteFile(exe, []byte("#!/bin/sh\nprintf '%s|%s' \"$1\" \"$ANDROID_HOME\"\n"), 0755))
	activeConfig = &buildConfig{Paths: map[string]string{"android_sdk": join(dir, "sdk")}, Tools: map[string]string{"cmake": exe}}
	got, err := output(dir, "cmake", "argument with spaces")
	if err != nil || got != "argument with spaces|"+join(dir, "sdk") {
		t.Fatalf("%q %v", got, err)
	}
}

func TestDiscoveryPriorityAndFlutterSymlinks(t *testing.T) {
	base := get(filepath.EvalSymlinks(t.TempDir()))
	flutter := join(base, "flutter sdk/bin/flutter")
	dart := join(base, "flutter sdk/bin/cache/dart-sdk/bin/dart")
	include := join(base, "flutter sdk/bin/cache/dart-sdk/include")
	for _, p := range []string{flutter, dart, join(include, "dart_api_dl.h")} {
		must(write(p, "fixture"))
	}
	launcher := join(base, "flutter-link")
	must(os.Symlink(flutter, launcher))
	home := join(base, "home")
	sdk := join(home, "Library/Android/sdk")
	xcode := join(base, "Xcode.app/Contents/Developer")
	must(write(join(sdk, "platform-tools/adb"), "fixture"))
	must(write(join(xcode, "usr/bin/xcodebuild"), "fixture"))
	lookup := func(name string) (string, error) {
		if name == "flutter" {
			return launcher, nil
		}
		if name == "make" {
			return "/path/make", nil
		}
		if name == "dart" {
			return "/unrelated/dart", nil
		}
		return "", os.ErrNotExist
	}
	env := func(name string) string {
		if name == "JAVA_HOME" {
			return "/env/jdk"
		}
		return ""
	}
	c := &buildConfig{Paths: map[string]string{"java_home": "/yaml/jdk", "android_sdk": "/yaml/sdk", "developer_dir": "/yaml/xcode", "dart_sdk_include": "/yaml/include"}, Tools: map[string]string{"make": "/yaml/make", "mosquitto": "/yaml/mosquitto", "dart": "/yaml/dart"}}
	c.discover(nil, lookup, env, home, xcode)
	for key, want := range map[string]string{"java_home": "/env/jdk", "android_sdk": sdk, "developer_dir": xcode, "dart_sdk_include": include} {
		if c.Paths[key] != want {
			t.Fatalf("%s=%s want %s", key, c.Paths[key], want)
		}
	}
	for key, want := range map[string]string{"make": "/path/make", "mosquitto": "/yaml/mosquitto", "dart": dart} {
		if c.Tools[key] != want {
			t.Fatalf("%s=%s want %s", key, c.Tools[key], want)
		}
	}
	// Explicit options win, including explicitly clearing a discovered value.
	c.Paths["java_home"] = "/cli/jdk"
	c.Paths["android_sdk"] = "/cli/sdk"
	c.Paths["developer_dir"] = "/cli/xcode"
	c.Paths["dart_sdk_include"] = "/cli/include"
	c.Tools["dart"] = "/cli/dart"
	c.Tools["make"] = ""
	c.discover(map[string]bool{"java-home": true, "android-sdk": true, "developer-dir": true, "dart-sdk-include": true, "dart": true, "make": true}, lookup, env, home, xcode)
	for key, want := range map[string]string{"java_home": "/cli/jdk", "android_sdk": "/cli/sdk", "developer_dir": "/cli/xcode", "dart_sdk_include": "/cli/include"} {
		if c.Paths[key] != want {
			t.Fatal(key, c.Paths[key])
		}
	}
	if c.Tools["dart"] != "/cli/dart" || c.Tools["make"] != "" {
		t.Fatal(c.Tools)
	}
}
func TestDiscoveryFallbackAndMissingTool(t *testing.T) {
	base := t.TempDir()
	lookup := func(string) (string, error) { return "", os.ErrNotExist }
	env := func(string) string { return "" }
	c := &buildConfig{Paths: map[string]string{"java_home": "/yaml/jdk", "android_sdk": "/yaml/sdk", "developer_dir": "/yaml/xcode"}, Tools: map[string]string{"cmake": "/yaml/cmake"}}
	c.discover(nil, lookup, env, base, join(base, "missing-xcode"))
	if c.Paths["java_home"] != "/yaml/jdk" || c.Paths["android_sdk"] != "/yaml/sdk" || c.Paths["developer_dir"] != "/yaml/xcode" || c.Tools["cmake"] != "/yaml/cmake" {
		t.Fatal(c)
	}
	if err := c.requireTools("make"); err == nil {
		t.Fatal("missing tool accepted")
	}
}
