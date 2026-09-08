package store

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"

	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/jackc/pgx/v5"
)

func validAction(id string) bool { return len(id) >= 8 && len(id) <= 160 }
func actionDigest(kind string, payload any) string {
	b, _ := json.Marshal(struct {
		Kind    string
		Payload any
	}{kind, payload})
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:])
}

// readAction holds the global per-principal action lock until transaction end.
// Callers must still reauthorize the current resource before returning a replay.
func readAction(ctx context.Context, tx pgx.Tx, actor, id, digest string, out any) (bool, error) {
	if _, err := tx.Exec(ctx, "SELECT pg_advisory_xact_lock(hashtextextended($1,0))", actor+"/"+id); err != nil {
		return false, err
	}
	var prior string
	var data []byte
	err := tx.QueryRow(ctx, "SELECT request_hash,receipt FROM actions WHERE principal_id=$1 AND action_id=$2", actor, id).Scan(&prior, &data)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if prior != digest {
		return false, domain.ErrConflict
	}
	return true, json.Unmarshal(data, out)
}
func saveAction(ctx context.Context, tx pgx.Tx, actor, id, digest string, out any) error {
	data, err := json.Marshal(out)
	if err != nil {
		return err
	}
	_, err = tx.Exec(ctx, "INSERT INTO actions(principal_id,action_id,request_hash,receipt) VALUES($1,$2,$3,$4)", actor, id, digest, data)
	return err
}
func workspaceAccess(ctx context.Context, tx pgx.Tx, actor, workspace string) (string, error) {
	var role string
	err := tx.QueryRow(ctx, `SELECT wm.role FROM workspace_members wm JOIN principals p ON p.id=wm.principal_id WHERE wm.workspace_id=$1 AND wm.principal_id=$2 AND NOT p.disabled FOR SHARE OF wm,p`, workspace, actor).Scan(&role)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", domain.ErrForbidden
	}
	return role, err
}
