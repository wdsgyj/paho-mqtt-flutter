package main

import (
	"archive/zip"
	"crypto/sha256"
	"encoding/hex"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

type appOptions struct {
	device, java, flutter, suite, trust string
	run                                 bool
}

func appCommand(platform string, args []string) error {
	f := flag.NewFlagSet(platform+"-app", flag.ContinueOnError)
	o := appOptions{}
	config := addConfigFlags(f)
	f.StringVar(&o.suite, "suite", "wire", "wire, runtime (iOS), trust (iOS) or smoke")
	f.StringVar(&o.device, "device", "", "device/emulator UUID for --run")
	f.StringVar(&o.trust, "trust-config", "", "JSON Dart defines for iOS trust fixture")
	f.BoolVar(&o.run, "run", false, "run integration tests after building; Debug for iOS simulator")
	if e := f.Parse(args); e != nil {
		return e
	}
	if o.suite != "wire" && o.suite != "runtime" && o.suite != "trust" && o.suite != "smoke" {
		return fmt.Errorf("invalid suite")
	}
	if platform == "android" && (o.suite == "runtime" || o.suite == "trust") {
		return fmt.Errorf("runtime/trust use iOS fixtures")
	}
	if o.run && (o.device == "" || o.suite == "smoke") {
		return fmt.Errorf("--run requires --device and an integration suite")
	}
	if o.suite == "trust" && o.trust == "" {
		return fmt.Errorf("trust suite requires --trust-config")
	}
	c, err := config.load(f)
	if err != nil {
		return err
	}
	if err = c.requireApp(platform); err != nil {
		return err
	}
	if o.run && o.suite == "runtime" {
		if err = c.requireTools("mosquitto"); err != nil {
			return err
		}
	}
	activeConfig = c
	o.java, o.flutter = c.Paths["java_home"], c.Tools["flutter"]
	if platform == "android" {
		androidApp(o)
	} else {
		iosApp(o)
	}
	return nil
}
func prepareApp(o appOptions, platform, work string) (string, string) {
	host := join(work, "host")
	cmd(root, nil, o.flutter, "create", "--no-pub", "--platforms="+platform, "--project-name", "mqtt_sdk_test", host)
	// The temporary test App uses the real Flutter integration plugin.
	integration := ""
	if o.suite != "smoke" {
		integration = "  integration_test:\n    sdk: flutter\n"
	}
	must(write(join(host, "pubspec.yaml"), fmt.Sprintf("name: mqtt_sdk_test\npublish_to: none\nversion: 1.0.0+1\nenvironment:\n  sdk: '>=3.3.0 <4.0.0'\ndependencies:\n  flutter:\n    sdk: flutter\n  paho_mqtt_ffi:\n    path: %q\n%sdev_dependencies:\n  flutter_test:\n    sdk: flutter\n", join(src, "flutter"), integration)))
	must(copyFile(join(src, "flutter/integration/release_app/main.dart"), join(host, "lib/main.dart")))
	target := "lib/main.dart"
	if o.suite == "wire" {
		prepareWire(host)
		target = "integration_test/mqtt_v2_test.dart"
	} else if o.suite != "smoke" {
		for _, name := range []string{"runtime_test.dart", "trust_test.dart", "connection_probe.dart"} {
			must(copyFile(join(src, "flutter/integration/ios", name), join(host, "integration_test", name)))
		}
		target = "integration_test/" + o.suite + "_test.dart"
		must(copyFile(join(src, "flutter/integration/ios/AppDelegate.swift"), join(host, "ios/Runner/AppDelegate.swift")))
	}
	cmd(host, nil, o.flutter, "pub", "get")
	return host, target
}
func prepareWire(host string) {
	s := read(join(src, "flutter/test/mqtt_v2_test.dart"))
	for _, marker := range []string{"import 'support/native_bootstrap.dart';\n", "  setUpAll(() => setUpMqttHostTests());\n"} {
		if strings.Count(s, marker) != 1 {
			panic("host bootstrap marker changed")
		}
		s = strings.ReplaceAll(s, marker, "")
	}
	s = strings.ReplaceAll(s, "import 'package:flutter_test/flutter_test.dart';", "import 'package:flutter_test/flutter_test.dart';\nimport 'package:integration_test/integration_test.dart';")
	s = strings.ReplaceAll(s, "TestWidgetsFlutterBinding.ensureInitialized();", "IntegrationTestWidgetsFlutterBinding.ensureInitialized();")
	s = strings.ReplaceAll(s, "  test(", "  testWidgets(")
	s = strings.ReplaceAll(s, "() async {", "(tester) async {")
	for _, n := range []string{"create", "accept", "close", "event<T>", "next<T extends v5.MqttConnectionEvent>"} {
		s = strings.ReplaceAll(s, n+"(tester) async", n+"() async")
	}
	must(write(join(host, "integration_test/mqtt_v2_test.dart"), s))
	must(write(join(host, "test_driver/driver.dart"), "import 'package:integration_test/integration_test_driver.dart';\nFuture<void> main() => integrationDriver();\n"))
}
func androidApp(o appOptions) {
	native := join(dist, "android/arm64-v8a")
	must(verify(native))
	nativeHash := get(hashFile(join(native, "build-info.json")))
	work := get(workspace("android-app"))
	host, target := prepareApp(o, "android", work)
	// Flutter can have a globally configured SDK; pin Gradle to this command's SDK.
	local := join(host, "android/local.properties")
	properties := regexp.MustCompile(`(?m)^sdk\.dir=.*\n?`).ReplaceAllString(read(local), "")
	sdk := strings.NewReplacer("\\", "\\\\", ":", "\\:", "=", "\\=").Replace(activeConfig.Paths["android_sdk"])
	must(write(local, properties+"\nsdk.dir="+sdk+"\n"))
	settings := join(host, "android/settings.gradle.kts")
	s := read(settings)
	re := regexp.MustCompile(`id\("com.android.application"\) version "([^"]+)" apply false`)
	m := re.FindStringSubmatch(s)
	if len(m) < 2 {
		panic("cannot detect AGP version")
	}
	s = strings.Replace(s, m[0], m[0]+"\n    id(\"com.android.library\") version \""+m[1]+"\" apply false", 1)
	must(write(settings, s))
	// Keep native release image byte-identical; symbols already live in dist.
	appGradle := join(host, "android/app/build.gradle.kts")
	s = read(appGradle)
	s = strings.Replace(s, "android {", "android {\n    packaging { jniLibs { keepDebugSymbols += \"**/libmqtt_sdk.so\" } }", 1)
	must(write(appGradle, s))
	env := map[string]string{}
	if o.java != "" {
		env["JAVA_HOME"] = o.java
		env["PATH"] = join(o.java, "bin") + string(os.PathListSeparator) + configEnvironment()["PATH"]
	}
	args := []string{join(host, "android/gradlew"), ":app:assembleDebug", "-Ptarget-platform=android-arm64", "-Ptarget=" + target, "-Ptrack-widget-creation=false", "--console=plain", "-Pdart-obfuscation=false", "-Ptree-shake-icons=false"}
	cmd(join(host, "android"), env, args...)
	apk := join(host, "build/app/outputs/apk/debug/app-debug.apk")
	verifyAPK(apk, join(native, "release/libmqtt_sdk.so"))
	if o.run {
		cmd(host, env, o.flutter, "drive", "--use-application-binary="+apk, "--target="+target, "--driver=test_driver/driver.dart", "-d", o.device)
	}
	assertNativeUnchanged(native, nativeHash)
	fmt.Println("Android test App verified; removing temporary App and build files")
	must(clean(work))
}
func verifyAPK(apk, library string) {
	r, e := zip.OpenReader(apk)
	must(e)
	defer r.Close()
	count := 0
	for _, f := range r.File {
		if strings.HasSuffix(f.Name, "libmqtt_sdk.so") {
			count++
			if f.Name != "lib/arm64-v8a/libmqtt_sdk.so" {
				panic("unexpected ABI in APK")
			}
			c, e := f.Open()
			must(e)
			b, e := io.ReadAll(c)
			c.Close()
			must(e)
			h := sha256.Sum256(b)
			if hex.EncodeToString(h[:]) != get(hashFile(library)) {
				panic("APK native library hash mismatch")
			}
		}
	}
	if count != 1 {
		panic("APK must contain exactly one MQTT library")
	}
}
func iosApp(o appOptions) {
	native := join(dist, "ios")
	must(verify(native))
	nativeHash := get(hashFile(join(native, "build-info.json")))
	work := get(workspace("ios-app"))
	host, target := prepareApp(o, "ios", work)
	config := read(join(host, "ios/Flutter/Generated.xcconfig"))
	m := regexp.MustCompile(`(?m)^FLUTTER_ROOT=(.+)$`).FindStringSubmatch(config)
	if len(m) < 2 {
		panic("FLUTTER_ROOT missing")
	}
	helper := strings.ReplaceAll(join(m[1], "packages/flutter_tools/bin/podhelper"), "'", "\\'")
	must(write(join(host, "ios/Podfile"), fmt.Sprintf(`platform :ios, '15.0'
ENV['COCOAPODS_DISABLE_STATS'] = 'true'
project 'Runner', { 'Debug' => :debug, 'Profile' => :release, 'Release' => :release }
require '%s'
flutter_ios_podfile_setup
target 'Runner' do
  use_frameworks! :linkage => :static
  flutter_install_all_ios_pods File.dirname(File.realpath(__FILE__))
end
post_install do |installer|
  installer.pods_project.targets.each do |target|
    flutter_additional_ios_build_settings(target)
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
      config.build_settings['DEBUG_INFORMATION_FORMAT'] = 'dwarf-with-dsym'
    end
  end
end
`, helper)))
	project := join(host, "ios/Runner.xcodeproj/project.pbxproj")
	s := read(project)
	s = regexp.MustCompile(`IPHONEOS_DEPLOYMENT_TARGET = [0-9.]+;`).ReplaceAllString(s, "IPHONEOS_DEPLOYMENT_TARGET = 15.0;")
	s = strings.ReplaceAll(s, "DEBUG_INFORMATION_FORMAT = dwarf;", "DEBUG_INFORMATION_FORMAT = \"dwarf-with-dsym\";")
	s = strings.ReplaceAll(s, "buildSettings = {", "buildSettings = {\n\t\t\t\tARCHS = arm64;\n\t\t\t\t\"EXCLUDED_ARCHS[sdk=iphonesimulator*]\" = \"i386 x86_64\";")
	must(write(project, s))
	cmd(join(host, "ios"), nil, "pod", "install")
	symbols := join(work, "symbols")
	must(mkdir(symbols))
	args := []string{o.flutter, "build", "ios", "--debug", "--simulator", "--no-codesign", "-t", target}
	defines := []string{}
	if o.trust != "" {
		defines = append(defines, "--dart-define-from-file="+get(filepath.Abs(o.trust)))
	}
	// Runtime fixture needs a live broker while running, but build-only also gets
	// deterministic defines so no external server is required to build the app.
	var broker *brokerProcess
	if o.suite == "runtime" {
		uri := "tcp://127.0.0.1:1883"
		if o.run {
			broker = startBroker(join(work, "broker"), false, false)
			defer broker.stop()
			uri = broker.uri
		}
		defines = append(defines, "--dart-define=MQTT_TEST_BROKER="+uri)
	}
	cmd(host, nil, append(args, defines...)...)
	if o.run {
		cmd(host, nil, append([]string{o.flutter, "test", target, "-d", o.device}, defines...)...)
	}
	app := join(host, "build/ios/iphonesimulator/Runner.app")
	// Find every linked Mach-O image in our App. UUID-check dSYMs before cleanup.
	images := []string{join(app, "Runner"), join(app, "Runner.debug.dylib")}
	for _, img := range images {
		if !exists(img) {
			continue
		}
		name := filepath.Base(img)
		dsym := join(symbols, name+".dSYM")
		cmd(root, nil, "xcrun", "dsymutil", img, "-o", dsym)
		assertUUID(img, dsym)
	}
	nativeDSYM := join(symbols, "Runner.dSYM")
	if exists(join(symbols, "Runner.debug.dylib.dSYM")) {
		nativeDSYM = join(symbols, "Runner.debug.dylib.dSYM")
	}
	for _, name := range []string{"mqtt_get_api", "MQTTAsync_createWithOptions", "SSL_CTX_new"} {
		data := capture(root, "xcrun", "dwarfdump", "--name="+name, nativeDSYM)
		if !strings.Contains(data, "DW_AT_low_pc") {
			panic("missing linked native DWARF: " + name)
		}
	}
	assertNativeUnchanged(native, nativeHash)
	fmt.Println("iOS test App and linked native DWARF verified; removing temporary App and symbols")
	must(clean(work))
}
func assertUUID(image, dsym string) {
	re := regexp.MustCompile(`UUID: ([0-9A-Fa-f-]+)`)
	a := re.FindAllStringSubmatch(capture(root, "xcrun", "dwarfdump", "--uuid", image), -1)
	b := re.FindAllStringSubmatch(capture(root, "xcrun", "dwarfdump", "--uuid", dsym), -1)
	if len(a) == 0 || len(a) != len(b) {
		panic("missing dSYM UUID")
	}
	for i := range a {
		if a[i][1] != b[i][1] {
			panic("App dSYM UUID mismatch")
		}
	}
}

func assertNativeUnchanged(native, before string) {
	must(verify(native))
	if get(hashFile(join(native, "build-info.json"))) != before {
		panic("native artifact changed while building the App; rerun the App build")
	}
}
