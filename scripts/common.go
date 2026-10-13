package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

var join = filepath.Join

func exists(p string) bool { _, e := os.Stat(p); return e == nil }
func mkdir(p string) error { return os.MkdirAll(p, 0755) }
func write(p, s string) error {
	if e := mkdir(filepath.Dir(p)); e != nil {
		return e
	}
	return os.WriteFile(p, []byte(s), 0644)
}
func read(p string) string {
	b, e := os.ReadFile(p)
	if e != nil {
		panic(e)
	}
	return string(b)
}
func envMerge(values map[string]string) []string {
	m := map[string]string{}
	for _, s := range os.Environ() {
		k, v, _ := strings.Cut(s, "=")
		m[k] = v
	}
	for k, v := range configEnvironment() {
		m[k] = v
	}
	for k, v := range values {
		m[k] = v
	}
	r := []string{}
	for k, v := range m {
		r = append(r, k+"="+v)
	}
	return r
}
func run(dir string, env map[string]string, args ...string) error {
	fmt.Println("+", strings.Join(args, " "))
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Minute)
	defer cancel()
	c := exec.CommandContext(ctx, tool(args[0]), args[1:]...)
	c.Dir = dir
	c.Env = envMerge(env)
	c.Stdout = os.Stdout
	c.Stderr = os.Stderr
	if e := c.Run(); e != nil {
		return fmt.Errorf("%s: %w", args[0], e)
	}
	return nil
}
func output(dir string, args ...string) (string, error) {
	c := exec.Command(tool(args[0]), args[1:]...)
	c.Dir = dir
	c.Env = envMerge(nil)
	b, e := c.CombinedOutput()
	if e != nil {
		return "", fmt.Errorf("%s: %w\n%s", args[0], e, b)
	}
	return strings.TrimSpace(string(b)), nil
}
func hashFile(p string) (string, error) {
	b, e := os.ReadFile(p)
	if e != nil {
		return "", e
	}
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:]), nil
}
func copyFile(a, b string) error {
	s, e := os.Stat(a)
	if e != nil {
		return e
	}
	v, e := os.ReadFile(a)
	if e != nil {
		return e
	}
	if e = mkdir(filepath.Dir(b)); e != nil {
		return e
	}
	return os.WriteFile(b, v, s.Mode().Perm())
}
func copyTree(a, b string) error {
	return filepath.WalkDir(a, func(p string, d fs.DirEntry, e error) error {
		if e != nil {
			return e
		}
		r, e := filepath.Rel(a, p)
		if e != nil {
			return e
		}
		to := join(b, r)
		if d.Type()&os.ModeSymlink != 0 {
			v, e := os.Readlink(p)
			if e != nil {
				return e
			}
			if e = mkdir(filepath.Dir(to)); e != nil {
				return e
			}
			return os.Symlink(v, to)
		}
		if d.IsDir() {
			return mkdir(to)
		}
		return copyFile(p, to)
	})
}
func clean(p string) error {
	p = filepath.Clean(p)
	base, e := filepath.EvalSymlinks(build)
	if e != nil {
		return e
	}
	actual, e := filepath.EvalSymlinks(p)
	if os.IsNotExist(e) {
		return nil
	}
	if e != nil {
		return e
	}
	rel, e := filepath.Rel(base, actual)
	if e != nil || rel == "." || rel == ".." || strings.HasPrefix(rel, ".."+string(os.PathSeparator)) {
		return fmt.Errorf("refuse cleanup outside build subdirectory: %s", p)
	}
	info, e := os.Lstat(p)
	if e != nil {
		return e
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("refuse symlink cleanup: %s", p)
	}
	if e = os.RemoveAll(p); e != nil {
		return e
	}
	fmt.Println("Cleaned:", p)
	return nil
}
func workspace(name string) (string, error) {
	if e := mkdir(build); e != nil {
		return "", e
	}
	return os.MkdirTemp(build, name+"-")
}
func fileHashes(dir string) (map[string]string, error) {
	m := map[string]string{}
	e := filepath.WalkDir(dir, func(p string, d fs.DirEntry, e error) error {
		if e != nil {
			return e
		}
		if d.IsDir() || d.Type()&os.ModeSymlink != 0 {
			return nil
		}
		r, _ := filepath.Rel(dir, p)
		h, e := hashFile(p)
		if e != nil {
			return e
		}
		m[filepath.ToSlash(r)] = h
		return nil
	})
	return m, e
}
func manifest(dir string, meta map[string]any) error {
	h, e := fileHashes(dir)
	if e != nil {
		return e
	}
	meta["files"] = h
	meta["built_at"] = time.Now().UTC().Format(time.RFC3339)
	data, e := json.MarshalIndent(meta, "", "  ")
	if e != nil {
		return e
	}
	return write(join(dir, "build-info.json"), string(data)+"\n")
}
func verify(dir string) error {
	b, e := os.ReadFile(join(dir, "build-info.json"))
	if e != nil {
		return fmt.Errorf("build required for %s: %w", dir, e)
	}
	var m struct {
		Files map[string]string `json:"files"`
	}
	if e = json.Unmarshal(b, &m); e != nil {
		return e
	}
	if len(m.Files) == 0 {
		return fmt.Errorf("legacy artifact manifest: rebuild %s", dir)
	}
	for f, want := range m.Files {
		got, e := hashFile(join(dir, f))
		if e != nil {
			return e
		}
		if want != got {
			return fmt.Errorf("checksum mismatch: %s", f)
		}
	}
	return nil
}
func publish(from, to string) error {
	return publishDirectory(from, to, verify)
}
func publishDirectory(from, to string, validate func(string) error) error {
	if e := validate(from); e != nil {
		return e
	}
	if e := mkdir(filepath.Dir(to)); e != nil {
		return e
	}
	tmp, e := os.MkdirTemp(filepath.Dir(to), ".publish-")
	if e != nil {
		return e
	}
	defer os.RemoveAll(tmp)
	staged := join(tmp, "new")
	if e = copyTree(from, staged); e != nil {
		return e
	}
	if e = validate(staged); e != nil {
		return e
	}
	old := join(tmp, "old")
	had := exists(to)
	if had {
		if e = os.Rename(to, old); e != nil {
			return e
		}
	}
	if e = os.Rename(staged, to); e != nil {
		if had {
			_ = os.Rename(old, to)
		}
		return e
	}
	fmt.Println("Published:", to)
	return nil
}
func sourceHash() (string, error) {
	files := []string{}
	for _, dir := range []string{join(src, "native"), join(src, "patches"), join(root, "scripts")} {
		e := filepath.WalkDir(dir, func(p string, d fs.DirEntry, e error) error {
			if e != nil {
				return e
			}
			if !d.IsDir() {
				if dir == join(root, "scripts") && filepath.Ext(p) != ".go" && d.Name() != "go.mod" && d.Name() != "go.sum" {
					return nil
				}
				files = append(files, p)
			}
			return nil
		})
		if e != nil {
			return "", e
		}
	}
	sort.Strings(files)
	h := sha256.New()
	for _, p := range files {
		b, e := os.ReadFile(p)
		if e != nil {
			return "", e
		}
		r, _ := filepath.Rel(root, p)
		fmt.Fprintf(h, "%s\x00%s\x00", r, b)
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}
func must(e error) {
	if e != nil {
		panic(e)
	}
}
func get(s string, e error) string                          { must(e); return s }
func cmd(dir string, env map[string]string, args ...string) { must(run(dir, env, args...)) }
func capture(dir string, args ...string) string             { return get(output(dir, args...)) }
