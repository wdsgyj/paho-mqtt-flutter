package main

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

func overlay(source, dest string) error {
	a, e := filepath.EvalSymlinks(source)
	if e != nil {
		return e
	}
	a, e = filepath.Abs(a)
	if e != nil {
		return e
	}
	b, e := filepath.Abs(dest)
	if e != nil {
		return e
	}
	if resolved, err := filepath.EvalSymlinks(b); err == nil {
		b = resolved
	}
	if a == b || strings.HasPrefix(b, a+"/") {
		return fmt.Errorf("overlay must be outside source checkout")
	}
	// Copy only compiler inputs; upstream docs, samples and build trees are unnecessary.
	e = filepath.WalkDir(a, func(p string, d fs.DirEntry, e error) error {
		if e != nil {
			return e
		}
		rel, _ := filepath.Rel(a, p)
		if rel == "." {
			return mkdir(b)
		}
		if d.IsDir() {
			if d.Name() == ".git" || d.Name() == ".idea" || strings.HasPrefix(d.Name(), "build") || strings.HasPrefix(d.Name(), "_build") || d.Name() == "docs" {
				return filepath.SkipDir
			}
			return mkdir(join(b, rel))
		}
		return copyFile(p, join(b, rel))
	})
	if e != nil {
		return e
	}
	for _, edit := range pahoEdits {
		p := join(b, "src", edit.name)
		data, e := os.ReadFile(p)
		if e != nil {
			return e
		}
		if !strings.Contains(string(data), edit.old) {
			return fmt.Errorf("Paho baseline mismatch: %s", edit.name)
		}
		if e = write(p, strings.Replace(string(data), edit.old, edit.new, edit.count)); e != nil {
			return e
		}
	}
	fmt.Println("Prepared Paho overlay:", b)
	return nil
}
