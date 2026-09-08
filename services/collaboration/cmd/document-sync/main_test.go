package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestPrivateCredentialLoadingDoesNotAcceptPublicFilesOrSymlinks(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "token")
	os.WriteFile(path, []byte(`{"token":"sample-token"}`), 0600)
	token, err := credential(path, "doc_free")
	if err != nil || token != "sample-token" {
		t.Fatal("token loader", err)
	}
	os.Chmod(path, 0644)
	if _, err = credential(path, "doc_free"); err == nil {
		t.Fatal("public file accepted")
	}
	os.Chmod(path, 0600)
	alias := filepath.Join(dir, "alias")
	os.Symlink(path, alias)
	if _, err = credential(alias, "doc_free"); err == nil {
		t.Fatal("symlink accepted")
	}
}
func TestDocmostCookieFileLoadsOnlyAuthToken(t *testing.T) {
	path := filepath.Join(t.TempDir(), "cookies")
	os.WriteFile(path, []byte("# Netscape HTTP Cookie File\nlocalhost\tFALSE\t/\tFALSE\t0\tauthToken\texample\nlocalhost\tFALSE\t/\tFALSE\t0\tother\tnot-selected\n"), 0600)
	value, err := credential(path, "docmost")
	if err != nil || value != "example" {
		t.Fatal(err)
	}
}
func TestConfigRejectsUnknownAndTrailingJSON(t *testing.T) {
	for _, value := range []string{`{"journal":"/tmp/j","bindings":[],"unknown":true}`, `{"journal":"/tmp/j","bindings":[]} {"b":2}`} {
		path := filepath.Join(t.TempDir(), "c")
		os.WriteFile(path, []byte(value), 0600)
		if _, err := readConfig(path); err == nil {
			t.Fatal("invalid config accepted")
		}
	}
}
