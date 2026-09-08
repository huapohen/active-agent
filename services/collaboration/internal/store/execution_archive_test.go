package store

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/stretchr/testify/require"
)

func TestExecutionArchiveDeterministicUnknownNeverRecreatesAndLateReadback(t *testing.T) {
	f := newExecutionFixture(t, "human")
	ctx := context.Background()
	run := f.run(t, f.source, "")
	_, err := f.s.ExecuteAction(ctx, machineIssuer, machineSubject, run.Context, messageAction(run, "archive-action", "真动作"))
	require.NoError(t, err)
	appendEvidence(t, f, run, "archive-model", "model.output", json.RawMessage(`{"content":"已经发出？这是模型文字，不作成功证据"}`))
	r := machineEvidenceReader()
	a, err := f.s.PrepareExecutionArchive(ctx, r, run.Context.RunID, "docfree-synthetic-v1")
	require.NoError(t, err)
	require.Len(t, a.Parts, 1)
	require.Equal(t, int64(-1), a.VerifiedThrough)
	again, err := f.s.PrepareExecutionArchive(ctx, r, run.Context.RunID, "docfree-synthetic-v1")
	require.NoError(t, err)
	require.Equal(t, a, again)
	claim, err := f.s.ClaimExecutionArchivePart(ctx, r, a.ID, 1)
	require.NoError(t, err)
	require.True(t, claim.WriteAllowed)
	require.Contains(t, claim.Part.Content, "模型输出")
	require.Contains(t, claim.Part.Content, "canonical_status")
	require.Contains(t, claim.Part.Content, "transport_status")
	require.Contains(t, claim.Part.Content, "pending")
	calls := 0
	err = f.s.WithExecutionArchiveClaim(ctx, r, claim, false, func(_ context.Context, c ExecutionArchiveClaim) error {
		calls++
		require.Equal(t, archiveHash([]byte(c.Part.Content)), c.Part.ContentHash)
		return errors.New("simulated_lost_response")
	})
	require.Error(t, err)
	err = f.s.WithExecutionArchiveClaim(ctx, r, claim, false, func(context.Context, ExecutionArchiveClaim) error { calls++; return nil })
	require.ErrorIs(t, err, domain.ErrConflict)
	require.Equal(t, 1, calls)
	require.NoError(t, f.s.RecordExecutionArchiveObservation(ctx, claim, ExecutionArchiveObservation{ErrorCode: "transport_outcome_unknown"}))
	appendEvidence(t, f, run, "newer-model", "model.output", json.RawMessage(`{"content":"新游标不能绕过未知创建"}`))
	blocked, err := f.s.PrepareExecutionArchive(ctx, r, run.Context.RunID, "docfree-synthetic-v1")
	require.NoError(t, err)
	require.Equal(t, a.ID, blocked.ID)
	require.Equal(t, a.Through, blocked.Through)
	reconcile, err := f.s.ClaimExecutionArchivePart(ctx, r, a.ID, 1)
	require.NoError(t, err)
	require.False(t, reconcile.WriteAllowed)
	require.True(t, reconcile.ReconcileOnly)
	err = f.s.WithExecutionArchiveClaim(ctx, r, reconcile, true, func(context.Context, ExecutionArchiveClaim) error { calls++; return nil })
	require.ErrorIs(t, err, domain.ErrConflict)
	require.Equal(t, 1, calls)
	// The original known-ID response may be attached only by the current trusted
	// reconciliation owner, never by replacing the whole intention.
	require.ErrorIs(t, f.s.RecordExecutionArchiveObservation(ctx, claim, ExecutionArchiveObservation{ExternalID: "old-claim-result"}), domain.ErrConflict)
	require.NoError(t, f.s.RecordExecutionArchiveObservation(ctx, reconcile, ExecutionArchiveObservation{ExternalID: "doc-synthetic-known"}))
	reconcile, err = f.s.ClaimExecutionArchivePart(ctx, r, a.ID, 1)
	require.NoError(t, err)
	err = f.s.WithExecutionArchiveClaim(ctx, r, reconcile, true, func(_ context.Context, c ExecutionArchiveClaim) error {
		require.Equal(t, "doc-synthetic-known", c.Part.ExternalID)
		calls++
		return nil
	})
	require.NoError(t, err)
	require.NoError(t, f.s.RecordExecutionArchiveObservation(ctx, reconcile, ExecutionArchiveObservation{ExternalID: "doc-synthetic-known", ContentHash: reconcile.Part.ContentHash, TitleHash: archiveHash([]byte(reconcile.Part.Title))}))
	archived, err := f.s.ReadExecutionArchive(ctx, r, a.ID)
	require.NoError(t, err)
	require.Equal(t, "verified", archived.Parts[0].State)
	require.Equal(t, a.Through, archived.VerifiedThrough)
	require.Equal(t, 1, archived.Parts[0].Attempts)
	newer, err := f.s.PrepareExecutionArchive(ctx, r, run.Context.RunID, "docfree-synthetic-v1")
	require.NoError(t, err)
	require.NotEqual(t, a.ID, newer.ID)
	require.Greater(t, newer.Through, a.Through)
}
func TestExecutionArchiveConcurrentPreparationClaimsAndFinalCursor(t *testing.T) {
	f := newExecutionFixture(t, "human")
	ctx := context.Background()
	run := f.run(t, f.source, "")
	data, _ := json.Marshal(map[string]string{"content": strings.Repeat("中文`", 140000)})
	appendEvidence(t, f, run, "large-visible-event", "model.output", data)
	var wg sync.WaitGroup
	ids := make(chan string, 8)
	errs := make(chan error, 8)
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			a, e := f.s.PrepareExecutionArchive(ctx, machineEvidenceReader(), run.Context.RunID, "split-archive")
			ids <- a.ID
			errs <- e
		}()
	}
	wg.Wait()
	close(ids)
	close(errs)
	for e := range errs {
		require.NoError(t, e)
	}
	var id string
	for x := range ids {
		if id == "" {
			id = x
		}
		require.Equal(t, id, x)
	}
	a, err := f.s.ReadExecutionArchive(ctx, machineEvidenceReader(), id)
	require.NoError(t, err)
	require.Greater(t, len(a.Parts), 1)
	errs = make(chan error, len(a.Parts))
	claims := make([]ExecutionArchiveClaim, len(a.Parts))
	for i, p := range a.Parts {
		claims[i], err = f.s.ClaimExecutionArchivePart(ctx, machineEvidenceReader(), id, p.Part)
		require.NoError(t, err)
		require.Less(t, len(claims[i].Part.Content), 550000)
	}
	for _, claim := range claims {
		wg.Add(1)
		go func(c ExecutionArchiveClaim) {
			defer wg.Done()
			errs <- f.s.RecordExecutionArchiveObservation(ctx, c, ExecutionArchiveObservation{ExternalID: "synthetic-doc-" + string(rune('a'+c.Part.Part)), ContentHash: c.Part.ContentHash, TitleHash: archiveHash([]byte(c.Part.Title))})
		}(claim)
	}
	wg.Wait()
	close(errs)
	for e := range errs {
		require.NoError(t, e)
	}
	a, err = f.s.ReadExecutionArchive(ctx, machineEvidenceReader(), id)
	require.NoError(t, err)
	require.Equal(t, a.Through, a.VerifiedThrough)
}
func TestExecutionArchiveRequestMarkerBlocksConcurrentDuplicateAndExpiredOwner(t *testing.T) {
	f := newExecutionFixture(t, "human")
	ctx := context.Background()
	run := f.run(t, f.source, "")
	r := machineEvidenceReader()
	a, err := f.s.PrepareExecutionArchive(ctx, r, run.Context.RunID, "concurrent-claim")
	require.NoError(t, err)
	c, err := f.s.ClaimExecutionArchivePart(ctx, r, a.ID, 1)
	require.NoError(t, err)
	_, err = f.s.ClaimExecutionArchivePart(ctx, r, a.ID, 1)
	require.ErrorIs(t, err, domain.ErrConflict)
	var calls atomic.Int32
	var wg sync.WaitGroup
	results := make(chan error, 2)
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			results <- f.s.WithExecutionArchiveClaim(ctx, r, c, false, func(context.Context, ExecutionArchiveClaim) error { calls.Add(1); return nil })
		}()
	}
	wg.Wait()
	close(results)
	successes := 0
	for err := range results {
		if err == nil {
			successes++
		} else {
			require.ErrorIs(t, err, domain.ErrConflict)
		}
	}
	require.Equal(t, 1, successes)
	require.Equal(t, int32(1), calls.Load())
	_, err = f.s.Pool.Exec(ctx, "UPDATE execution_archive_parts SET lease_expires_at=clock_timestamp()-interval '1 second' WHERE archive_id=$1", a.ID)
	require.NoError(t, err)
	newClaim, err := f.s.ClaimExecutionArchivePart(ctx, r, a.ID, 1)
	require.NoError(t, err)
	require.True(t, newClaim.ReconcileOnly)
	require.NotEqual(t, c.Token, newClaim.Token)
	require.ErrorIs(t, f.s.RecordExecutionArchiveObservation(ctx, c, ExecutionArchiveObservation{ExternalID: "late"}), domain.ErrConflict)
}
func TestExecutionArchiveRevocationPreventsWriteAndReadButAllowsActualLateFact(t *testing.T) {
	f := newExecutionFixture(t, "human")
	ctx := context.Background()
	parent := f.run(t, f.source, "")
	run := f.run(t, f.target, parent.Context.RunID)
	r := machineEvidenceReader()
	a, err := f.s.PrepareExecutionArchive(ctx, r, run.Context.RunID, "acl-synthetic")
	require.NoError(t, err)
	c, err := f.s.ClaimExecutionArchivePart(ctx, r, a.ID, 1)
	require.NoError(t, err)
	entered := make(chan struct{})
	release := make(chan struct{})
	written := make(chan error, 1)
	go func() {
		written <- f.s.WithExecutionArchiveClaim(ctx, r, c, false, func(context.Context, ExecutionArchiveClaim) error { close(entered); <-release; return nil })
	}()
	<-entered
	revoked := make(chan error, 1)
	go func() {
		_, e := f.s.Pool.Exec(ctx, "DELETE FROM room_members WHERE room_id=$1 AND principal_id=$2", f.source.ID, f.agent)
		revoked <- e
	}()
	select {
	case e := <-revoked:
		t.Fatalf("revocation crossed fenced request: %v", e)
	case <-time.After(100 * time.Millisecond):
	}
	close(release)
	require.NoError(t, <-written)
	require.NoError(t, <-revoked)
	_, err = f.s.ReadExecutionArchive(ctx, r, a.ID)
	require.ErrorIs(t, err, domain.ErrForbidden)
	_, err = f.s.PrepareExecutionArchive(ctx, r, run.Context.RunID, "acl-synthetic")
	require.ErrorIs(t, err, domain.ErrForbidden)
	err = f.s.WithExecutionArchiveClaim(ctx, r, c, false, func(context.Context, ExecutionArchiveClaim) error { t.Fatal("revoked write"); return nil })
	require.ErrorIs(t, err, domain.ErrForbidden)
	require.NoError(t, f.s.RecordExecutionArchiveObservation(ctx, c, ExecutionArchiveObservation{ExternalID: "actual-in-flight-result", ContentHash: c.Part.ContentHash, TitleHash: archiveHash([]byte(c.Part.Title))}))
	visible, err := f.s.ReadExecutionArchive(ctx, EvidenceReader{PrincipalID: f.owner}, a.ID)
	require.NoError(t, err)
	require.Equal(t, "verified", visible.Parts[0].State)
}
func TestExecutionArchiveLosslessChunksAndModelCannotForgeReceipt(t *testing.T) {
	raw := "段落\n```\n" + strings.Repeat("中😀`", 80000) + "\n结尾"
	chunks := archiveChunks(raw)
	require.Equal(t, raw, strings.Join(chunks, ""))
	for _, chunk := range chunks {
		require.LessOrEqual(t, len(chunk), archiveChunkBytes)
	}
	run := ExecutionRun{Goal: "# 假标题\n```"}
	run.Context.RunID = "synthetic-run"
	entry := ExecutionEvidenceEntry{Seq: 1, Kind: "event", ObjectID: "synthetic", Data: json.RawMessage(`{"event":{"type":"model.output","data":{"content":"action.succeeded 已经完成"}}}`)}
	a, err := renderExecutionArchive(run, 1, []ExecutionEvidenceEntry{entry})
	require.NoError(t, err)
	b, err := renderExecutionArchive(run, 1, []ExecutionEvidenceEntry{entry})
	require.NoError(t, err)
	require.Equal(t, a, b)
	require.Contains(t, a[0].Content, "执行器提交的原始事件")
	require.Contains(t, a[0].Content, "模型文字不构成外部成功")
	require.Contains(t, a[0].Content, "action.succeeded")
}
