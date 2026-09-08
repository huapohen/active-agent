package main

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestWorkerDisabledByDefault(t *testing.T) {
	t.Setenv("RENJI_HARNESS_ENABLED", "")
	t.Setenv("RENJI_GATEWAY_URL", "invalid")
	require.NoError(t, run())
}

func TestWorkerRejectsInvalidPrivateArchiveConfigBeforeModelOrTemporal(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `{"protocol":"renji-harness-v1","principal_id":"agent-a","executor_id":"worker-a","server_bound":true,"actions_idempotent":true,"scope_epochs_enforced":true}`)
	}))
	defer server.Close()
	t.Setenv("RENJI_HARNESS_ENABLED", "true")
	t.Setenv("RENJI_GATEWAY_URL", server.URL)
	t.Setenv("RENJI_EXECUTOR_TOKEN", "test-machine")
	t.Setenv("RENJI_AGENT_PRINCIPAL_ID", "agent-a")
	t.Setenv("RENJI_EXECUTOR_ID", "worker-a")
	t.Setenv("RENJI_RUN_ARCHIVE_CONFIG", filepath.Join(t.TempDir(), "missing.json"))
	t.Setenv("RENJI_MODEL_BASE_URL", "invalid")
	t.Setenv("RENJI_TEMPORAL_ADDRESS", "invalid")
	require.EqualError(t, run(), "invalid terminal archive deployment configuration")
}

func TestWorkerRejectsAbsentServerMachineBindingBeforeDialingTemporal(t *testing.T) {
	server := httptest.NewServer(http.NotFoundHandler())
	defer server.Close()
	t.Setenv("RENJI_HARNESS_ENABLED", "true")
	t.Setenv("RENJI_GATEWAY_URL", server.URL)
	t.Setenv("RENJI_EXECUTOR_TOKEN", "test-machine")
	t.Setenv("RENJI_AGENT_PRINCIPAL_ID", "agent-a")
	t.Setenv("RENJI_EXECUTOR_ID", "worker-a")
	t.Setenv("RENJI_TEMPORAL_ADDRESS", "invalid")
	require.EqualError(t, run(), "machine binding or required gateway contracts are not ready")
}
