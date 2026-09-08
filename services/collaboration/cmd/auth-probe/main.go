// auth-probe verifies a configured, finite-lived Clerk machine credential.
// It prints only identity metadata; neither token nor machine secret is logged.
package main

import (
	"context"
	"encoding/json"
	"github.com/huapohen/active-agent/services/collaboration/internal/auth"
	"os"
	"time"
)

func main() {
	v, err := auth.NewClerkMachine(auth.ClerkMachineConfig{Issuer: os.Getenv("CLERK_ISSUER"), ReceiverMachineID: os.Getenv("CLERK_RECEIVER_MACHINE_ID"), MachineSecretKey: os.Getenv("CLERK_MACHINE_SECRET_KEY")})
	out := map[string]any{"verified": false, "checked_at": time.Now().UTC().Format(time.RFC3339)}
	if err == nil {
		ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
		defer cancel()
		var identity auth.MachineIdentity
		identity, err = v.VerifyMachine(ctx, os.Getenv("RENJI_GATEWAY_TOKEN"))
		if err == nil {
			out["verified"] = true
			out["issuer"] = identity.Issuer
			out["machine_subject"] = identity.MachineSubject
			out["receiver"] = identity.Audience
			out["expires_at"] = identity.ExpiresAt
		}
	}
	_ = json.NewEncoder(os.Stdout).Encode(out)
	if err != nil {
		os.Exit(1)
	}
}
