package main

import (
	"bytes"
	"context"
	"errors"
	"flag"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"go.yaml.in/yaml/v3"
)

const defaultPahoTag = "v1.3.16"
const defaultOpenSSLTag = "openssl-4.0.2"

var pahoBasePatches = []string{"paho-connected-session.patch", "paho-platform-trust.patch", "paho-diagnostics.patch"}

type sourceDownload struct{ name, key, repository, tag string }

func (d sourceDownload) validate(directory string) error {
	if directory == "" {
		return fmt.Errorf("source path is not configured")
	}
	markers := []string{"Configure", "VERSION.dat"}
	if d.name == "paho" {
		markers = []string{"CMakeLists.txt", "src/MQTTAsync.c", "src/MQTTAsync.h"}
	}
	for _, marker := range markers {
		info, err := os.Stat(join(directory, marker))
		if err != nil || !info.Mode().IsRegular() {
			return fmt.Errorf("missing source file: %s", join(directory, marker))
		}
	}
	return nil
}
func downloadCommand(args []string) error {
	f := flag.NewFlagSet("download", flag.ContinueOnError)
	config := addConfigFlags(f)
	dependency := f.String("dependency", "all", "all, paho or openssl; download only missing/invalid sources")
	pahoTag := f.String("paho-tag", defaultPahoTag, "Paho Git tag to download")
	opensslTag := f.String("openssl-tag", defaultOpenSSLTag, "OpenSSL Git tag to download")
	if err := f.Parse(args); err != nil {
		return err
	}
	if *dependency != "all" && *dependency != "paho" && *dependency != "openssl" {
		return fmt.Errorf("invalid dependency: %s", *dependency)
	}
	// Unlike builds, download may create an explicitly selected configuration file.
	c, err := config.loadAllowMissing(f, true)
	if err != nil {
		return err
	}
	file, err := filepath.Abs(*config.file)
	if err != nil {
		return err
	}
	expected, err := readOptionalFile(file)
	if err != nil {
		return err
	}
	activeConfig = c
	sources := []sourceDownload{
		{"paho", "paho_source", "https://github.com/eclipse-paho/paho.mqtt.c.git", *pahoTag},
		{"openssl", "openssl_source", "https://github.com/openssl/openssl.git", *opensslTag},
	}
	for _, source := range sources {
		if *dependency != "all" && *dependency != source.name {
			continue
		}
		directory := c.Paths[source.key]
		if err = source.validate(directory); err == nil {
			fmt.Printf("Using existing %s source: %s (tag option applies only to downloads)\n", source.name, directory)
		} else {
			fmt.Printf("%s source unavailable: %v\n", source.name, err)
			if err = c.requireTools("git"); err != nil {
				return err
			}
			directory, err = source.fetch(join(src, "deps"))
			if err != nil {
				return err
			}
		}
		// Persist after each success so a later network failure does not lose completed work.
		expected, err = updateSourceConfig(file, source.key, directory, expected)
		if err != nil {
			return err
		}
		c.Paths[source.key] = directory
		fmt.Printf("Configured paths.%s = %s\n", source.key, directory)
	}
	fmt.Println("Source paths saved to:", file)
	return nil
}

// Git streams its own transfer progress. A heartbeat also covers DNS and server stalls.
func downloadGit(directory string, args ...string) error {
	fmt.Println("+ git", strings.Join(args, " "))
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Minute)
	defer cancel()
	command := exec.CommandContext(ctx, tool("git"), args...)
	command.Dir = directory
	command.Env = envMerge(map[string]string{"GIT_TERMINAL_PROMPT": "0"})
	command.Stdout = os.Stdout
	command.Stderr = os.Stderr
	if err := command.Start(); err != nil {
		return err
	}
	done := make(chan error, 1)
	go func() { done <- command.Wait() }()
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	started := time.Now()
	for {
		select {
		case err := <-done:
			if ctx.Err() != nil {
				return fmt.Errorf("Git download timed out: %w", ctx.Err())
			}
			if err != nil {
				return fmt.Errorf("Git download failed: %w", err)
			}
			return nil
		case <-ticker.C:
			fmt.Printf("Download in progress (%s elapsed)...\n", time.Since(started).Round(time.Second))
		}
	}
}
func (d sourceDownload) fetch(deps string) (string, error) {
	if _, err := output(root, "git", "check-ref-format", "refs/tags/"+d.tag); err != nil || d.tag == "" {
		return "", fmt.Errorf("invalid %s tag: %q", d.name, d.tag)
	}
	destination := join(deps, d.name+"-"+url.PathEscape(d.tag))
	if _, err := os.Lstat(destination); err == nil {
		if err = d.validateManaged(destination); err != nil {
			return "", fmt.Errorf("refuse to replace existing directory %s: %w", destination, err)
		}
		fmt.Println("Reusing completed download:", destination)
		return destination, nil
	} else if !os.IsNotExist(err) {
		return "", err
	}
	if err := mkdir(deps); err != nil {
		return "", err
	}
	staging, err := os.MkdirTemp(deps, ".download-"+d.name+"-")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(staging)
	checkout := join(staging, "source")
	fmt.Printf("Downloading %s tag %s from %s\n", d.name, d.tag, d.repository)
	for _, args := range [][]string{
		{"init", "--quiet", checkout},
		{"-C", checkout, "remote", "add", "origin", d.repository},
		{"-C", checkout, "fetch", "--progress", "--depth=1", "origin", "refs/tags/" + d.tag + ":refs/tags/" + d.tag},
		{"-C", checkout, "checkout", "--quiet", "--detach", "refs/tags/" + d.tag},
	} {
		if err = downloadGit(root, args...); err != nil {
			return "", err
		}
	}
	if err = d.validate(checkout); err != nil {
		return "", err
	}
	if d.name == "paho" {
		for _, patch := range pahoBasePatches {
			file := join(src, "patches", patch)
			fmt.Println("Applying SDK patch:", patch)
			if err = run(checkout, nil, "git", "apply", "--check", file); err != nil {
				return "", fmt.Errorf("Paho tag %s is incompatible with %s: %w", d.tag, patch, err)
			}
			if err = run(checkout, nil, "git", "apply", file); err != nil {
				return "", err
			}
		}
		// Fail before publishing/configuring a tag incompatible with the MQTT 5 overlay.
		if err = overlay(checkout, join(staging, "overlay-check")); err != nil {
			return "", err
		}
	}
	if err = d.validateManaged(checkout); err != nil {
		return "", err
	}
	if err = os.Rename(checkout, destination); err != nil {
		return "", err
	}
	fmt.Println("Source ready:", destination)
	return destination, nil
}
func (d sourceDownload) validateManaged(directory string) error {
	info, err := os.Lstat(directory)
	if err != nil {
		return err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("not an owned source directory")
	}
	if err = d.validate(directory); err != nil {
		return err
	}
	origin, err := output(directory, "git", "remote", "get-url", "origin")
	if err != nil {
		return err
	}
	if origin != d.repository {
		return fmt.Errorf("repository mismatch")
	}
	head, err := output(directory, "git", "rev-parse", "HEAD")
	if err != nil {
		return err
	}
	tag, err := output(directory, "git", "rev-parse", "--verify", "refs/tags/"+d.tag+"^{commit}")
	if err != nil {
		return err
	}
	if head != tag {
		return fmt.Errorf("tag/HEAD mismatch")
	}
	if d.name == "paho" {
		for _, patch := range pahoBasePatches {
			if _, err = output(directory, "git", "apply", "--reverse", "--check", join(src, "patches", patch)); err != nil {
				return fmt.Errorf("incomplete SDK patches: %w", err)
			}
		}
	}
	return nil
}
func readOptionalFile(file string) ([]byte, error) {
	data, err := os.ReadFile(file)
	if os.IsNotExist(err) {
		return nil, nil
	}
	return data, err
}

// Edit only the selected YAML path, preserving comments and unrelated user settings.
// Compare the original bytes before replacement to avoid clobbering concurrent edits.
func updateSourceConfig(file, key, directory string, expected []byte) ([]byte, error) {
	current, err := readOptionalFile(file)
	if err != nil {
		return nil, err
	}
	if !bytes.Equal(current, expected) {
		return nil, fmt.Errorf("configuration changed during download; source kept at %s; rerun download", directory)
	}
	if _, err = readBuildConfig(file, false); err != nil {
		return nil, err
	}
	var document yaml.Node
	if len(current) == 0 {
		document = yaml.Node{Kind: yaml.DocumentNode, Content: []*yaml.Node{{Kind: yaml.MappingNode, Tag: "!!map"}}}
	} else if err = yaml.Unmarshal(current, &document); err != nil {
		return nil, err
	}
	if len(document.Content) != 1 || document.Content[0].Kind != yaml.MappingNode {
		return nil, fmt.Errorf("configuration must be a YAML mapping")
	}
	mapping := document.Content[0]
	var paths *yaml.Node
	for i := 0; i < len(mapping.Content); i += 2 {
		if mapping.Content[i].Value == "paths" {
			paths = mapping.Content[i+1]
		}
	}
	if paths == nil {
		paths = &yaml.Node{Kind: yaml.MappingNode, Tag: "!!map"}
		mapping.Content = append(mapping.Content, &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: "paths"}, paths)
	}
	if paths.Tag == "!!null" {
		*paths = yaml.Node{Kind: yaml.MappingNode, Tag: "!!map"}
	}
	if paths.Kind != yaml.MappingNode {
		return nil, fmt.Errorf("configuration paths must be a mapping")
	}
	relative, err := filepath.Rel(filepath.Dir(file), directory)
	if err != nil {
		return nil, err
	}
	value := filepath.ToSlash(relative)
	found := false
	for i := 0; i < len(paths.Content); i += 2 {
		if paths.Content[i].Value == key {
			paths.Content[i+1].Kind = yaml.ScalarNode
			paths.Content[i+1].Tag = "!!str"
			paths.Content[i+1].Value = value
			paths.Content[i+1].Content = nil
			found = true
		}
	}
	if !found {
		paths.Content = append(paths.Content, &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: key}, &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: value})
	}
	var data bytes.Buffer
	encoder := yaml.NewEncoder(&data)
	encoder.SetIndent(2)
	if err = encoder.Encode(&document); err != nil {
		return nil, err
	}
	if err = encoder.Close(); err != nil {
		return nil, err
	}
	if bytes.Equal(current, data.Bytes()) {
		return current, nil
	}
	if err = mkdir(filepath.Dir(file)); err != nil {
		return nil, err
	}
	temp, err := os.CreateTemp(filepath.Dir(file), ".build-yaml-*")
	if err != nil {
		return nil, err
	}
	defer os.Remove(temp.Name())
	mode := os.FileMode(0644)
	if info, e := os.Stat(file); e == nil {
		mode = info.Mode().Perm()
	}
	err = errors.Join(temp.Chmod(mode), func() error { _, e := temp.Write(data.Bytes()); return e }(), temp.Close())
	if err != nil {
		return nil, err
	}
	latest, err := readOptionalFile(file)
	if err != nil {
		return nil, err
	}
	if !bytes.Equal(latest, expected) {
		return nil, fmt.Errorf("configuration changed during download; refusing to overwrite %s", file)
	}
	if err = os.Rename(temp.Name(), file); err != nil {
		return nil, err
	}
	return data.Bytes(), nil
}
