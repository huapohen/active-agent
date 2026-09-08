package store

import (
	"context"

	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/jackc/pgx/v5"
)

// Transport reuses persisted execution authority, never an epoch supplied in
// message content. It takes source locks before the ordinary target-room lock,
// in the same sorted order as ExecuteAction. Completed runs may finish already
// committed deliveries; stopped, revoked or reconfigured runs may not.
func executionDeliveryAdmission(ctx context.Context, tx pgx.Tx, claim deliveryClaim) error {
	if claim.ExecutionRunID == "" {
		return nil
	}
	run, err := loadExecutionRun(ctx, tx, claim.ExecutionRunID)
	if err != nil {
		return err
	}
	if run.Context.PrincipalID != claim.Actor || run.Context.RoomID != claim.Room {
		return domain.ErrForbidden
	}
	b, err := executorByID(ctx, tx, run.Context.ExecutorID, false)
	if err != nil {
		return err
	}
	if executionPolicyStale(b, run) || (run.Status != "running" && run.Status != "completed") {
		return domain.ErrStopped
	}
	scopes, err := executionScopes(run.Context)
	if err != nil {
		return err
	}
	for _, scope := range scopes {
		_, epoch, stopped, e := deliveryMember(ctx, tx, scope.RoomID, claim.Actor)
		if e != nil {
			return e
		}
		if stopped || epoch != scope.Epoch {
			return domain.ErrStopped
		}
	}
	return nil
}
