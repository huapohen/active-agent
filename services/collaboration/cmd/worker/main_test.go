package main

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestWorkerDisabledByDefault(t *testing.T) {
	t.Setenv("RENJI_HARNESS_ENABLED", "")
	t.Setenv("RENJI_GATEWAY_URL", "invalid")
	require.NoError(t, run())
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
