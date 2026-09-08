package store

import (
	"context"
	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/jackc/pgx/v5"
	"sort"
	"time"
)

func lockArchiveAudience(ctx context.Context, tx pgx.Tx, run ExecutionRun, audience []string) error {
	if len(audience) > 100 {
		return domain.ErrInvalid
	}
	ids := append([]string(nil), audience...)
	sort.Strings(ids)
	previous := ""
	for _, id := range ids {
		if id == previous {
			continue
		}
		previous = id
		if !executionUUIDs(id) {
			return domain.ErrInvalid
		}
		if _, err := lockPrincipal(ctx, tx, id); err != nil {
			return err
		}
		if _, _, err := lockExecutionScopes(ctx, tx, run, id); err != nil {
			return err
		}
	}
	return nil
}

// Preflight reads have no creation claim. The trusted adapter uses this only
// for fixed me/room GETs, retaining current source/audience locks throughout.
func (s *Store) WithExecutionArchiveSource(ctx context.Context, reader EvidenceReader, runID string, audience []string, fn func(context.Context) error) error {
	if fn == nil {
		return domain.ErrInvalid
	}
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	run, _, err := evidenceAccess(ctx, tx, reader, runID, "audit")
	if err != nil {
		return err
	}
	if err = lockArchiveAudience(ctx, tx, run, audience); err != nil {
		return err
	}
	bounded, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	if err = fn(bounded); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// Called only for a deployment-owned target configuration, never a user API.
// Reusing an approved target ID for a different destination cannot bypass an
// unknown archive intention by silently changing its endpoint or ACL mapping.
func (s *Store) BindExecutionArchiveTarget(ctx context.Context, id, configHash string) error {
	if !archiveBindingValid(id) || !validExecutionID(configHash) {
		return domain.ErrInvalid
	}
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if _, err = tx.Exec(ctx, `INSERT INTO execution_archive_target_configs(binding_id,config_hash) VALUES($1,$2) ON CONFLICT DO NOTHING`, id, configHash); err != nil {
		return err
	}
	var actual string
	if err = tx.QueryRow(ctx, "SELECT config_hash FROM execution_archive_target_configs WHERE binding_id=$1 FOR SHARE", id).Scan(&actual); err != nil {
		return err
	}
	if actual != configHash {
		return domain.ErrConflict
	}
	return tx.Commit(ctx)
}
