package main

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/huapohen/active-agent/services/collaboration/internal/runarchive"
	"github.com/stretchr/testify/require"
)

func TestRunArchiveCommandDisabledBeforeCredentialsOrDatabase(t *testing.T) {
	p := filepath.Join(t.TempDir(), "archive.json")
	raw := `{"schema":"renji.run-archive.v1","enabled":false,"mode":"single_source_synthetic","database_url_env":"DATABASE_URL","clerk":{"issuer":"https://test.clerk.accounts.dev","receiver_machine_id":"mch_receiver","machine_secret_env":"SECRET","token_env":"TOKEN"},"targets":[{"binding_id":"synthetic","approved_by":"test","approval_reference":"fixture","workspace_id":"487f6cc1-323f-4261-bf4a-53fb364d1a20","source_room_id":"487f6cc1-323f-4261-bf4a-53fb364d1a21","doc_free_endpoint":"http://127.0.0.1:3218","doc_free_room_id":"room-synthetic","doc_free_principal_id":"principal-agent","doc_free_token_env":"DOC_FREE_TOKEN","principal_mappings":[{"go_principal_id":"487f6cc1-323f-4261-bf4a-53fb364d1a22","doc_free_principal_id":"principal-agent"}]}]}`
	require.NoError(t, os.WriteFile(p, []byte(raw), 0600))
	_, e := run(context.Background(), []string{"--config", p, "--run", "487f6cc1-323f-4261-bf4a-53fb364d1a23"}, func(string) string { t.Fatal("disabled command read credentials"); return "" })
	require.Equal(t, "run_archive_disabled", runarchive.Code(e))
}
func TestRunArchiveCommandNoInlineCredentialOrTargetOverride(t *testing.T) {
	for _, args := range [][]string{nil, {"--config", "unused", "--run", "id", "--endpoint", "http://elsewhere"}, {"--config", "unused", "--run", "id", "--fake-machine"}, {"--config", "unused", "--run", "id", "--token", "test"}} {
		_, e := run(context.Background(), args, func(string) string { t.Fatal("invalid arguments accessed environment"); return "" })
		require.Equal(t, "archive_arguments_required", runarchive.Code(e))
	}
}
