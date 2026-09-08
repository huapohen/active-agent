package main

import (
	"context"
	"encoding/json"
	"flag"
	"github.com/huapohen/active-agent/services/collaboration/internal/auth"
	"github.com/huapohen/active-agent/services/collaboration/internal/runarchive"
	"github.com/huapohen/active-agent/services/collaboration/internal/store"
	"os"
	"os/signal"
	"syscall"
)

func run(ctx context.Context, args []string, getenv func(string) string) (any, error) {
	flags := flag.NewFlagSet("run-archive", flag.ContinueOnError)
	flags.SetOutput(os.Stderr)
	var configPath, runID string
	flags.StringVar(&configPath, "config", "", "Private server-owned configuration file")
	flags.StringVar(&runID, "run", "", "Authorized persistent Run ID")
	if flags.Parse(args) != nil || flags.NArg() != 0 || configPath == "" || runID == "" {
		return nil, runarchive.Failure("archive_arguments_required")
	}
	c, err := runarchive.LoadConfig(configPath)
	if err != nil {
		return nil, err
	}
	if !c.Enabled {
		return nil, runarchive.Failure("run_archive_disabled")
	}
	v, err := auth.NewClerkMachine(auth.ClerkMachineConfig{Issuer: c.Clerk.Issuer, ReceiverMachineID: c.Clerk.ReceiverMachineID, MachineSecretKey: getenv(c.Clerk.MachineSecretEnv)})
	if err != nil {
		return nil, runarchive.Failure("invalid_clerk_configuration")
	}
	dsn := getenv(c.DatabaseURLEnv)
	if dsn == "" {
		return nil, runarchive.Failure("database_configuration_missing")
	}
	s, err := store.Open(ctx, dsn)
	if err != nil {
		return nil, runarchive.Failure("archive_database_unavailable")
	}
	defer s.Close()
	// Migrations are a separate deployment step; this command never mutates schema.
	runner, err := runarchive.New(c, s, v, getenv)
	if err != nil {
		return nil, err
	}
	return runner.Run(ctx, runID)
}
func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	result, err := run(ctx, os.Args[1:], os.Getenv)
	if err != nil {
		json.NewEncoder(os.Stdout).Encode(map[string]any{"status": "requires_attention", "error_code": runarchive.Code(err), "result": result})
		os.Exit(1)
	}
	json.NewEncoder(os.Stdout).Encode(result)
}
