package store

import (
	"context"

	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/jackc/pgx/v5"
)

// The caller holds the current identity, room/member and (for a Run) all
// inherited source locks until commit. Fetch at most one bounded excerpt per
// already-authorized room in one query; do not issue a message request per row.
func loadRoomPreviews(ctx context.Context, tx pgx.Tx, rooms []domain.Room) error {
	if len(rooms) == 0 {
		return nil
	}
	ids := make([]string, len(rooms))
	byID := make(map[string]int, len(rooms))
	for i := range rooms {
		ids[i] = rooms[i].ID
		byID[rooms[i].ID] = i
		rooms[i].LastMessage = nil
	}
	rows, err := tx.Query(ctx, `SELECT m.id::text,r.id::text,m.author_id::text,p.display_name,p.kind,left(m.content,240),m.seq,m.created_at
FROM rooms r
JOIN LATERAL (SELECT id,author_id,content,seq,created_at FROM messages WHERE room_id=r.id ORDER BY seq DESC LIMIT 1) m ON true
JOIN principals p ON p.id=m.author_id
WHERE r.id=ANY($1::uuid[]) ORDER BY r.id`, ids)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var preview domain.RoomPreview
		if err := rows.Scan(&preview.ID, &preview.RoomID, &preview.AuthorID, &preview.AuthorName, &preview.AuthorKind, &preview.Excerpt, &preview.Seq, &preview.CreatedAt); err != nil {
			return err
		}
		preview.ContentKind = "text"
		rooms[byID[preview.RoomID]].LastMessage = &preview
	}
	return rows.Err()
}
