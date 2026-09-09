package store

import (
	"context"
	"crypto/sha256"
	"embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io/fs"
	"sort"
	"strings"
	"sync"

	"github.com/google/uuid"
	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/huapohen/active-agent/services/collaboration/internal/store/sqlgen"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"
)

//go:embed migrations/*.sql
var migrations embed.FS

type Store struct {
	Pool                *pgxpool.Pool
	reactionValidatorMu sync.RWMutex
	reactionValidator   ReactionEmojiValidator
}

func Open(ctx context.Context, dsn string) (*Store, error) {
	p, err := pgxpool.New(ctx, dsn)
	if err != nil {
		return nil, err
	}
	if err = p.Ping(ctx); err != nil {
		p.Close()
		return nil, err
	}
	return &Store{Pool: p}, nil
}
func (s *Store) Close() { s.Pool.Close() }
func (s *Store) Migrate(ctx context.Context) error {
	db := stdlib.OpenDBFromPool(s.Pool)
	defer db.Close()
	files, err := fs.Sub(migrations, "migrations")
	if err != nil {
		return err
	}
	p, err := goose.NewProvider(goose.DialectPostgres, db, files)
	if err != nil {
		return err
	}
	_, err = p.Up(ctx)
	return err
}

// ResolveIdentity binds only a verifier-produced issuer/subject. Clients cannot
// choose principal IDs, actor kinds, or map themselves to existing identities.
func (s *Store) ResolveIdentity(ctx context.Context, issuer, subject string) (domain.Principal, error) {
	var p domain.Principal
	if issuer == "" || subject == "" {
		return p, domain.ErrForbidden
	}
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return p, err
	}
	defer tx.Rollback(ctx)
	if _, err = tx.Exec(ctx, "SELECT pg_advisory_xact_lock(hashtextextended($1,0))", issuer+"\x1f"+subject); err != nil {
		return p, err
	}
	var disabled bool
	err = tx.QueryRow(ctx, `SELECT p.id::text,p.kind,p.display_name,p.disabled FROM external_identities i JOIN principals p ON p.id=i.principal_id WHERE issuer=$1 AND subject=$2 FOR SHARE OF p`, issuer, subject).Scan(&p.ID, &p.Kind, &p.DisplayName, &disabled)
	if errors.Is(err, pgx.ErrNoRows) {
		p = domain.Principal{ID: uuid.NewString(), Kind: "human", DisplayName: "新同事"}
		_, err = tx.Exec(ctx, "INSERT INTO principals(id,kind,display_name) VALUES($1,$2,$3)", p.ID, p.Kind, p.DisplayName)
		if err == nil {
			_, err = tx.Exec(ctx, "INSERT INTO external_identities VALUES($1,$2,$3)", issuer, subject, p.ID)
		}
	}
	if err != nil {
		return p, err
	}
	if disabled {
		return p, domain.ErrForbidden
	}
	return p, tx.Commit(ctx)
}

func lockPrincipal(ctx context.Context, tx pgx.Tx, id string) (domain.Principal, error) {
	var p domain.Principal
	var disabled bool
	err := tx.QueryRow(ctx, "SELECT id::text,kind,display_name,disabled FROM principals WHERE id=$1 FOR SHARE", id).Scan(&p.ID, &p.Kind, &p.DisplayName, &disabled)
	if errors.Is(err, pgx.ErrNoRows) || disabled {
		return p, domain.ErrForbidden
	}
	return p, err
}

func (s *Store) CreateWorkspace(ctx context.Context, actor, action, title string) (string, error) {
	title = strings.TrimSpace(title)
	if !singleLine(title, 240, 240) || !validAction(action) {
		return "", domain.ErrInvalid
	}
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return "", err
	}
	defer tx.Rollback(ctx)
	if _, err = lockPrincipal(ctx, tx, actor); err != nil {
		return "", err
	}
	digest := actionDigest("workspace.create", title)
	var prior string
	replayed, err := readAction(ctx, tx, actor, action, digest, &prior)
	if err != nil {
		return "", err
	}
	if replayed {
		if _, err = workspaceAccess(ctx, tx, actor, prior); err != nil {
			return "", err
		}
		return prior, tx.Commit(ctx)
	}
	id := uuid.NewString()
	if _, err = tx.Exec(ctx, "INSERT INTO workspaces(id,title) VALUES($1,$2)", id, title); err != nil {
		return "", err
	}
	if _, err = tx.Exec(ctx, "INSERT INTO workspace_members VALUES($1,$2,'owner')", id, actor); err != nil {
		return "", err
	}
	if err = saveAction(ctx, tx, actor, action, digest, id); err != nil {
		return "", err
	}
	if err = event(ctx, tx, "", actor, action, "workspace.created", map[string]string{"id": id, "title": title}, false); err != nil {
		return "", err
	}
	return id, tx.Commit(ctx)
}

func (s *Store) CreateRoom(ctx context.Context, actor, action, workspace, title string, members []string) (domain.Room, error) {
	r := domain.Room{ID: uuid.NewString(), WorkspaceID: workspace, Title: strings.TrimSpace(title), Kind: "group", Version: 1, ScopeEpoch: 1}
	if !singleLine(r.Title, 240, 240) || len(members) > 100 || !validAction(action) || !executionUUIDs(workspace) {
		return r, domain.ErrInvalid
	}
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return r, err
	}
	defer tx.Rollback(ctx)
	if _, err = lockPrincipal(ctx, tx, actor); err != nil {
		return r, err
	}
	seen := map[string]bool{actor: true}
	for _, m := range members {
		seen[m] = true
	}
	ordered := make([]string, 0, len(seen))
	for m := range seen {
		if _, e := uuid.Parse(m); e != nil {
			return r, domain.ErrInvalid
		}
		ordered = append(ordered, m)
	}
	sort.Strings(ordered)
	digest := actionDigest("room.create", struct {
		Workspace, Title string
		Members          []string
	}{workspace, r.Title, ordered})
	var prior domain.Room
	replayed, err := readAction(ctx, tx, actor, action, digest, &prior)
	if err != nil {
		return r, err
	}
	if _, err = workspaceAccess(ctx, tx, actor, workspace); err != nil {
		return r, err
	}
	if replayed {
		if _, _, err = roomAccess(ctx, tx, actor, prior.ID); err != nil {
			return r, err
		}
		return prior, tx.Commit(ctx)
	}
	// Lock current membership and disabled state for every requested member;
	// concurrent revocation cannot slip between admission and room creation.
	for _, m := range ordered {
		if _, err = workspaceAccess(ctx, tx, m, workspace); err != nil {
			return r, err
		}
	}
	if _, err = tx.Exec(ctx, "INSERT INTO rooms(id,workspace_id,title) VALUES($1,$2,$3)", r.ID, workspace, r.Title); err != nil {
		return r, err
	}
	for m := range seen {
		memberRole := "member"
		if m == actor {
			memberRole = "owner"
		}
		if _, err = tx.Exec(ctx, "INSERT INTO room_members VALUES($1,$2,$3)", r.ID, m, memberRole); err != nil {
			return r, err
		}
	}
	if err = saveAction(ctx, tx, actor, action, digest, r); err != nil {
		return r, err
	}
	if err = event(ctx, tx, r.ID, actor, action, "room.created", r, true); err != nil {
		return r, err
	}
	return r, tx.Commit(ctx)
}

func event(ctx context.Context, tx pgx.Tx, room, actor, action, kind string, data any, transport bool) error {
	b, err := json.Marshal(data)
	if err != nil {
		return err
	}
	var id int64
	var roomID any
	if room != "" {
		roomID = room
	}
	err = tx.QueryRow(ctx, "INSERT INTO events(room_id,principal_id,action_id,type,data) VALUES($1,$2,$3,$4,$5) RETURNING id", roomID, actor, action, kind, b).Scan(&id)
	if err != nil {
		return err
	}
	if transport {
		_, err = tx.Exec(ctx, "INSERT INTO transport_outbox(event_id,provider) VALUES($1,'rongcloud')", id)
	}
	return err
}

func roomAccess(ctx context.Context, tx pgx.Tx, actor, room string) (domain.Room, string, error) {
	var r domain.Room
	var role string
	err := tx.QueryRow(ctx, `SELECT r.id::text,r.workspace_id::text,r.title,r.kind,r.version,r.scope_epoch,r.stopped,m.role
FROM rooms r JOIN room_members m ON m.room_id=r.id JOIN workspace_members wm ON wm.workspace_id=r.workspace_id AND wm.principal_id=m.principal_id
WHERE r.id=$1 AND m.principal_id=$2 FOR UPDATE OF r FOR SHARE OF m,wm`, room, actor).Scan(&r.ID, &r.WorkspaceID, &r.Title, &r.Kind, &r.Version, &r.ScopeEpoch, &r.Stopped, &role)
	if errors.Is(err, pgx.ErrNoRows) {
		err = domain.ErrForbidden
	}
	return r, role, err
}

func (s *Store) Send(ctx context.Context, actor, room string, cmd domain.SendMessage) (domain.Receipt, error) {
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return domain.Receipt{}, err
	}
	defer tx.Rollback(ctx)
	out, err := sendTx(ctx, tx, actor, room, cmd)
	if err != nil {
		return out, err
	}
	return out, tx.Commit(ctx)
}

// sendTx shares the caller's transaction so a native execution can fence all
// inherited source scopes through the same message/action/event/outbox commit.
func sendTx(ctx context.Context, tx pgx.Tx, actor, room string, cmd domain.SendMessage) (domain.Receipt, error) {
	var out domain.Receipt
	if strings.TrimSpace(cmd.Content) == "" || len(cmd.Content) > 8192 || len(cmd.ActionID) < 8 || len(cmd.ActionID) > 160 || (cmd.ReplyTo != "" && !executionUUIDs(cmd.ReplyTo)) {
		return out, domain.ErrInvalid
	}
	b, _ := json.Marshal(struct {
		Room    string
		Command domain.SendMessage
	}{room, cmd})
	h := sha256.Sum256(b)
	digest := hex.EncodeToString(h[:])
	p, err := lockPrincipal(ctx, tx, actor)
	if err != nil {
		return out, err
	}
	// Serialize the action ID globally for this actor, including cross-room reuse.
	if _, err = tx.Exec(ctx, "SELECT pg_advisory_xact_lock(hashtextextended($1,0))", actor+"/"+cmd.ActionID); err != nil {
		return out, err
	}
	r, _, err := roomAccess(ctx, tx, actor, room)
	if err != nil {
		return out, err
	}
	var prior string
	var raw []byte
	err = tx.QueryRow(ctx, "SELECT request_hash,receipt FROM actions WHERE principal_id=$1 AND action_id=$2", actor, cmd.ActionID).Scan(&prior, &raw)
	if err == nil {
		if prior != digest {
			return out, domain.ErrConflict
		}
		if err = json.Unmarshal(raw, &out); err != nil {
			return out, err
		}
		out.Replayed = true
		return out, nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return out, err
	}
	// Replaying an existing receipt is a read; admitting a NEW agent action
	// always checks the currently locked scope epoch, even after resume.
	if p.Kind == "agent" && (r.Stopped || cmd.ScopeEpoch == nil || *cmd.ScopeEpoch != r.ScopeEpoch) {
		return out, domain.ErrStopped
	}
	m := domain.Message{ID: uuid.NewString(), RoomID: room, AuthorID: actor, Content: cmd.Content, ReplyTo: cmd.ReplyTo}
	var snapshot []byte
	if cmd.ReplyTo != "" {
		m.Reply, err = messageReplySnapshot(ctx, tx, room, cmd.ReplyTo)
		if err != nil {
			return out, err
		}
		snapshot, err = json.Marshal(m.Reply)
		if err != nil {
			return out, err
		}
	}
	if err = tx.QueryRow(ctx, "UPDATE rooms SET seq=seq+1 WHERE id=$1 RETURNING seq", room).Scan(&m.Seq); err != nil {
		return out, err
	}
	if err = tx.QueryRow(ctx, "INSERT INTO messages(id,room_id,author_id,content,seq,reply_to,reply_snapshot) VALUES($1,$2,$3,$4,$5,NULLIF($6,'')::uuid,$7) RETURNING created_at", m.ID, room, actor, m.Content, m.Seq, m.ReplyTo, snapshot).Scan(&m.CreatedAt); err != nil {
		return out, err
	}
	out.Message = m
	raw, _ = json.Marshal(out)
	if _, err = tx.Exec(ctx, "INSERT INTO actions(principal_id,action_id,request_hash,receipt) VALUES($1,$2,$3,$4)", actor, cmd.ActionID, digest, raw); err != nil {
		return out, err
	}
	if err = event(ctx, tx, room, actor, cmd.ActionID, "message.created", m, true); err != nil {
		return out, err
	}
	return out, nil
}

func (s *Store) SetStopped(ctx context.Context, actor, room, action string, expected int64, stopped bool) (domain.Room, error) {
	var r domain.Room
	if !validAction(action) || expected < 1 {
		return r, domain.ErrInvalid
	}
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return r, err
	}
	defer tx.Rollback(ctx)
	if _, err = lockPrincipal(ctx, tx, actor); err != nil {
		return r, err
	}
	digest := actionDigest("room.execution_policy", struct {
		Room    string
		Version int64
		Stopped bool
	}{room, expected, stopped})
	var prior domain.Room
	replayed, err := readAction(ctx, tx, actor, action, digest, &prior)
	if err != nil {
		return r, err
	}
	r, role, err := roomAccess(ctx, tx, actor, room)
	if err != nil {
		return r, err
	}
	if role != "owner" && role != "admin" {
		return r, domain.ErrForbidden
	}
	if replayed {
		return prior, tx.Commit(ctx)
	}
	if r.Version != expected {
		return r, domain.ErrConflict
	}
	err = tx.QueryRow(ctx, "UPDATE rooms SET stopped=$2,scope_epoch=scope_epoch+1,version=version+1 WHERE id=$1 RETURNING scope_epoch,version", room, stopped).Scan(&r.ScopeEpoch, &r.Version)
	if err != nil {
		return r, err
	}
	r.Stopped = stopped
	if err = saveAction(ctx, tx, actor, action, digest, r); err != nil {
		return r, err
	}
	if err = event(ctx, tx, room, actor, action, "room.execution_policy_changed", r, false); err != nil {
		return r, err
	}
	return r, tx.Commit(ctx)
}

func (s *Store) Rooms(ctx context.Context, actor, after string) ([]domain.Room, error) {
	if after == "" {
		after = "00000000-0000-0000-0000-000000000000"
	}
	var actorID, afterID pgtype.UUID
	if actorID.Scan(actor) != nil || afterID.Scan(after) != nil {
		return nil, domain.ErrInvalid
	}
	rows, err := sqlgen.New(s.Pool).ListAuthorizedRooms(ctx, sqlgen.ListAuthorizedRoomsParams{PrincipalID: actorID, AfterID: afterID})
	if err != nil {
		return nil, err
	}
	out := []domain.Room{}
	for _, r := range rows {
		out = append(out, domain.Room{ID: r.ID, WorkspaceID: r.WorkspaceID, Title: r.Title, Kind: r.Kind, Version: r.Version, ScopeEpoch: r.ScopeEpoch, Stopped: r.Stopped})
	}
	return out, nil
}

func (s *Store) Messages(ctx context.Context, actor, room string, after int64) ([]domain.Message, error) {
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	if _, err = lockPrincipal(ctx, tx, actor); err != nil {
		return nil, err
	}
	if _, _, err = roomAccess(ctx, tx, actor, room); err != nil {
		return nil, err
	}
	out, err := readMessageRows(ctx, tx, actor, room, after)
	if err != nil {
		return nil, err
	}
	return out, tx.Commit(ctx)
}
