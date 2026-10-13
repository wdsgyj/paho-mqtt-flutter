package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestDownloadConfigPreservesSettingsAndComments(t *testing.T) {
	base := t.TempDir()
	file := join(base, "config/build.yaml")
	initial := []byte("# user settings\npaths:\n  ndk: /custom/ndk # keep NDK\n  paho_source: /missing # source comment\ntools:\n  git: /custom/git\n")
	must(write(file, string(initial)))
	source := join(base, "deps/paho source")
	updated, err := updateSourceConfig(file, "paho_source", source, initial)
	if err != nil {
		t.Fatal(err)
	}
	for _, value := range []string{"# user settings", "# keep NDK", "# source comment", "/custom/ndk", "/custom/git", "../deps/paho source"} {
		if !strings.Contains(string(updated), value) {
			t.Fatal(string(updated))
		}
	}
	c, err := readBuildConfig(file, true)
	if err != nil || c.Paths["paho_source"] != source {
		t.Fatal(c, err)
	}
	must(write(file, string(updated)+"# edited concurrently\n"))
	if _, err = updateSourceConfig(file, "openssl_source", join(base, "ssl"), updated); err == nil {
		t.Fatal("overwrote concurrent edit")
	}
	if !strings.Contains(read(file), "edited concurrently") {
		t.Fatal("lost edit")
	}
}
func TestDownloadCreatesConfigAndRetainsOnFailure(t *testing.T) {
	file := join(t.TempDir(), "config/build.yaml")
	source := join(filepath.Dir(file), "source")
	data, err := updateSourceConfig(file, "openssl_source", source, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(data) == 0 {
		t.Fatal("no config created")
	}
	c, err := readBuildConfig(file, true)
	if err != nil || c.Paths["openssl_source"] != source {
		t.Fatal(c, err)
	}
	bad := []byte("paths:\n  typo: /bad\n")
	must(write(file, string(bad)))
	if _, err = updateSourceConfig(file, "openssl_source", source, bad); err == nil {
		t.Fatal("rewrote invalid YAML")
	}
	if read(file) != string(bad) {
		t.Fatal("modified failed config")
	}
}
func TestDownloadUsesExactTagAndCleansFailedFetch(t *testing.T) {
	git, err := exec.LookPath("git")
	if err != nil {
		t.Skip("git unavailable")
	}
	savedRoot, savedConfig := root, activeConfig
	t.Cleanup(func() { root = savedRoot; activeConfig = savedConfig })
	root = t.TempDir()
	activeConfig = &buildConfig{Paths: map[string]string{}, Tools: map[string]string{"git": git}}
	upstream := join(root, "upstream")
	must(mkdir(upstream))
	gitRun := func(args ...string) {
		t.Helper()
		if _, err := output(upstream, append([]string{"git"}, args...)...); err != nil {
			t.Fatal(err)
		}
	}
	gitRun("init", "--quiet")
	for _, name := range []string{"Configure", "VERSION.dat"} {
		must(write(join(upstream, name), "version one"))
	}
	gitRun("add", ".")
	gitRun("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "initial")
	gitRun("tag", "release-1")
	must(write(join(upstream, "VERSION.dat"), "version two"))
	gitRun("add", ".")
	gitRun("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "later")
	deps := join(root, "deps")
	d := sourceDownload{"openssl", "openssl_source", upstream, "release-1"}
	path, err := d.fetch(deps)
	if err != nil {
		t.Fatal(err)
	}
	if read(join(path, "VERSION.dat")) != "version one" {
		t.Fatal("fetched branch tip instead of tag")
	}
	again, err := d.fetch(deps)
	if err != nil || again != path {
		t.Fatal(again, err)
	}
	d.tag = "missing-tag"
	if _, err = d.fetch(deps); err == nil {
		t.Fatal("missing tag accepted")
	}
	entries, err := os.ReadDir(deps)
	if err != nil || len(entries) != 1 {
		t.Fatal(entries, err)
	}
	d.tag = "../escape"
	if _, err = d.fetch(deps); err == nil {
		t.Fatal("invalid ref accepted")
	}
}
func TestDownloadRejectsInvalidSource(t *testing.T) {
	base := t.TempDir()
	d := sourceDownload{name: "paho"}
	if d.validate("") == nil || d.validate(base) == nil {
		t.Fatal("invalid source accepted")
	}
	for _, name := range []string{"CMakeLists.txt", "src/MQTTAsync.c", "src/MQTTAsync.h"} {
		must(write(join(base, name), "fixture"))
	}
	if err := d.validate(base); err != nil {
		t.Fatal(err)
	}
}
