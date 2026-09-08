package runarchive

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"
)

func testConfig() Config {
	return Config{Schema: "renji.run-archive.v1", Mode: "single_source_synthetic", DatabaseURLEnv: "RENJI_DATABASE_URL", Clerk: ClerkConfig{Issuer: testIssuer, ReceiverMachineID: "mch_receiver", MachineSecretEnv: "MACHINE_SECRET", TokenEnv: "MACHINE_TOKEN"}, Targets: []TargetConfig{{BindingID: "synthetic-v1", ApprovedBy: "operator", ApprovalReference: "isolated-test", WorkspaceID: "28a73b9b-a3cf-48f9-b717-c840843fd8df", SourceRoomID: "5bfb0cdf-5715-4b32-b55f-d865153717eb", DocFreeEndpoint: "http://127.0.0.1:3218", DocFreeRoomID: "room-synthetic", DocFreePrincipalID: "principal-agent", DocFreeTokenEnv: "DOC_FREE_TOKEN", PrincipalMappings: []PrincipalMapping{{GoPrincipalID: "19f95251-c43e-42d4-9a89-ae7e96059d84", DocFreePrincipalID: "principal-agent"}}}}}
}
func TestArchiveConfigRejectsUnknownFieldsAndUnsafeFiles(t *testing.T) {
	c := testConfig()
	raw, e := json.Marshal(c)
	require.NoError(t, e)
	dir := t.TempDir()
	p := filepath.Join(dir, "config.json")
	require.NoError(t, os.WriteFile(p, raw, 0600))
	actual, e := LoadConfig(p)
	require.NoError(t, e)
	require.Equal(t, c, actual)
	require.NoError(t, os.Chmod(p, 0644))
	_, e = LoadConfig(p)
	require.Error(t, e)
	require.NoError(t, os.Chmod(p, 0600))
	link := filepath.Join(dir, "link.json")
	require.NoError(t, os.Symlink(p, link))
	_, e = LoadConfig(link)
	require.Error(t, e)
	for _, v := range []string{string(raw[:len(raw)-1]) + `,"fake_machine":true}`, string(raw) + `{}`, string(raw[:len(raw)-1]) + `,"token":"must_not_be_inline"}`} {
		require.NoError(t, os.WriteFile(p, []byte(v), 0600))
		_, e = LoadConfig(p)
		require.Error(t, e)
	}
}
func TestArchiveConfigRejectsProductionAndUnboundDestinations(t *testing.T) {
	for _, mode := range []string{"production", "multi_source", ""} {
		c := testConfig()
		c.Mode = mode
		require.Error(t, c.Validate())
	}
	for _, endpoint := range []string{"http://example.com", "https://user:pass@example.com", "https://example.com/path", "https://example.com?token=secret", "file:///tmp/doc", "https://example.com#other"} {
		c := testConfig()
		c.Targets[0].DocFreeEndpoint = endpoint
		require.Error(t, c.Validate())
	}
	for _, endpoint := range []string{"http://127.0.0.1:3218", "http://[::1]:3218", "https://docs.example.test"} {
		c := testConfig()
		c.Targets[0].DocFreeEndpoint = endpoint
		require.NoError(t, c.Validate())
	}
	c := testConfig()
	c.Targets[0].PrincipalMappings = append(c.Targets[0].PrincipalMappings, c.Targets[0].PrincipalMappings[0])
	require.Error(t, c.Validate())
	c = testConfig()
	c.Targets[0].PrincipalMappings[0].DocFreePrincipalID = "different-principal"
	require.Error(t, c.Validate())
	c = testConfig()
	c.Targets[0].DocFreeRoomID = "../rooms"
	require.Error(t, c.Validate())
	c = testConfig()
	c.Clerk.TokenEnv = "TOKEN=value"
	require.Error(t, c.Validate())
}
func TestArchiveBindingFingerprintSortsMappingsButPreservesDestination(t *testing.T) {
	c := testConfig()
	a := c.Targets[0]
	a.PrincipalMappings = append(a.PrincipalMappings, PrincipalMapping{GoPrincipalID: "7f290bf4-dbae-4692-b94b-9698660fba99", DocFreePrincipalID: "principal-human"})
	b := a
	b.PrincipalMappings = []PrincipalMapping{a.PrincipalMappings[1], a.PrincipalMappings[0]}
	b.DocFreeEndpoint += "/"
	require.Equal(t, a.fingerprint(), b.fingerprint())
	b.DocFreeRoomID = "new-room"
	require.NotEqual(t, a.fingerprint(), b.fingerprint())
}
