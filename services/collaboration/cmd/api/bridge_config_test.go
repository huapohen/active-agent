package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestPrivateBridgeBindings(t *testing.T) {
	path := filepath.Join(t.TempDir(), "private.json")
	raw := `[{"id":"fixture-bridge","receiver_id":"11111111-1111-4111-8111-111111111111","room_id":"22222222-2222-4222-8222-222222222222","secret":"` + strings.Repeat("synthetic", 5) + `"}]`
	require.NoError(t, os.WriteFile(path, []byte(raw), 0600))
	bindings, err := loadBridgeBindings(path)
	require.NoError(t, err)
	require.Len(t, bindings, 1)
	require.NoError(t, os.Chmod(path, 0644))
	_, err = loadBridgeBindings(path)
	require.Error(t, err)
	require.NoError(t, os.Chmod(path, 0600))
	link := filepath.Join(t.TempDir(), "link.json")
	require.NoError(t, os.Symlink(path, link))
	_, err = loadBridgeBindings(link)
	require.Error(t, err)
	for _, invalid := range []string{raw + "{}", strings.Replace(raw, `"id":`, `"extra":1,"id":`, 1), "null", "[" + raw[1:len(raw)-1] + "," + raw[1:len(raw)-1] + "]"} {
		require.NoError(t, os.WriteFile(path, []byte(invalid), 0600))
		_, err = loadBridgeBindings(path)
		require.Error(t, err)
	}
}
