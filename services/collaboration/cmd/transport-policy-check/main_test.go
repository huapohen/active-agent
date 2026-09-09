package main

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestPrivateConfigIsDataAndRejectsAmbiguity(t *testing.T) {
	path := filepath.Join(t.TempDir(), "provider.env")
	body := "RONGCLOUD_API_URL=https://example.invalid\nRONGCLOUD_APP_KEY='literal-key'\nRONGCLOUD_APP_SECRET='$(never-execute)'\n"
	require.NoError(t, os.WriteFile(path, []byte(body), 0600))
	v, err := readConfig(path)
	require.NoError(t, err)
	require.Equal(t, "$(never-execute)", v["RONGCLOUD_APP_SECRET"])
	require.NoError(t, os.WriteFile(path, []byte(body+"RONGCLOUD_APP_KEY=other\n"), 0600))
	_, err = readConfig(path)
	require.Error(t, err)
	require.NoError(t, os.WriteFile(path, []byte(body), 0600))
	require.NoError(t, os.Chmod(path, 0644))
	_, err = readConfig(path)
	require.Error(t, err)
}
