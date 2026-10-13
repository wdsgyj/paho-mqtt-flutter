package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
)

type nativeOptions struct{ platform, ndk, openssl, paho, dart, deployment, api string }

func nativeCommand(args []string) error {
	f := flag.NewFlagSet("native", flag.ContinueOnError)
	o := nativeOptions{}
	config := addConfigFlags(f)
	f.StringVar(&o.platform, "platform", "all", "all, android, ios or host (macOS arm64)")
	f.StringVar(&o.deployment, "deployment-target", "15.0", "iOS deployment target")
	f.StringVar(&o.api, "android-platform", "android-21", "Android API target")
	if e := f.Parse(args); e != nil {
		return e
	}
	if f.NArg() != 0 {
		return fmt.Errorf("unexpected native arguments")
	}
	if o.platform != "all" && o.platform != "android" && o.platform != "ios" && o.platform != "host" {
		return fmt.Errorf("invalid platform")
	}
	c, err := config.load(f)
	if err != nil {
		return err
	}
	if err = nativePlatformError(o.platform); err != nil {
		return err
	}
	if err = c.requireAll(nativeRequirements(o.platform)); err != nil {
		return err
	}
	if o.platform == "all" || o.platform == "ios" {
		if !regexp.MustCompile(`^(1[5-9]|[2-9][0-9])\.\d+$`).MatchString(o.deployment) {
			return fmt.Errorf("iOS deployment target must be >=15.0")
		}
	}
	activeConfig = c
	o.openssl, o.paho, o.dart, o.ndk = c.Paths["openssl_source"], c.Paths["paho_source"], c.Paths["dart_sdk_include"], c.Paths["ndk"]
	if o.platform == "all" || o.platform == "android" {
		api, err := strconv.Atoi(strings.TrimPrefix(o.api, "android-"))
		if err != nil || api < 21 || !strings.HasPrefix(o.api, "android-") {
			return fmt.Errorf("--android-platform must be android-21 or newer")
		}
		nativeAndroid(o)
	}
	if o.platform == "all" || o.platform == "ios" {
		if runtime.GOOS != "darwin" {
			return fmt.Errorf("iOS requires macOS")
		}
		nativeIOS(o)
	}
	if o.platform == "all" || o.platform == "host" {
		if runtime.GOOS != "darwin" || runtime.GOARCH != "arm64" {
			return fmt.Errorf("host target requires macOS arm64")
		}
		nativeHost(o)
	}
	return nil
}
func openssl(o nativeOptions, work, target string, env map[string]string, extra ...string) string {
	ssl := join(work, "openssl-build")
	prefix := join(work, "openssl-install")
	must(mkdir(ssl))
	args := []string{"perl", join(o.openssl, "Configure"), target, "no-shared", "no-module", "no-tests", "--prefix=" + prefix, "--libdir=lib"}
	args = append(args, extra...)
	cmd(ssl, env, args...)
	makefile := read(join(ssl, "Makefile"))
	flags := ""
	for _, k := range []string{"CFLAGS", "CNF_CFLAGS"} {
		m := regexp.MustCompile(`(?m)^` + k + `=(.*)$`).FindStringSubmatch(makefile)
		if len(m) < 2 {
			panic("missing OpenSSL flags")
		}
		flags += " " + m[1]
	}
	checkFlags(flags)
	cmd(ssl, env, "make", "-j8", "build_libs")
	cmd(ssl, env, "make", "install_dev")
	return prefix
}
func checkFlags(flags string) {
	v := strings.Fields(flags)
	hasOs, hasG := false, false
	for _, s := range v {
		if s == "-Os" {
			hasOs = true
		}
		if s == "-g" {
			hasG = true
		}
		if s == "-O0" || s == "-O1" || s == "-O2" || s == "-O3" || s == "-Og" {
			panic("unexpected optimization: " + s)
		}
	}
	if !hasOs || !hasG {
		panic("expected -Os and -g: " + flags)
	}
}
func cmakeNative(o nativeOptions, work, prefix string, extra ...string) string {
	native := join(work, "native")
	args := []string{"cmake", "-S", join(src, "native"), "-B", native, "-G", "Ninja", "-DCMAKE_BUILD_TYPE=Release", "-DMQTT_WITH_TLS=ON", "-DPAHO_SOURCE_DIR=" + o.paho, "-DMQTT_GO_EXECUTABLE=" + tool("go"), "-DCMAKE_MAKE_PROGRAM=" + tool("ninja"), "-DDART_SDK_INCLUDE_DIR=" + o.dart, "-DOPENSSL_INCLUDE_DIR=" + join(prefix, "include"), "-DOPENSSL_SSL_LIBRARY=" + join(prefix, "lib/libssl.a"), "-DOPENSSL_CRYPTO_LIBRARY=" + join(prefix, "lib/libcrypto.a")}
	args = append(args, extra...)
	cmd(root, nil, args...)
	cmd(root, nil, "cmake", "--build", native, "--parallel", "8")
	var entries []struct{ Command string }
	must(json.Unmarshal([]byte(read(join(native, "compile_commands.json"))), &entries))
	for _, e := range entries {
		checkFlags(e.Command)
	}
	return native
}
func nativeMeta(o nativeOptions, target string) map[string]any {
	return map[string]any{"kind": "native", "target": target, "optimization": "-Os", "debug_info": true, "tls": true, "abi": 2, "core_abi": 2, "source_sha256": get(sourceHash()), "openssl": read(join(o.openssl, "VERSION.dat")), "paho_commit": capture(root, "git", "-C", o.paho, "rev-parse", "HEAD"), "paho_diff": capture(root, "git", "-C", o.paho, "diff", "HEAD", "--", "src"), "dart_version": strings.TrimSpace(read(join(o.dart, "../version")))}
}
func nativeAndroid(o nativeOptions) {
	if !regexp.MustCompile(`^android-\d+$`).MatchString(o.api) {
		panic("expected android-N API")
	}
	work := get(workspace("native-android"))
	host := "darwin-x86_64"
	if runtime.GOOS == "linux" {
		host = "linux-x86_64"
	}
	llvm := join(o.ndk, "toolchains/llvm/prebuilt", host, "bin")
	env := map[string]string{"ANDROID_NDK_ROOT": o.ndk, "PATH": llvm + string(os.PathListSeparator) + configEnvironment()["PATH"], "CFLAGS": "-Os -g -fPIC -DNDEBUG"}
	prefix := openssl(o, work, "android-arm64", env, "-D__ANDROID_API__="+strings.TrimPrefix(o.api, "android-"))
	native := cmakeNative(o, work, prefix, "-DCMAKE_TOOLCHAIN_FILE="+join(o.ndk, "build/cmake/android.toolchain.cmake"), "-DANDROID_ABI=arm64-v8a", "-DANDROID_PLATFORM="+o.api, "-DCMAKE_SHARED_LINKER_FLAGS=-Wl,--build-id=sha1")
	stage := join(work, "artifacts")
	release := join(stage, "release/libmqtt_sdk.so")
	symbols := join(stage, "symbols/libmqtt_sdk.so")
	must(mkdir(filepath.Dir(symbols)))
	must(mkdir(filepath.Dir(release)))
	original := join(native, "libmqtt_sdk.so")
	must(copyFile(original, symbols))
	cmd(root, nil, join(llvm, "llvm-strip"), "--strip-unneeded", "-o", release, original)
	cmd(root, nil, join(llvm, "llvm-objcopy"), "--add-gnu-debuglink="+symbols, release)
	id := regexp.MustCompile(`Build ID: (\w+)`)
	a := id.FindStringSubmatch(capture(root, join(llvm, "llvm-readelf"), "-n", release))
	b := id.FindStringSubmatch(capture(root, join(llvm, "llvm-readelf"), "-n", symbols))
	if len(a) != 2 || len(b) != 2 || a[1] != b[1] {
		panic("native Build ID mismatch")
	}
	if !strings.Contains(capture(root, join(llvm, "llvm-readelf"), "-S", symbols), ".debug_info") {
		panic("missing native DWARF")
	}
	meta := nativeMeta(o, "android-arm64")
	meta["build_id"] = a[1]
	meta["android_api"] = o.api
	meta["ndk"] = read(join(o.ndk, "source.properties"))
	must(manifest(stage, meta))
	must(publish(stage, join(dist, "android/arm64-v8a")))
	must(clean(work))
}

// buildHost keeps executables and dependency libraries in one disposable workspace.
func buildHost(o nativeOptions) (work, native string) {
	work = get(workspace("native-host"))
	prefix := openssl(o, work, "darwin64-arm64-cc", map[string]string{"CFLAGS": "-Os -g -fPIC -DNDEBUG"})
	native = cmakeNative(o, work, prefix, "-DMQTT_BUILD_HOST_CHECK=ON", "-DCMAKE_OSX_ARCHITECTURES=arm64", "-DCMAKE_BUILD_WITH_INSTALL_RPATH=ON", "-DCMAKE_INSTALL_RPATH=@loader_path")
	assertHostExports(join(native, "libmqtt_sdk.dylib"))
	cmd(root, nil, "ctest", "--test-dir", native, "--output-on-failure")
	// Standalone trust loader fixture shares this optimized OpenSSL build.
	cmd(root, nil, "xcrun", "clang", "-Os", "-g", "-DNDEBUG", "-Wall", "-Wextra", "-Werror", "-I", join(src, "native/tls"), "-I", join(prefix, "include"), join(src, "native/tests/tls_roots_check.c"), join(src, "native/tls/mqtt_tls.c"), join(prefix, "lib/libssl.a"), join(prefix, "lib/libcrypto.a"), "-framework", "Security", "-framework", "CoreFoundation", "-o", join(native, "tls_roots_check"))
	return work, native
}
func nativeHost(o nativeOptions) {
	work, native := buildHost(o)
	stage := join(work, "artifacts")
	library := join(stage, hostLibraryRelative)
	must(copyFile(join(native, "libmqtt_sdk.dylib"), library))
	cmd(root, nil, "xcrun", "strip", "-S", "-x", library)
	assertHostExports(library)
	must(publishHostLibrary(stage, join(dist, "test")))
	must(clean(work))
}

// Check both before tests and after stripping so new dependency exports cannot leak.
func assertHostExports(library string) {
	symbols := strings.Fields(capture(root, "xcrun", "nm", "-gUj", library))
	if len(symbols) != 1 || symbols[0] != "_mqtt_get_api" {
		panic(fmt.Sprintf("unexpected host dylib exports: %v", symbols))
	}
}

const hostLibraryRelative = "macos-arm64/release/libmqtt_sdk.dylib"

// The host test distribution intentionally has no manifest or symbol archive.
// Validate the copy in memory, then replace the test directory with rollback on failure.
func publishHostLibrary(stage, destination string) error {
	expected, err := hashFile(join(stage, hostLibraryRelative))
	if err != nil {
		return err
	}
	return publishDirectory(stage, destination, func(dir string) error {
		files, err := fileHashes(dir)
		if err != nil {
			return err
		}
		if len(files) != 1 || files[hostLibraryRelative] != expected {
			return fmt.Errorf("host distribution must contain only the matching %s", hostLibraryRelative)
		}
		return nil
	})
}
func nativeIOS(o nativeOptions) {
	if !regexp.MustCompile(`^(1[5-9]|[2-9][0-9])\.\d+$`).MatchString(o.deployment) {
		panic("iOS deployment target must be >=15.0")
	}
	work := get(workspace("native-ios"))
	stage := join(work, "artifacts")
	headers := join(work, "Headers")
	must(mkdir(headers))
	for _, name := range []string{"mqtt_api.h", "mqtt_api_v2.h", "mqtt_error.h"} {
		must(copyFile(join(src, "native/include", name), join(headers, name)))
	}
	must(write(join(headers, "module.modulemap"), "module CMqttSdk {\n  header \"mqtt_api_v2.h\"\n  export *\n}\n"))
	libraries := []string{}
	for _, sdk := range []string{"iphoneos", "iphonesimulator"} {
		directory := join(work, sdk)
		sysroot := capture(root, "xcrun", "--sdk", sdk, "--show-sdk-path")
		triple := "arm64-apple-ios" + o.deployment
		target := "ios64-xcrun"
		if sdk == "iphonesimulator" {
			triple += "-simulator"
			target = "iossimulator-arm64-xcrun"
		}
		env := map[string]string{"CROSS_TOP": filepath.Dir(filepath.Dir(sysroot)), "CROSS_SDK": filepath.Base(sysroot), "SDKROOT": sysroot, "CC": capture(root, "xcrun", "--sdk", sdk, "-f", "clang"), "CFLAGS": "-Os -g -fPIC -DNDEBUG -target " + triple + " -isysroot '" + sysroot + "'"}
		prefix := openssl(o, directory, target, env)
		native := cmakeNative(o, directory, prefix, "-DCMAKE_SYSTEM_NAME=iOS", "-DCMAKE_OSX_SYSROOT="+sysroot, "-DCMAKE_OSX_ARCHITECTURES=arm64", "-DCMAKE_OSX_DEPLOYMENT_TARGET="+o.deployment)
		library := join(directory, "libCMqttSdk.a")
		cmd(root, nil, "xcrun", "libtool", "-static", "-o", library, join(native, "libmqtt_sdk.a"), join(native, "paho/src/libpaho-mqtt3as.a"), join(prefix, "lib/libssl.a"), join(prefix, "lib/libcrypto.a"))
		libraries = append(libraries, library)
		// Never strip static libraries. The XCFramework retains the optimized DWARF;
		// the final App link is responsible for dSYM generation and stripping.
		for _, name := range []string{"mqtt_get_api", "MQTTAsync_createWithOptions", "SSL_CTX_new"} {
			if !strings.Contains(capture(root, "xcrun", "dwarfdump", "--name="+name, library), "DW_TAG_subprogram") {
				panic("missing static DWARF: " + name)
			}
		}
	}
	args := []string{"xcodebuild", "-create-xcframework"}
	for _, library := range libraries {
		args = append(args, "-library", library, "-headers", headers)
	}
	args = append(args, "-output", join(stage, "release/CMqttSdk.xcframework"))
	cmd(root, nil, args...)
	meta := nativeMeta(o, "ios-arm64+simulator-arm64")
	meta["deployment_target"] = o.deployment
	meta["xcode"] = capture(root, "xcodebuild", "-version")
	meta["symbols_note"] = "Unstripped -Os static XCFramework with DWARF. Only the consuming App generates dSYM and strips symbols."
	must(manifest(stage, meta))
	must(publish(stage, join(dist, "ios")))
	must(clean(work))
}
