package store

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"unicode/utf8"

	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/jackc/pgx/v5"
)

// A deployment supplies a trusted stable-ID catalog. Never accept arbitrary
// strings or treat a missing provider as an allow-all emoji configuration.
type ReactionEmojiValidator interface{ Contains(string) bool }

func (s *Store) SetReactionEmojiValidator(v ReactionEmojiValidator) {
	s.reactionValidatorMu.Lock()
	defer s.reactionValidatorMu.Unlock()
	s.reactionValidator = v
}
func (s *Store) validReactionEmoji(id string) bool {
	if len(id) == 0 || len(id) > 160 || !utf8.ValidString(id) || strings.ContainsRune(id, 0) {
		return false
	}
	s.reactionValidatorMu.RLock()
	defer s.reactionValidatorMu.RUnlock()
	return s.reactionValidator != nil && s.reactionValidator.Contains(id)
}
func excerpt(s string, limit int) string {
	r := []rune(s)
	if len(r) > limit {
		r = r[:limit]
	}
	return string(r)
}
func messageReplySnapshot(ctx context.Context, tx pgx.Tx, room, id string) (*domain.MessageReply, error) {
	out := new(domain.MessageReply)
	var content string
	err := tx.QueryRow(ctx, `SELECT m.id::text,m.room_id::text,m.author_id::text,p.display_name,p.kind,m.content,m.seq
 FROM messages m JOIN principals p ON p.id=m.author_id WHERE m.id=$1 AND m.room_id=$2 FOR SHARE OF m,p`, id, room).Scan(&out.MessageID, &out.RoomID, &out.AuthorID, &out.AuthorName, &out.AuthorKind, &content, &out.Seq)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, domain.ErrInvalid
	}
	if err != nil {
		return nil, err
	}
	out.Excerpt = excerpt(content, 240)
	out.AuthorName = excerpt(out.AuthorName, 160)
	return out, nil
}

const messageReadColumns = `id::text,room_id::text,author_id::text,content,seq,created_at,COALESCE(reply_to::text,''),reply_snapshot,reaction_version`

func scanMessage(row pgx.Row) (domain.Message, error) {
	var m domain.Message
	var raw []byte
	err := row.Scan(&m.ID, &m.RoomID, &m.AuthorID, &m.Content, &m.Seq, &m.CreatedAt, &m.ReplyTo, &raw, &m.ReactionVersion)
	if err == nil && len(raw) > 0 {
		err = json.Unmarshal(raw, &m.Reply)
	}
	return m, err
}

// Caller holds room membership and room locks through hydration. Each message
// contributes at most 21 rows, independent of the number of reaction principals.
func hydrateMessages(ctx context.Context, tx pgx.Tx, actor string, messages []domain.Message) error {
	if len(messages) == 0 {
		return nil
	}
	ids := make([]string, len(messages))
	index := map[string]int{}
	for i := range messages {
		ids[i] = messages[i].ID
		index[ids[i]] = i
	}
	rows, err := tx.Query(ctx, `SELECT ids.id::text,r.emoji,r.n,r.selected FROM unnest($1::uuid[]) ids(id)
 CROSS JOIN LATERAL (SELECT emoji,count(*) AS n,bool_or(principal_id=$2::uuid) AS selected
 FROM message_reactions WHERE message_id=ids.id AND active GROUP BY emoji ORDER BY emoji COLLATE "C" LIMIT 21) r
 ORDER BY ids.id,r.emoji COLLATE "C"`, ids, actor)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var id string
		var r domain.ReactionSummary
		if err = rows.Scan(&id, &r.Emoji, &r.Count, &r.Selected); err != nil {
			return err
		}
		m := &messages[index[id]]
		if len(m.Reactions) == 20 {
			m.ReactionsHasMore = true
			m.ReactionsNextAfter = m.Reactions[19].Emoji
			continue
		}
		m.Reactions = append(m.Reactions, r)
	}
	return rows.Err()
}
func readMessageRows(ctx context.Context, tx pgx.Tx, actor, room string, after int64) ([]domain.Message, error) {
	rows, err := tx.Query(ctx, `SELECT `+messageReadColumns+` FROM messages WHERE room_id=$1 AND seq>$2 ORDER BY seq LIMIT 101`, room, after)
	if err != nil {
		return nil, err
	}
	out := []domain.Message{}
	for rows.Next() {
		m, scanErr := scanMessage(rows)
		if scanErr != nil {
			rows.Close()
			return nil, scanErr
		}
		out = append(out, m)
	}
	rows.Close()
	if err = rows.Err(); err != nil {
		return nil, err
	}
	if err = hydrateMessages(ctx, tx, actor, out); err != nil {
		return nil, err
	}
	return out, nil
}

func (s *Store) SetReaction(ctx context.Context, actor, room, message string, cmd domain.SetReaction) (domain.ReactionReceipt, error) {
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return domain.ReactionReceipt{}, err
	}
	defer tx.Rollback(ctx)
	out, err := s.reactionSetTx(ctx, tx, actor, room, message, cmd)
	if err != nil {
		return out, err
	}
	return out, tx.Commit(ctx)
}
func (s *Store) reactionSetTx(ctx context.Context, tx pgx.Tx, actor, room, message string, cmd domain.SetReaction) (domain.ReactionReceipt, error) {
	var out domain.ReactionReceipt
	if !validAction(cmd.ActionID) || !executionUUIDs(room, message) || !s.validReactionEmoji(cmd.Emoji) {
		return out, domain.ErrInvalid
	}
	p, err := lockPrincipal(ctx, tx, actor)
	if err != nil {
		return out, err
	}
	// All routes use the same actor/action lock before resource locks.
	digest := actionDigest("reaction.set", struct {
		Room, Message string
		Command       domain.SetReaction
	}{room, message, cmd})
	replay, err := readAction(ctx, tx, actor, cmd.ActionID, digest, &out)
	if err != nil {
		return out, err
	}
	r, _, err := roomAccess(ctx, tx, actor, room)
	if err != nil {
		return out, err
	}
	if replay {
		out.Replayed = true
		return out, nil
	}
	if p.Kind == "agent" && (r.Stopped || cmd.ScopeEpoch == nil || *cmd.ScopeEpoch != r.ScopeEpoch) {
		return out, domain.ErrStopped
	}
	var version int64
	err = tx.QueryRow(ctx, `SELECT reaction_version FROM messages WHERE id=$1 AND room_id=$2 FOR UPDATE`, message, room).Scan(&version)
	if errors.Is(err, pgx.ErrNoRows) {
		return out, domain.ErrInvalid
	}
	if err != nil {
		return out, err
	}
	var old bool
	err = tx.QueryRow(ctx, `SELECT active FROM message_reactions WHERE message_id=$1 AND principal_id=$2 AND emoji=$3`, message, actor, cmd.Emoji).Scan(&old)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return out, err
	}
	_, err = tx.Exec(ctx, `INSERT INTO message_reactions(message_id,principal_id,emoji,active) VALUES($1,$2,$3,$4)
 ON CONFLICT(message_id,principal_id,emoji) DO UPDATE SET active=EXCLUDED.active,updated_at=now()`, message, actor, cmd.Emoji, cmd.Active)
	if err != nil {
		return out, err
	}
	out = domain.ReactionReceipt{RoomID: room, MessageID: message, PrincipalID: actor, Emoji: cmd.Emoji, Active: cmd.Active, Changed: old != cmd.Active, Selected: cmd.Active}
	if err = tx.QueryRow(ctx, `UPDATE messages SET reaction_version=reaction_version+1 WHERE id=$1 RETURNING reaction_version`, message).Scan(&out.Version); err != nil {
		return out, err
	}
	if err = tx.QueryRow(ctx, `SELECT count(*) FROM message_reactions WHERE message_id=$1 AND emoji=$2 AND active`, message, cmd.Emoji).Scan(&out.Count); err != nil {
		return out, err
	}
	if err = saveAction(ctx, tx, actor, cmd.ActionID, digest, out); err != nil {
		return out, err
	}
	if err = event(ctx, tx, room, actor, cmd.ActionID, "message.reaction_set", out, true); err != nil {
		return out, err
	}
	return out, nil
}

type ReactionQuery struct {
	After           string
	Limit           int
	ExpectedVersion *int64
}

func reactionSummariesTx(ctx context.Context, tx pgx.Tx, actor, room, message string, q ReactionQuery) (domain.ReactionPage, error) {
	out := domain.ReactionPage{RoomID: room, MessageID: message, Summaries: []domain.ReactionSummary{}}
	if !executionUUIDs(room, message) || q.Limit < 0 || q.Limit > 50 || len(q.After) > 160 || !utf8.ValidString(q.After) || strings.ContainsRune(q.After, 0) || (q.ExpectedVersion != nil && *q.ExpectedVersion < 0) {
		return out, domain.ErrInvalid
	}
	if q.Limit == 0 {
		q.Limit = 50
	}
	// A noninitial page must fence the version. A cursor alone cannot establish
	// that aggregate rows still belong to the snapshot fetched by the caller.
	if q.After != "" && q.ExpectedVersion == nil {
		return out, domain.ErrInvalid
	}
	err := tx.QueryRow(ctx, `SELECT reaction_version FROM messages WHERE id=$1 AND room_id=$2`, message, room).Scan(&out.Version)
	if errors.Is(err, pgx.ErrNoRows) {
		return out, domain.ErrForbidden
	}
	if err != nil {
		return out, err
	}
	if q.ExpectedVersion != nil && *q.ExpectedVersion != out.Version {
		return out, domain.ErrConflict
	}
	rows, err := tx.Query(ctx, `SELECT emoji,count(*),bool_or(principal_id=$2::uuid) FROM message_reactions
 WHERE message_id=$1 AND active AND emoji>$3 COLLATE "C" GROUP BY emoji ORDER BY emoji COLLATE "C" LIMIT $4`, message, actor, q.After, q.Limit+1)
	if err != nil {
		return out, err
	}
	defer rows.Close()
	for rows.Next() {
		var r domain.ReactionSummary
		if err = rows.Scan(&r.Emoji, &r.Count, &r.Selected); err != nil {
			return out, err
		}
		out.Summaries = append(out.Summaries, r)
	}
	if err = rows.Err(); err != nil {
		return out, err
	}
	if len(out.Summaries) > q.Limit {
		out.Summaries = out.Summaries[:q.Limit]
		out.HasMore = true
		out.NextAfter = out.Summaries[len(out.Summaries)-1].Emoji
	}
	return out, nil
}
func (s *Store) ReactionSummaries(ctx context.Context, actor, room, message string, q ReactionQuery) (domain.ReactionPage, error) {
	var out domain.ReactionPage
	if !executionUUIDs(room, message) {
		return out, domain.ErrInvalid
	}
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return out, err
	}
	defer tx.Rollback(ctx)
	if _, err = lockPrincipal(ctx, tx, actor); err != nil {
		return out, err
	}
	if _, _, err = roomAccess(ctx, tx, actor, room); err != nil {
		return out, err
	}
	out, err = reactionSummariesTx(ctx, tx, actor, room, message, q)
	if err != nil {
		return out, err
	}
	return out, tx.Commit(ctx)
}
func (s *Store) ExecutorReactionSummaries(ctx context.Context, issuer, subject, room, message string, q ReactionQuery) (domain.ReactionPage, error) {
	var out domain.ReactionPage
	if !executionUUIDs(room, message) {
		return out, domain.ErrInvalid
	}
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return out, err
	}
	defer tx.Rollback(ctx)
	b, err := executorByMachine(ctx, tx, issuer, subject)
	if err != nil {
		return out, err
	}
	r, _, err := roomAccess(ctx, tx, b.Principal.ID, room)
	if err != nil {
		return out, err
	}
	if r.WorkspaceID != b.WorkspaceID {
		return out, domain.ErrForbidden
	}
	out, err = reactionSummariesTx(ctx, tx, b.Principal.ID, room, message, q)
	if err != nil {
		return out, err
	}
	return out, tx.Commit(ctx)
}
func (s *Store) ExecutionReactionSummaries(ctx context.Context, issuer, subject, runID, room, message string, q ReactionQuery) (domain.ReactionPage, error) {
	var out domain.ReactionPage
	if !executionUUIDs(room, message) {
		return out, domain.ErrInvalid
	}
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return out, err
	}
	defer tx.Rollback(ctx)
	b, run, err := executionReadRun(ctx, tx, issuer, subject, runID)
	if err != nil {
		return out, err
	}
	scopes, err := executionScopes(run.Context)
	if err != nil {
		return out, err
	}
	found := false
	for _, scope := range scopes {
		if scope.RoomID == room {
			found = true
		}
	}
	if !found {
		return out, domain.ErrForbidden
	}
	out, err = reactionSummariesTx(ctx, tx, b.Principal.ID, room, message, q)
	if err != nil {
		return out, err
	}
	return out, tx.Commit(ctx)
}
