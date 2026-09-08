package store

import (
	"context"
	"errors"
	"slices"

	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/jackc/pgx/v5"
)

// Point reads and newest-first pages retain exactly the same current identity,
// source membership and execution fences as the forward native export.
type messageReadIdentity struct {
	actor, issuer, subject, run string
	machine                     bool
}

func authorizeMessageSelection(ctx context.Context, tx pgx.Tx, identity messageReadIdentity, roomID string) (string, error) {
	if !identity.machine {
		if _, err := lockPrincipal(ctx, tx, identity.actor); err != nil {
			return "", err
		}
		_, _, err := roomAccess(ctx, tx, identity.actor, roomID)
		return identity.actor, err
	}
	if identity.run != "" {
		binding, run, err := executionReadRun(ctx, tx, identity.issuer, identity.subject, identity.run)
		if err != nil {
			return "", err
		}
		scopes, err := executionScopes(run.Context)
		if err != nil {
			return "", err
		}
		for _, scope := range scopes {
			if scope.RoomID == roomID {
				return binding.Principal.ID, nil
			}
		}
		return "", domain.ErrForbidden
	}
	binding, err := executorByMachine(ctx, tx, identity.issuer, identity.subject)
	if err != nil {
		return "", err
	}
	room, _, err := roomAccess(ctx, tx, binding.Principal.ID, roomID)
	if err != nil {
		return "", err
	}
	if room.WorkspaceID != binding.WorkspaceID {
		return "", domain.ErrForbidden
	}
	return binding.Principal.ID, nil
}

func (s *Store) selectedMessages(ctx context.Context, identity messageReadIdentity, roomID, messageID string, before int64, limit int) ([]domain.Message, error) {
	if !executionUUIDs(roomID) || (messageID != "" && !executionUUIDs(messageID)) || before < 0 || limit < 1 || limit > 100 {
		return nil, domain.ErrInvalid
	}
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	actor, err := authorizeMessageSelection(ctx, tx, identity, roomID)
	if err != nil {
		return nil, err
	}
	out := []domain.Message{}
	if messageID != "" {
		m, err := scanMessage(tx.QueryRow(ctx, "SELECT "+messageReadColumns+" FROM messages WHERE room_id=$1 AND id=$2", roomID, messageID))
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrForbidden
		}
		if err != nil {
			return nil, err
		}
		out = append(out, m)
	} else {
		rows, err := tx.Query(ctx, "SELECT "+messageReadColumns+" FROM messages WHERE room_id=$1 AND ($2::bigint=0 OR seq<$2) ORDER BY seq DESC LIMIT $3", roomID, before, limit+1)
		if err != nil {
			return nil, err
		}
		for rows.Next() {
			m, err := scanMessage(rows)
			if err != nil {
				rows.Close()
				return nil, err
			}
			out = append(out, m)
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return nil, err
		}
		// Return the bounded look-ahead row first. The transport drops it when
		// len > limit and reports an exclusive cursor for the oldest kept row.
		slices.Reverse(out)
	}
	if err := hydrateMessages(ctx, tx, actor, out); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return out, nil
}

func (s *Store) Message(ctx context.Context, actor, roomID, messageID string) (domain.Message, error) {
	return s.selectedMessage(ctx, messageReadIdentity{actor: actor}, roomID, messageID)
}
func (s *Store) ExecutorMessage(ctx context.Context, issuer, subject, roomID, messageID string) (domain.Message, error) {
	return s.selectedMessage(ctx, messageReadIdentity{issuer: issuer, subject: subject, machine: true}, roomID, messageID)
}
func (s *Store) ExecutionMessage(ctx context.Context, issuer, subject, runID, roomID, messageID string) (domain.Message, error) {
	return s.selectedMessage(ctx, messageReadIdentity{issuer: issuer, subject: subject, run: runID, machine: true}, roomID, messageID)
}
func (s *Store) selectedMessage(ctx context.Context, identity messageReadIdentity, roomID, messageID string) (domain.Message, error) {
	if !executionUUIDs(messageID) {
		return domain.Message{}, domain.ErrInvalid
	}
	messages, err := s.selectedMessages(ctx, identity, roomID, messageID, 0, 1)
	if err != nil {
		return domain.Message{}, err
	}
	return messages[0], nil
}
func (s *Store) MessagesBefore(ctx context.Context, actor, roomID string, before int64, limit int) ([]domain.Message, error) {
	return s.selectedMessages(ctx, messageReadIdentity{actor: actor}, roomID, "", before, limit)
}
func (s *Store) ExecutorMessagesBefore(ctx context.Context, issuer, subject, roomID string, before int64, limit int) ([]domain.Message, error) {
	return s.selectedMessages(ctx, messageReadIdentity{issuer: issuer, subject: subject, machine: true}, roomID, "", before, limit)
}
func (s *Store) ExecutionMessagesBefore(ctx context.Context, issuer, subject, runID, roomID string, before int64, limit int) ([]domain.Message, error) {
	return s.selectedMessages(ctx, messageReadIdentity{issuer: issuer, subject: subject, run: runID, machine: true}, roomID, "", before, limit)
}
