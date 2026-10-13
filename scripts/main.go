// Command sdk builds native libraries, test applications and regression fixtures.
package main

import (
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
)

var root, src, build, dist string

func main() {
	defer func() {
		if e := recover(); e != nil {
			fmt.Fprintln(os.Stderr, "ERROR:", e)
			os.Exit(1)
		}
	}()
	_, file, _, _ := runtime.Caller(0)
	root = filepath.Dir(filepath.Dir(file))
	src = join(root, "src")
	build = join(root, "build")
	dist = join(root, "dist")
	if err := dispatch(os.Args[1:]); err != nil && !errors.Is(err, flag.ErrHelp) {
		fmt.Fprintln(os.Stderr, "ERROR:", err)
		os.Exit(1)
	}
}
func dispatch(args []string) error {
	if len(args) == 0 {
		usage()
		return nil
	}
	switch args[0] {
	case "download":
		return downloadCommand(args[1:])
	case "doctor":
		return doctorCommand(args[1:])
	case "native":
		return nativeCommand(args[1:])
	case "android-app":
		return appCommand("android", args[1:])
	case "ios-app":
		return appCommand("ios", args[1:])
	case "test":
		return testCommand(args[1:])
	case "overlay":
		if len(args) != 3 {
			return fmt.Errorf("overlay SOURCE DESTINATION")
		}
		return overlay(args[1], args[2])
	case "check-api":
		return checkAPI(args[1:])
	case "help", "-h", "--help":
		usage()
		return nil
	default:
		return fmt.Errorf("unknown command %q", args[0])
	}
}
func usage() {
	fmt.Println(`Run from the repository root:
  go -C scripts run . download     [--dependency all|paho|openssl] [--paho-tag TAG] [--openssl-tag TAG]
  go -C scripts run . doctor       [--target all|native|android-app|ios-app|test|check-api]
  go -C scripts run . native       --platform all|android|ios|host
  go -C scripts run . android-app  [--run --device emulator-5554]
  go -C scripts run . ios-app      [--run --device UUID]
  go -C scripts run . test         --suite runtime|errors|reconnect|subscribe|trust|all
  go -C scripts run . check-api
  go -C scripts test ./...
Each command accepts --help. All C/Paho/OpenSSL code uses -Os -g -DNDEBUG,
including temporary test apps (Flutter Debug). Mobile test apps are built on demand
under build/ and removed after successful verification; no App is saved to dist/.
Native libraries publish under dist/: iOS is unstripped; Android has stripped and
full DWARF images from the same build. dist/test keeps only the host dylib.
C test executables are built on demand and cleaned after successful tests.`)
}
