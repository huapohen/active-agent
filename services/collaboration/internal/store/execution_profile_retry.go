package store

import (
	"context"
	"errors"
	"time"

	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/huapohen/active-agent/services/collaboration/internal/harness"
	"github.com/jackc/pgx/v5/pgconn"
)

// Global profile writes can contend with a group dispatch holding room locks
// while admitting another member. A short lock timeout releases this entire
// uncommitted transaction; only PostgreSQL-confirmed rollback errors retry.
// No provider request or other external effect occurs in a profile transaction.
// Ambiguous commit/network errors never enter this retry loop.
func (s *Store) executeProfileAction(ctx context.Context, issuer, subject string, rc harness.RunContext, a harness.Action) (harness.Receipt, error) {
	for attempt := 0; attempt < 8; attempt++ {
		out, err := s.executeAction(ctx, issuer, subject, rc, a)
		var pgError *pgconn.PgError
		if !errors.As(err, &pgError) || (pgError.Code != "55P03" && pgError.Code != "40P01" && pgError.Code != "40001") {
			return out, err
		}
		if attempt == 7 {
			break
		}
		timer := time.NewTimer(time.Duration(20+attempt*10) * time.Millisecond)
		select {
		case <-ctx.Done():
			timer.Stop()
			return harness.Receipt{}, ctx.Err()
		case <-timer.C:
		}
	}
	return harness.Receipt{}, domain.ErrProfileBusy
}
