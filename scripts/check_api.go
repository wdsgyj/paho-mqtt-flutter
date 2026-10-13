package main

import (
	"flag"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
)

func checkAPI(args []string) error {
	f := flag.NewFlagSet("check-api", flag.ContinueOnError)
	config := addConfigFlags(f)
	if err := f.Parse(args); err != nil {
		return err
	}
	c, err := config.load(f)
	if err != nil {
		return err
	}
	if err = c.requireTools("dart"); err != nil {
		return err
	}
	activeConfig = c
	p, e := os.CreateTemp(join(src, "flutter/test"), "api_visibility_*.dart")
	if e != nil {
		return e
	}
	defer os.Remove(p.Name())
	source := append(append([]string{}, apiPrelude...), apiExpressions...)
	source = append(source, "}")
	_, e = p.WriteString(strings.Join(source, "\n"))
	p.Close()
	if e != nil {
		return e
	}
	command := exec.Command(tool("dart"), "analyze", "--format=machine", p.Name())
	command.Dir = join(src, "flutter")
	command.Env = envMerge(nil)
	b, err := command.CombinedOutput()
	if err == nil {
		return fmt.Errorf("internal API unexpectedly accessible")
	}
	found := map[int]bool{}
	allowed := map[string]bool{}
	for _, code := range []string{"UNDEFINED_FUNCTION", "UNDEFINED_IDENTIFIER", "UNDEFINED_METHOD", "UNDEFINED_PREFIXED_NAME", "UNDEFINED_GETTER", "UNDEFINED_CONSTRUCTOR_DEFAULT", "NEW_WITH_UNDEFINED_CONSTRUCTOR_DEFAULT"} {
		allowed[code] = true
	}
	for _, line := range strings.Split(string(b), "\n") {
		parts := strings.Split(line, "|")
		if len(parts) >= 8 && parts[0] == "ERROR" {
			n, e := strconv.Atoi(parts[4])
			if e != nil || !allowed[parts[2]] || n <= len(apiPrelude) || n > len(apiPrelude)+len(apiExpressions) {
				return fmt.Errorf("unexpected diagnostic: %s", line)
			}
			found[n] = true
		}
	}
	if len(found) != len(apiExpressions) {
		return fmt.Errorf("unexpected API visibility results:\n%s", b)
	}
	fmt.Printf("Public API visibility: %d internal accesses rejected\n", len(found))
	return nil
}
