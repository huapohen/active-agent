package store

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
	"testing"

	"github.com/google/uuid"
	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/huapohen/active-agent/services/collaboration/internal/harness"
	"github.com/huapohen/active-agent/services/collaboration/internal/transport"
	"github.com/stretchr/testify/require"
)

type testEmojiCatalog map[string]bool

func (c testEmojiCatalog) Contains(id string) bool { return c[id] }
func reactionFixture(t *testing.T) (executionFixture, domain.Message) {
	t.Helper()
	f := newExecutionFixture(t, "human")
	f.s.SetReactionEmojiValidator(testEmojiCatalog{"feishu:OK": true, "unicode:heart": true})
	r, err := f.s.Send(context.Background(), f.owner, f.target.ID, domain.SendMessage{ActionID: "message-to-react", Content: "服务端消息事实"})
	require.NoError(t, err)
	return f, r.Message
}
func reactionAction(run ExecutionRun, key, message, emoji string, active bool) harness.Action {
	raw, _ := json.Marshal(map[string]any{"message_id": message, "emoji": emoji, "active": active})
	return harness.Action{ID: harness.StableID(run.Context.RunID, key), Type: "reaction.set", Payload: raw}
}
func TestMessageReplySnapshotSameRoomAndLegacyDigest(t *testing.T) {
	f, m := reactionFixture(t)
	ctx := context.Background()
	// The old shape retains its exact JSON and action digest when reply is absent.
	old := struct {
		Room    string
		Command struct {
			ActionID   string `json:"action_id"`
			Content    string `json:"content"`
			ScopeEpoch *int64 `json:"scope_epoch,omitempty"`
		}
	}{Room: f.target.ID}
	old.Command.ActionID = "message-to-react"
	old.Command.Content = m.Content
	raw, _ := json.Marshal(old)
	sum := sha256.Sum256(raw)
	var digest string
	require.NoError(t, f.s.Pool.QueryRow(ctx, "SELECT request_hash FROM actions WHERE principal_id=$1 AND action_id=$2", f.owner, old.Command.ActionID).Scan(&digest))
	require.Equal(t, hex.EncodeToString(sum[:]), digest)
	raw, _ = json.Marshal(m)
	require.NotContains(t, string(raw), "reply")
	require.NotContains(t, string(raw), "reaction")
	_, err := f.s.Pool.Exec(ctx, "UPDATE messages SET content=$2 WHERE id=$1", m.ID, strings.Repeat("中", 300))
	require.NoError(t, err)
	cmd := domain.SendMessage{ActionID: "server-snapshot-reply", Content: "回应", ReplyTo: m.ID}
	got, err := f.s.Send(ctx, f.employee, f.target.ID, cmd)
	require.NoError(t, err)
	require.NotNil(t, got.Message.Reply)
	require.Equal(t, m.ID, got.Message.ReplyTo)
	require.Equal(t, m.AuthorID, got.Message.Reply.AuthorID)
	require.Equal(t, "human", got.Message.Reply.AuthorKind)
	require.Equal(t, "测试human", got.Message.Reply.AuthorName)
	require.Len(t, []rune(got.Message.Reply.Excerpt), 240)
	_, err = f.s.Pool.Exec(ctx, "UPDATE principals SET display_name='名字变更' WHERE id=$1", m.AuthorID)
	require.NoError(t, err)
	replay, err := f.s.Send(ctx, f.employee, f.target.ID, cmd)
	require.NoError(t, err)
	require.True(t, replay.Replayed)
	require.Equal(t, got.Message, replay.Message)
	list, err := f.s.Messages(ctx, f.employee, f.target.ID, 0)
	require.NoError(t, err)
	require.Equal(t, got.Message.Reply, list[1].Reply)
	for name, id := range map[string]string{"foreign": m.ID, "missing": uuid.NewString(), "malformed": "not-uuid"} {
		t.Run(name, func(t *testing.T) {
			room := f.target.ID
			if name == "foreign" {
				room = f.source.ID
			}
			_, e := f.s.Send(ctx, f.employee, room, domain.SendMessage{ActionID: "invalid-reply-" + name, Content: "不得提交", ReplyTo: id})
			require.ErrorIs(t, e, domain.ErrInvalid)
		})
	}
	bad := cmd
	bad.ReplyTo = ""
	_, err = f.s.Send(ctx, f.employee, f.target.ID, bad)
	require.ErrorIs(t, err, domain.ErrConflict)
	require.Equal(t, 2, executionCount(t, f.s, "messages"))
}
func TestReactionConcurrentIdempotencyExplicitStateAndServerCounts(t *testing.T) {
	f, m := reactionFixture(t)
	ctx := context.Background()
	cmd := domain.SetReaction{ActionID: "one-concurrent-reaction", Emoji: "feishu:OK", Active: true}
	var wg sync.WaitGroup
	errs := make(chan error, 12)
	receipts := make(chan domain.ReactionReceipt, 12)
	for i := 0; i < 12; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			r, e := f.s.SetReaction(ctx, f.employee, f.target.ID, m.ID, cmd)
			errs <- e
			receipts <- r
		}()
	}
	wg.Wait()
	close(errs)
	close(receipts)
	for e := range errs {
		require.NoError(t, e)
	}
	original := 0
	for r := range receipts {
		require.EqualValues(t, 1, r.Count)
		require.EqualValues(t, 1, r.Version)
		require.True(t, r.Selected)
		require.True(t, r.Changed)
		if !r.Replayed {
			original++
		}
	}
	require.Equal(t, 1, original)
	require.Equal(t, 1, executionCount(t, f.s, "message_reactions"))
	var events, outbox int
	require.NoError(t, f.s.Pool.QueryRow(ctx, `SELECT count(*),count(o.id) FROM events e LEFT JOIN transport_outbox o ON o.event_id=e.id WHERE e.type='message.reaction_set'`).Scan(&events, &outbox))
	require.Equal(t, 1, events)
	require.Equal(t, 1, outbox)
	// A new explicit set is auditable even when the state already matches.
	cmd.ActionID = "same-state-new-action"
	r, err := f.s.SetReaction(ctx, f.employee, f.target.ID, m.ID, cmd)
	require.NoError(t, err)
	require.False(t, r.Changed)
	require.EqualValues(t, 2, r.Version)
	require.EqualValues(t, 1, r.Count)
	ownerCmd := domain.SetReaction{ActionID: "owner-same-emoji", Emoji: cmd.Emoji, Active: true}
	r, err = f.s.SetReaction(ctx, f.owner, f.target.ID, m.ID, ownerCmd)
	require.NoError(t, err)
	require.EqualValues(t, 2, r.Count)
	cmd.ActionID = "explicit-remove-reaction"
	cmd.Active = false
	r, err = f.s.SetReaction(ctx, f.employee, f.target.ID, m.ID, cmd)
	require.NoError(t, err)
	require.True(t, r.Changed)
	require.False(t, r.Selected)
	require.EqualValues(t, 1, r.Count)
	cmd.ActionID = "remove-again-new-action"
	r, err = f.s.SetReaction(ctx, f.employee, f.target.ID, m.ID, cmd)
	require.NoError(t, err)
	require.False(t, r.Changed)
	require.EqualValues(t, 5, r.Version)
	old, err := f.s.SetReaction(ctx, f.employee, f.target.ID, m.ID, domain.SetReaction{ActionID: "one-concurrent-reaction", Emoji: "feishu:OK", Active: true})
	require.NoError(t, err)
	require.True(t, old.Replayed)
	require.True(t, old.Active)
	require.EqualValues(t, 1, old.Version)
	list, err := f.s.Messages(ctx, f.employee, f.target.ID, 0)
	require.NoError(t, err)
	require.EqualValues(t, 5, list[0].ReactionVersion)
	require.Equal(t, []domain.ReactionSummary{{Emoji: "feishu:OK", Count: 1, Selected: false}}, list[0].Reactions)
	list, err = f.s.Messages(ctx, f.owner, f.target.ID, 0)
	require.NoError(t, err)
	require.True(t, list[0].Reactions[0].Selected)
	for name, mutate := range map[string]func(*domain.SetReaction){"active": func(c *domain.SetReaction) { c.Active = true }, "emoji": func(c *domain.SetReaction) { c.Emoji = "unicode:heart" }} {
		t.Run(name, func(t *testing.T) {
			bad := cmd
			mutate(&bad)
			_, e := f.s.SetReaction(ctx, f.employee, f.target.ID, m.ID, bad)
			require.ErrorIs(t, e, domain.ErrConflict)
		})
	}
	// Sending text cannot reuse the same actor/action key either.
	_, err = f.s.Send(ctx, f.employee, f.target.ID, domain.SendMessage{ActionID: cmd.ActionID, Content: "different action type"})
	require.ErrorIs(t, err, domain.ErrConflict)
}
func TestReactionCatalogAndTargetFailClosed(t *testing.T) {
	f, m := reactionFixture(t)
	ctx := context.Background()
	cmd := domain.SetReaction{ActionID: "reject-unconfigured", Emoji: "feishu:OK", Active: true}
	f.s.SetReactionEmojiValidator(nil)
	_, err := f.s.SetReaction(ctx, f.owner, f.target.ID, m.ID, cmd)
	require.ErrorIs(t, err, domain.ErrInvalid)
	f.s.SetReactionEmojiValidator(testEmojiCatalog{"feishu:OK": true})
	for _, id := range []string{"unknown", "🙂", "", strings.Repeat("a", 161), "nul\x00"} {
		bad := cmd
		bad.Emoji = id
		_, err = f.s.SetReaction(ctx, f.owner, f.target.ID, m.ID, bad)
		require.ErrorIs(t, err, domain.ErrInvalid)
	}
	_, err = f.s.SetReaction(ctx, f.owner, f.source.ID, m.ID, cmd)
	require.ErrorIs(t, err, domain.ErrInvalid)
	_, err = f.s.SetReaction(ctx, f.owner, f.target.ID, uuid.NewString(), cmd)
	require.ErrorIs(t, err, domain.ErrInvalid)
	require.Zero(t, executionCount(t, f.s, "message_reactions"))
}
func TestReactionPaginationBoundedAndVersionFenced(t *testing.T) {
	f, m := reactionFixture(t)
	ctx := context.Background()
	catalog := testEmojiCatalog{}
	for i := 0; i < 57; i++ {
		catalog[fmt.Sprintf("catalog:%03d", i)] = true
	}
	f.s.SetReactionEmojiValidator(catalog)
	for i := 0; i < 57; i++ {
		_, err := f.s.SetReaction(ctx, f.owner, f.target.ID, m.ID, domain.SetReaction{ActionID: fmt.Sprintf("bounded-react-%03d", i), Emoji: fmt.Sprintf("catalog:%03d", i), Active: true})
		require.NoError(t, err)
	}
	messages, err := f.s.Messages(ctx, f.owner, f.target.ID, 0)
	require.NoError(t, err)
	require.Len(t, messages[0].Reactions, 20)
	require.True(t, messages[0].ReactionsHasMore)
	require.Equal(t, "catalog:019", messages[0].ReactionsNextAfter)
	p, err := f.s.ReactionSummaries(ctx, f.owner, f.target.ID, m.ID, ReactionQuery{})
	require.NoError(t, err)
	require.Len(t, p.Summaries, 50)
	require.EqualValues(t, 57, p.Version)
	require.True(t, p.HasMore)
	q := ReactionQuery{After: p.NextAfter, Limit: 50, ExpectedVersion: &p.Version}
	next, err := f.s.ReactionSummaries(ctx, f.owner, f.target.ID, m.ID, q)
	require.NoError(t, err)
	require.Len(t, next.Summaries, 7)
	require.False(t, next.HasMore)
	require.Empty(t, next.NextAfter)
	_, err = f.s.ReactionSummaries(ctx, f.owner, f.target.ID, m.ID, ReactionQuery{After: p.NextAfter})
	require.ErrorIs(t, err, domain.ErrInvalid)
	_, err = f.s.SetReaction(ctx, f.owner, f.target.ID, m.ID, domain.SetReaction{ActionID: "alter-version-during-pagination", Emoji: "catalog:056", Active: false})
	require.NoError(t, err)
	_, err = f.s.ReactionSummaries(ctx, f.owner, f.target.ID, m.ID, q)
	require.ErrorIs(t, err, domain.ErrConflict)
	_, err = f.s.ReactionSummaries(ctx, f.owner, f.target.ID, m.ID, ReactionQuery{Limit: 51})
	require.ErrorIs(t, err, domain.ErrInvalid)
}
func TestReactionAgentPolicyAndRevokedReplay(t *testing.T) {
	f, m := reactionFixture(t)
	ctx := context.Background()
	cmd := domain.SetReaction{ActionID: "agent-reaction-before-stop", Emoji: "feishu:OK", Active: true, ScopeEpoch: &f.target.ScopeEpoch}
	r, err := f.s.SetReaction(ctx, f.agent, f.target.ID, m.ID, cmd)
	require.NoError(t, err)
	require.Equal(t, f.agent, r.PrincipalID)
	stopped, err := f.s.SetStopped(ctx, f.owner, f.target.ID, "reaction-stop", f.target.Version, true)
	require.NoError(t, err)
	replay, err := f.s.SetReaction(ctx, f.agent, f.target.ID, m.ID, cmd)
	require.NoError(t, err)
	require.True(t, replay.Replayed)
	fresh := cmd
	fresh.ActionID = "agent-new-after-stop"
	_, err = f.s.SetReaction(ctx, f.agent, f.target.ID, m.ID, fresh)
	require.ErrorIs(t, err, domain.ErrStopped)
	_, err = f.s.SetReaction(ctx, f.employee, f.target.ID, m.ID, domain.SetReaction{ActionID: "human-after-stop", Emoji: "feishu:OK", Active: true})
	require.NoError(t, err)
	_, err = f.s.SetStopped(ctx, f.owner, f.target.ID, "reaction-resume", stopped.Version, false)
	require.NoError(t, err)
	_, err = f.s.SetReaction(ctx, f.agent, f.target.ID, m.ID, fresh)
	require.ErrorIs(t, err, domain.ErrStopped)
	_, err = f.s.Pool.Exec(ctx, "DELETE FROM room_members WHERE room_id=$1 AND principal_id=$2", f.target.ID, f.agent)
	require.NoError(t, err)
	_, err = f.s.SetReaction(ctx, f.agent, f.target.ID, m.ID, cmd)
	require.ErrorIs(t, err, domain.ErrForbidden)
	_, err = f.s.ReactionSummaries(ctx, f.agent, f.target.ID, m.ID, ReactionQuery{})
	require.ErrorIs(t, err, domain.ErrForbidden)
}
func TestExecutionReactionStrictPayloadConcurrentCommitAndOrigins(t *testing.T) {
	f, m := reactionFixture(t)
	ctx := context.Background()
	parent := f.run(t, f.source, "")
	run := f.run(t, f.target, parent.Context.RunID)
	for name, payload := range map[string]string{"missing_active": fmt.Sprintf(`{"message_id":%q,"emoji":"feishu:OK"}`, m.ID), "null_active": fmt.Sprintf(`{"message_id":%q,"emoji":"feishu:OK","active":null}`, m.ID), "forged_count": fmt.Sprintf(`{"message_id":%q,"emoji":"feishu:OK","active":true,"count":100}`, m.ID), "unknown_emoji": fmt.Sprintf(`{"message_id":%q,"emoji":"fake","active":true}`, m.ID)} {
		t.Run(name, func(t *testing.T) {
			_, e := f.s.ExecuteAction(ctx, machineIssuer, machineSubject, run.Context, harness.Action{ID: harness.StableID(run.Context.RunID, name), Type: "reaction.set", Payload: json.RawMessage(payload)})
			require.ErrorIs(t, e, domain.ErrInvalid)
		})
	}
	a := reactionAction(run, "concurrent-native", m.ID, "feishu:OK", true)
	var wg sync.WaitGroup
	errs := make(chan error, 12)
	receipts := make(chan harness.Receipt, 12)
	for i := 0; i < 12; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			r, e := f.s.ExecuteAction(ctx, machineIssuer, machineSubject, run.Context, a)
			errs <- e
			receipts <- r
		}()
	}
	wg.Wait()
	close(errs)
	close(receipts)
	for e := range errs {
		require.NoError(t, e)
	}
	var first harness.Receipt
	for r := range receipts {
		if first.ActionID == "" {
			first = r
		}
		require.Equal(t, first, r)
	}
	require.Equal(t, 1, executionCount(t, f.s, "execution_actions"))
	require.Equal(t, 1, executionCount(t, f.s, "message_reactions"))
	var linked int
	require.NoError(t, f.s.Pool.QueryRow(ctx, "SELECT count(*) FROM transport_outbox WHERE execution_run_id=$1", run.Context.RunID).Scan(&linked))
	require.Equal(t, 1, linked)
	bad := reactionAction(run, "concurrent-native", m.ID, "feishu:OK", false)
	_, err := f.s.ExecuteAction(ctx, machineIssuer, machineSubject, run.Context, bad)
	require.ErrorIs(t, err, domain.ErrConflict)
	page, err := f.s.ExecutionReactionSummaries(ctx, machineIssuer, machineSubject, run.Context.RunID, f.target.ID, m.ID, ReactionQuery{})
	require.NoError(t, err)
	require.True(t, page.Summaries[0].Selected)
	stopped, err := f.s.SetStopped(ctx, f.owner, f.source.ID, "stop-reaction-origin", f.source.Version, true)
	require.NoError(t, err)
	_, err = f.s.ExecuteAction(ctx, machineIssuer, machineSubject, run.Context, a)
	require.ErrorIs(t, err, domain.ErrStopped)
	_, err = f.s.ExecutionReactionSummaries(ctx, machineIssuer, machineSubject, run.Context.RunID, f.target.ID, m.ID, ReactionQuery{})
	require.ErrorIs(t, err, domain.ErrStopped)
	_, err = f.s.ExecutorReactionSummaries(ctx, machineIssuer, machineSubject, f.target.ID, m.ID, ReactionQuery{})
	require.NoError(t, err)
	_, err = f.s.SetStopped(ctx, f.owner, f.source.ID, "resume-reaction-origin", stopped.Version, false)
	require.NoError(t, err)
	_, err = f.s.ExecuteAction(ctx, machineIssuer, machineSubject, run.Context, a)
	require.ErrorIs(t, err, domain.ErrStopped)
}
func TestExecutionReplyAndReactionWorkspaceReadIsolation(t *testing.T) {
	f, m := reactionFixture(t)
	ctx := context.Background()
	run := f.run(t, f.target, "")
	a := messageAction(run, "native-reply", "原生回复")
	a.Payload = json.RawMessage(fmt.Sprintf(`{"content":"原生回复","reply_to":%q}`, m.ID))
	_, err := f.s.ExecuteAction(ctx, machineIssuer, machineSubject, run.Context, a)
	require.NoError(t, err)
	got, err := f.s.ExecutionMessages(ctx, machineIssuer, machineSubject, run.Context.RunID, f.target.ID, 0)
	require.NoError(t, err)
	require.Equal(t, m.ID, got[1].Reply.MessageID)
	other, err := f.s.CreateWorkspace(ctx, f.owner, "other-reaction-workspace", "另一个组织")
	require.NoError(t, err)
	_, err = f.s.Pool.Exec(ctx, "INSERT INTO workspace_members VALUES($1,$2,'member')", other, f.agent)
	require.NoError(t, err)
	room, err := f.s.CreateRoom(ctx, f.owner, "other-reaction-room", other, "另一个群", []string{f.agent})
	require.NoError(t, err)
	msg, err := f.s.Send(ctx, f.owner, room.ID, domain.SendMessage{ActionID: "other-workspace-message", Content: "不可泄露"})
	require.NoError(t, err)
	_, err = f.s.ReactionSummaries(ctx, f.agent, room.ID, msg.Message.ID, ReactionQuery{})
	require.NoError(t, err)
	_, err = f.s.ExecutorReactionSummaries(ctx, machineIssuer, machineSubject, room.ID, msg.Message.ID, ReactionQuery{})
	require.ErrorIs(t, err, domain.ErrForbidden)
	_, err = f.s.ExecutionReactionSummaries(ctx, machineIssuer, machineSubject, run.Context.RunID, room.ID, msg.Message.ID, ReactionQuery{})
	require.ErrorIs(t, err, domain.ErrForbidden)
	_, err = f.s.Pool.Exec(ctx, "DELETE FROM workspace_members WHERE workspace_id=$1 AND principal_id=$2", f.workspace, f.agent)
	require.NoError(t, err)
	_, err = f.s.ExecutorReactionSummaries(ctx, machineIssuer, machineSubject, f.target.ID, m.ID, ReactionQuery{})
	require.ErrorIs(t, err, domain.ErrForbidden)
}

type reactionMessenger struct {
	recordingMessenger
	reactions     []domain.ReactionReceipt
	reactionError error
}

func (p *reactionMessenger) NotifyReaction(_ context.Context, r domain.ReactionReceipt) (transport.Delivery, error) {
	p.reactions = append(p.reactions, r)
	return transport.Delivery{Code: 200}, p.reactionError
}
func clearFixtureTransport(t *testing.T, f executionFixture, p Messenger) {
	t.Helper()
	for i := 0; i < 3; i++ {
		done, e := f.s.DispatchOne(context.Background(), p)
		require.NoError(t, e)
		require.True(t, done)
	}
}
func TestReactionOutboxInvalidationUnknownAndMissingPlugin(t *testing.T) {
	for _, mode := range []string{"success", "unknown", "missing"} {
		t.Run(mode, func(t *testing.T) {
			f, m := reactionFixture(t)
			ctx := context.Background()
			p := &reactionMessenger{}
			clearFixtureTransport(t, f, p)
			p.messages = nil
			_, err := f.s.SetReaction(ctx, f.owner, f.target.ID, m.ID, domain.SetReaction{ActionID: "reaction-notification", Emoji: "feishu:OK", Active: true})
			require.NoError(t, err)
			var messenger Messenger = p
			if mode == "unknown" {
				p.reactionError = errors.New("synthetic provider timeout")
			}
			if mode == "missing" {
				messenger = &recordingMessenger{}
			}
			ok, err := f.s.DispatchOne(ctx, messenger)
			require.NoError(t, err)
			require.True(t, ok)
			state, _ := transportState(t, f.s, f.target.ID, "message.reaction_set")
			want := map[string]string{"success": "delivered", "unknown": "unknown", "missing": "rejected"}[mode]
			require.Equal(t, want, state)
			require.Empty(t, p.messages)
			if mode == "missing" {
				require.Empty(t, messenger.(*recordingMessenger).messages)
				require.Empty(t, p.reactions)
			} else {
				require.Len(t, p.reactions, 1)
			}
			ok, err = f.s.DispatchOne(ctx, messenger)
			require.NoError(t, err)
			require.False(t, ok)
		})
	}
}
func TestExecutionReactionOutboxBlocksAllOriginsAndPolicyChanges(t *testing.T) {
	for _, cause := range []string{"source_stop", "policy_version", "executor_version", "membership"} {
		t.Run(cause, func(t *testing.T) {
			f, m := reactionFixture(t)
			ctx := context.Background()
			p := &reactionMessenger{}
			clearFixtureTransport(t, f, p)
			p.messages = nil
			parent := f.run(t, f.source, "")
			run := f.run(t, f.target, parent.Context.RunID)
			_, err := f.s.ExecuteAction(ctx, machineIssuer, machineSubject, run.Context, reactionAction(run, "before-dispatch", m.ID, "feishu:OK", true))
			require.NoError(t, err)
			switch cause {
			case "source_stop":
				_, err = f.s.SetStopped(ctx, f.owner, f.source.ID, "stop-before-notification", f.source.Version, true)
			case "policy_version":
				_, err = f.s.SetAgentExecutionPolicy(ctx, f.owner, AgentExecutionPolicyCommand{ActionID: "change-before-notification", WorkspaceID: f.workspace, AgentPrincipalID: f.agent, ExpectedVersion: f.b.PolicyVersion, ProactiveEnabled: true})
			case "executor_version":
				_, err = f.s.RegisterExecutor(ctx, f.owner, RegisterExecutorCommand{ActionID: "change-executor-before-notification", WorkspaceID: f.workspace, AgentPrincipalID: f.agent, Issuer: machineIssuer, MachineSubject: machineSubject, ExpectedVersion: f.b.Version, Enabled: true})
			case "membership":
				_, err = f.s.Pool.Exec(ctx, "DELETE FROM room_members WHERE room_id=$1 AND principal_id=$2", f.source.ID, f.agent)
			}
			require.NoError(t, err)
			ok, err := f.s.DispatchOne(ctx, p)
			require.NoError(t, err)
			require.True(t, ok)
			require.Empty(t, p.reactions)
			require.Empty(t, p.messages)
			state, _ := transportState(t, f.s, f.target.ID, "message.reaction_set")
			require.Equal(t, "blocked", state)
			// Confirmed blocked Agent notifications cannot block later human intervention.
			_, err = f.s.Send(ctx, f.owner, f.target.ID, domain.SendMessage{ActionID: "human-after-blocked-reaction", Content: "人类可以继续"})
			require.NoError(t, err)
			ok, err = f.s.DispatchOne(ctx, p)
			require.NoError(t, err)
			require.True(t, ok)
			require.Len(t, p.messages, 1)
		})
	}
}
