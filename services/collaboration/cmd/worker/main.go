package main

import (
	"context"
	"crypto/tls"
	"fmt"
	"net"
	"os"
	"strings"
	"time"

	"github.com/huapohen/active-agent/services/collaboration/internal/harness"
	"github.com/huapohen/active-agent/services/collaboration/internal/runarchive"
	"go.temporal.io/sdk/client"
	"go.temporal.io/sdk/worker"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "Worker refused startup or stopped with an error:", err)
		os.Exit(1)
	}
}

func run() error {
	if os.Getenv("RENJI_HARNESS_ENABLED") != "true" {
		fmt.Println("Harness worker disabled. Set RENJI_HARNESS_ENABLED=true after machine binding and gateway readiness are configured.")
		return nil
	}
	gw, err := harness.NewHTTPGateway(os.Getenv("RENJI_GATEWAY_URL"), os.Getenv("RENJI_EXECUTOR_TOKEN"), os.Getenv("RENJI_AGENT_PRINCIPAL_ID"), os.Getenv("RENJI_EXECUTOR_ID"))
	if err != nil {
		return fmt.Errorf("invalid machine gateway configuration")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	err = gw.VerifyBinding(ctx)
	cancel()
	if err != nil {
		return fmt.Errorf("machine binding or required gateway contracts are not ready")
	}
	archiveCtx, archiveCancel := context.WithTimeout(context.Background(), 15*time.Second)
	archiver, closeArchive, archiveMode, err := runarchive.OpenDeployment(archiveCtx, os.Getenv("RENJI_RUN_ARCHIVE_CONFIG"), os.Getenv)
	archiveCancel()
	if err != nil {
		return fmt.Errorf("invalid terminal archive deployment configuration")
	}
	defer closeArchive()
	model, err := harness.NewConfiguredHTTPModel(os.Getenv("RENJI_MODEL_BASE_URL"), os.Getenv("RENJI_MODEL_API_KEY"), os.Getenv("RENJI_MODEL_NAME"), os.Getenv("RENJI_MODEL_REASONING_EFFORT"), os.Getenv("RENJI_MODEL_API_STYLE"))
	if err != nil {
		return fmt.Errorf("invalid explicit model configuration")
	}
	planner, err := harness.NewEinoPlanner(harness.PlannerConfig{Model: model, Gateway: gw, AllowedActionTypes: gw.AllowedActionTypes()})
	if err != nil {
		return err
	}
	address := os.Getenv("RENJI_TEMPORAL_ADDRESS")
	if address == "" {
		address = "localhost:7233"
	}
	namespace := os.Getenv("RENJI_TEMPORAL_NAMESPACE")
	if namespace == "" {
		namespace = "default"
	}
	options := client.Options{HostPort: address, Namespace: namespace}
	host, _, err := net.SplitHostPort(address)
	if err != nil {
		return fmt.Errorf("invalid Temporal address")
	}
	loopback := host == "localhost"
	if ip := net.ParseIP(host); ip != nil {
		loopback = ip.IsLoopback()
	}
	if os.Getenv("RENJI_TEMPORAL_TLS") == "true" {
		options.ConnectionOptions.TLS = &tls.Config{MinVersion: tls.VersionTLS12, ServerName: host}
	} else if !loopback {
		return fmt.Errorf("Temporal TLS is required outside loopback")
	}
	c, err := client.Dial(options)
	if err != nil {
		return fmt.Errorf("Temporal connection failed")
	}
	defer c.Close()
	queue := os.Getenv("RENJI_TEMPORAL_TASK_QUEUE")
	if strings.TrimSpace(queue) == "" {
		queue = harness.TaskQueue
	}
	w := worker.New(c, queue, worker.Options{MaxConcurrentActivityExecutionSize: 4, MaxConcurrentWorkflowTaskExecutionSize: 4})
	harness.Register(w, &harness.Activities{Gateway: gw, Planner: planner, Archiver: archiver})
	fmt.Println("Terminal archive plugin:", archiveMode)
	fmt.Println("Harness worker started. Ctrl+C stops this executor; use the room stop API first to fence all source-derived actions.")
	return w.Run(worker.InterruptCh())
}
