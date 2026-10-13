package main

import (
	"bytes"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"

	"go.yaml.in/yaml/v3"
)

// Paths in YAML are relative to that file; command-line paths are relative to cwd.
// Explicit CLI options override discovery; YAML supplies sources and discovery fallbacks.
type buildConfig struct {
	Paths map[string]string `yaml:"paths"`
	Tools map[string]string `yaml:"tools"`
}

var activeConfig *buildConfig
var pathOptions = map[string]string{
	"paho_source": "paho-source", "openssl_source": "openssl-source", "dart_sdk_include": "dart-sdk-include",
	"ndk": "ndk", "android_sdk": "android-sdk", "java_home": "java-home", "developer_dir": "developer-dir",
}
var toolNames = []string{"go", "cmake", "ninja", "ctest", "make", "perl", "git", "flutter", "dart", "xcrun", "xcodebuild", "pod", "openssl", "mosquitto"}

type configFlags struct {
	file         *string
	paths, tools map[string]*string
}

func addConfigFlags(f *flag.FlagSet) configFlags {
	c := configFlags{file: f.String("config", join(root, "scripts/config/build.yaml"), "YAML build configuration"), paths: map[string]*string{}, tools: map[string]*string{}}
	keys := []string{}
	for key := range pathOptions {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, key := range keys {
		c.paths[key] = f.String(pathOptions[key], "", "override paths."+key)
	}
	for _, key := range toolNames {
		c.tools[key] = f.String(key, "", "override tools."+key+" executable path")
	}
	return c
}
func resolvePath(base, value string) (string, error) {
	if value == "" {
		return "", nil
	}
	if value == "~" || strings.HasPrefix(value, "~/") {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		value = filepath.Join(home, strings.TrimPrefix(value, "~"))
	}
	if !filepath.IsAbs(value) {
		value = filepath.Join(base, value)
	}
	return filepath.Abs(value)
}
func readBuildConfig(file string, required bool) (*buildConfig, error) {
	c := &buildConfig{Paths: map[string]string{}, Tools: map[string]string{}}
	data, err := os.ReadFile(file)
	if os.IsNotExist(err) && !required {
		return c, nil
	}
	if err != nil {
		return nil, fmt.Errorf("configuration %s: %w", file, err)
	}
	decoder := yaml.NewDecoder(bytes.NewReader(data))
	decoder.KnownFields(true)
	if err = decoder.Decode(c); err != nil {
		return nil, fmt.Errorf("configuration %s: %w", file, err)
	}
	var extra any
	if err = decoder.Decode(&extra); err != io.EOF {
		return nil, fmt.Errorf("configuration %s: expected exactly one YAML document", file)
	}
	if c.Paths == nil {
		c.Paths = map[string]string{}
	}
	if c.Tools == nil {
		c.Tools = map[string]string{}
	}
	for key, value := range c.Paths {
		if _, ok := pathOptions[key]; !ok {
			return nil, fmt.Errorf("unknown configuration path: %s", key)
		}
		c.Paths[key], err = resolvePath(filepath.Dir(file), value)
		if err != nil {
			return nil, err
		}
	}
	for key, value := range c.Tools {
		known := false
		for _, name := range toolNames {
			if name == key {
				known = true
			}
		}
		if !known {
			return nil, fmt.Errorf("unknown configuration tool: %s", key)
		}
		c.Tools[key], err = resolvePath(filepath.Dir(file), value)
		if err != nil {
			return nil, err
		}
	}
	return c, nil
}
func (options configFlags) load(f *flag.FlagSet) (*buildConfig, error) {
	return options.loadAllowMissing(f, false)
}
func (options configFlags) loadAllowMissing(f *flag.FlagSet, allowMissing bool) (*buildConfig, error) {
	if f.NArg() != 0 {
		return nil, fmt.Errorf("unexpected positional arguments: %v", f.Args())
	}
	provided := map[string]bool{}
	f.Visit(func(v *flag.Flag) { provided[v.Name] = true })
	c, err := readBuildConfig(*options.file, provided["config"] && !allowMissing)
	if err != nil {
		return nil, err
	}
	cwd, err := os.Getwd()
	if err != nil {
		return nil, err
	}
	for key, value := range options.paths {
		if provided[pathOptions[key]] {
			c.Paths[key], err = resolvePath(cwd, *value)
			if err != nil {
				return nil, err
			}
		}
	}
	for key, value := range options.tools {
		if provided[key] {
			c.Tools[key], err = resolvePath(cwd, *value)
			if err != nil {
				return nil, err
			}
		}
	}
	home, _ := os.UserHomeDir()
	c.discover(provided, exec.LookPath, os.Getenv, home, "/Applications/Xcode.app/Contents/Developer")
	return c, nil
}

// Kept separate from validation so each command validates only the inputs it uses.
// Lookup functions and conventional roots are arguments to make discovery testable.
func (c *buildConfig) discover(provided map[string]bool, lookPath func(string) (string, error), getenv func(string) string, home, defaultXcode string) {
	for _, name := range toolNames {
		if name == "dart" || provided[name] {
			continue
		}
		if value, err := lookPath(name); err == nil {
			c.Tools[name] = get(filepath.Abs(value))
		}
	}
	if !provided["java-home"] && getenv("JAVA_HOME") != "" {
		c.Paths["java_home"] = get(filepath.Abs(getenv("JAVA_HOME")))
	}
	if sdk := join(home, "Library/Android/sdk"); home != "" && !provided["android-sdk"] && exists(join(sdk, "platform-tools/adb")) {
		c.Paths["android_sdk"] = sdk
	}
	if !provided["developer-dir"] && exists(join(defaultXcode, "usr/bin/xcodebuild")) {
		c.Paths["developer_dir"] = defaultXcode
	}
	// Resolve symlinked launchers as well as SDK paths containing a wrapper executable.
	if flutter := c.Tools["flutter"]; flutter != "" {
		resolved, err := filepath.EvalSymlinks(flutter)
		if err != nil {
			resolved = flutter
		}
		for _, launcher := range []string{resolved, flutter} {
			sdk := join(filepath.Dir(launcher), "cache/dart-sdk")
			if !exists(join(sdk, "bin/dart")) {
				continue
			}
			if !provided["dart"] {
				c.Tools["dart"] = join(sdk, "bin/dart")
			}
			if !provided["dart-sdk-include"] && exists(join(sdk, "include/dart_api_dl.h")) {
				c.Paths["dart_sdk_include"] = join(sdk, "include")
			}
			break
		}
	}
}
func (c *buildConfig) requirePath(key, marker string) error {
	value := c.Paths[key]
	if value == "" {
		return fmt.Errorf("missing paths.%s: set it in scripts/config/build.yaml (or --config FILE), or pass --%s", key, pathOptions[key])
	}
	info, err := os.Stat(value)
	if err != nil || !info.IsDir() {
		return fmt.Errorf("paths.%s is not an accessible directory: %s", key, value)
	}
	if marker != "" && !exists(join(value, marker)) {
		return fmt.Errorf("paths.%s: missing %s in %s", key, marker, value)
	}
	return nil
}
func (c *buildConfig) requireTools(names ...string) error {
	for _, name := range names {
		value := c.Tools[name]
		if value == "" {
			return fmt.Errorf("missing tools.%s: configure it or pass --%s /path/to/executable", name, name)
		}
		info, err := os.Stat(value)
		if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0111 == 0 {
			return fmt.Errorf("tools.%s is not an executable file: %s", name, value)
		}
	}
	return nil
}
func tool(name string) string {
	if activeConfig != nil && !strings.ContainsRune(name, os.PathSeparator) {
		for _, known := range toolNames {
			if name == known {
				must(activeConfig.requireTools(name))
				return activeConfig.Tools[name]
			}
		}
	}
	return name
}

// Also expose selected tool directories to subprocesses (CMake, OpenSSL and Flutter).
func configEnvironment() map[string]string {
	env := map[string]string{}
	if activeConfig == nil {
		return env
	}
	dirs := []string{}
	seen := map[string]bool{}
	for _, name := range toolNames {
		if value := activeConfig.Tools[name]; value != "" {
			dir := filepath.Dir(value)
			if !seen[dir] {
				dirs = append(dirs, dir)
				seen[dir] = true
			}
		}
	}
	for key, variable := range map[string]string{"java_home": "JAVA_HOME", "android_sdk": "ANDROID_HOME", "developer_dir": "DEVELOPER_DIR"} {
		if value := activeConfig.Paths[key]; value != "" {
			env[variable] = value
		}
	}
	if value := env["JAVA_HOME"]; value != "" {
		dirs = append([]string{join(value, "bin")}, dirs...)
	}
	if value := env["ANDROID_HOME"]; value != "" {
		env["ANDROID_SDK_ROOT"] = value
	}
	env["PATH"] = strings.Join(append(dirs, os.Getenv("PATH")), string(os.PathListSeparator))
	return env
}
func (c *buildConfig) requireApp(platform string) error {
	return c.requireAll(appRequirements(platform))
}
