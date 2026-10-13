package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
)

// Both doctor and builds use these requirements to avoid divergent preflight checks.
type requirement struct {
	key, marker string
	tool        bool
}

func toolRequirements(names ...string) []requirement {
	result := []requirement{}
	for _, name := range names {
		result = append(result, requirement{key: name, tool: true})
	}
	return result
}
func nativeRequirements(platform string) []requirement {
	r := []requirement{{key: "paho_source", marker: "src/MQTTAsync.c"}, {key: "paho_source", marker: "CMakeLists.txt"}, {key: "openssl_source", marker: "Configure"}, {key: "openssl_source", marker: "VERSION.dat"}, {key: "dart_sdk_include", marker: "dart_api_dl.h"}, {key: "dart_sdk_include", marker: "dart_api_dl.c"}}
	r = append(r, toolRequirements("go", "cmake", "ninja", "make", "perl", "git")...)
	if platform == "all" || platform == "android" {
		r = append(r, requirement{key: "ndk", marker: "build/cmake/android.toolchain.cmake"})
	}
	if platform == "all" || platform == "ios" || platform == "host" {
		r = append(r, toolRequirements("xcrun")...)
	}
	if platform == "all" || platform == "host" {
		r = append(r, toolRequirements("ctest")...)
	}
	if platform == "all" || platform == "ios" {
		r = append(r, requirement{key: "developer_dir", marker: "usr/bin/xcodebuild"})
		r = append(r, toolRequirements("xcodebuild")...)
	}
	return r
}
func appRequirements(platform string) []requirement {
	r := toolRequirements("flutter")
	if platform == "android" {
		return append(r, requirement{key: "android_sdk", marker: "platform-tools/adb"}, requirement{key: "java_home", marker: "bin/java"})
	}
	r = append(r, requirement{key: "developer_dir", marker: "usr/bin/xcodebuild"})
	return append(r, toolRequirements("pod", "xcrun", "xcodebuild")...)
}
func (c *buildConfig) checkRequirement(r requirement) error {
	if r.tool {
		return c.requireTools(r.key)
	}
	return c.requirePath(r.key, r.marker)
}
func (c *buildConfig) requireAll(requirements []requirement) error {
	var failures []error
	for _, r := range requirements {
		if err := c.checkRequirement(r); err != nil {
			failures = append(failures, err)
		}
	}
	return errors.Join(failures...)
}
func nativePlatformError(platform string) error {
	if platform != "all" && platform != "android" && platform != "ios" && platform != "host" {
		return fmt.Errorf("invalid platform: %s", platform)
	}
	if platform != "android" && runtime.GOOS != "darwin" {
		return fmt.Errorf("iOS and host targets require macOS (current: %s/%s)", runtime.GOOS, runtime.GOARCH)
	}
	if (platform == "all" || platform == "host") && runtime.GOARCH != "arm64" {
		return fmt.Errorf("host target requires macOS arm64 (current: %s/%s)", runtime.GOOS, runtime.GOARCH)
	}
	return nil
}
func doctorCommand(args []string) error {
	f := flag.NewFlagSet("doctor", flag.ContinueOnError)
	config := addConfigFlags(f)
	target := f.String("target", "all", "all, native, android-app, ios-app, test or check-api")
	platform := f.String("platform", "all", "native target: all, android, ios or host (only with --target native)")
	if err := f.Parse(args); err != nil {
		return err
	}
	if *platform != "all" && *target != "native" {
		return fmt.Errorf("--platform requires --target native")
	}
	r := []requirement{}
	var platformErr error
	switch *target {
	case "all":
		r = append(r, nativeRequirements("all")...)
		r = append(r, appRequirements("android")...)
		r = append(r, appRequirements("ios")...)
		r = append(r, toolRequirements("flutter", "dart", "openssl", "mosquitto")...)
		platformErr = nativePlatformError("all")
	case "native":
		if *platform != "all" && *platform != "android" && *platform != "ios" && *platform != "host" {
			return fmt.Errorf("invalid platform: %s", *platform)
		}
		r = nativeRequirements(*platform)
		platformErr = nativePlatformError(*platform)
	case "android-app":
		r = appRequirements("android")
	case "ios-app":
		r = appRequirements("ios")
		platformErr = nativePlatformError("ios")
	case "test":
		r = append(nativeRequirements("host"), toolRequirements("flutter", "openssl", "mosquitto")...)
		platformErr = nativePlatformError("host")
	case "check-api":
		r = toolRequirements("dart")
	default:
		return fmt.Errorf("invalid doctor target: %s", *target)
	}
	c, err := config.load(f)
	if err != nil {
		return err
	}
	fmt.Printf("Checking %s dependencies (%s/%s)\n", *target, runtime.GOOS, runtime.GOARCH)
	if exists(*config.file) {
		fmt.Println("Configuration:", get(filepath.Abs(*config.file)))
	} else {
		fmt.Println("Configuration: no default file; using discovery and CLI options")
	}
	return doctorReport(os.Stdout, c, r, platformErr)
}
func doctorReport(out io.Writer, c *buildConfig, requirements []requirement, platformErr error) error {
	// Report each resolved path once, while checking every required marker beneath it.
	order := []string{}
	grouped := map[string][]requirement{}
	for _, r := range requirements {
		key := "paths." + r.key
		if r.tool {
			key = "tools." + r.key
		}
		if _, ok := grouped[key]; !ok {
			order = append(order, key)
		}
		duplicate := false
		for _, old := range grouped[key] {
			if old == r {
				duplicate = true
			}
		}
		if !duplicate {
			grouped[key] = append(grouped[key], r)
		}
	}
	failures := 0
	if platformErr != nil {
		fmt.Fprintln(out, "[FAIL]", platformErr)
		failures++
	}
	for _, key := range order {
		group := grouped[key]
		var problems []error
		seen := map[string]bool{}
		for _, r := range group {
			if err := c.checkRequirement(r); err != nil && !seen[err.Error()] {
				seen[err.Error()] = true
				problems = append(problems, err)
			}
		}
		if len(problems) > 0 {
			failures++
			for _, err := range problems {
				fmt.Fprintln(out, "[FAIL]", err)
			}
			continue
		}
		r := group[0]
		value := c.Paths[r.key]
		if r.tool {
			value = c.Tools[r.key]
		}
		fmt.Fprintf(out, "[OK] %s = %s\n", key, value)
		if resolved, err := filepath.EvalSymlinks(value); err == nil && resolved != value {
			fmt.Fprintln(out, "     resolved:", resolved)
		}
	}
	if failures > 0 {
		return fmt.Errorf("doctor: %d dependencies/platform checks failed; fix the items above", failures)
	}
	fmt.Fprintln(out, "Doctor passed: required tools and source paths are available.")
	fmt.Fprintln(out, "This checks paths and required files, not tool-version compatibility or build/test results.")
	return nil
}
