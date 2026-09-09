package transport

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/url"
	"slices"
	"time"

	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
)

// GroupWritePolicyObservation is evidence about two specific provider settings,
// never a read-only token grant or a complete SDK authorization policy. Repeated
// reads detect observed drift but the provider supplies no atomic policy epoch.
type GroupWritePolicyObservation struct {
	Schema             string    `json:"schema"`
	GroupID            string    `json:"group_id"`
	StartedAt          time.Time `json:"started_at"`
	CompletedAt        time.Time `json:"completed_at"`
	GroupMuted         bool      `json:"group_muted"`
	WhitelistIDs       []string  `json:"whitelist_ids"`
	RepeatedReadsEqual bool      `json:"repeated_reads_equal"`
	ResponseSHA256     []string  `json:"response_sha256"`
	DirectClientSafe   bool      `json:"direct_client_safe"`
	UnverifiedPaths    []string  `json:"unverified_paths"`
}

var ErrPolicyChanged = errors.New("rongcloud_policy_changed_during_read")

// ReadGroupWritePolicy performs four read-only API calls, always scoped to one
// explicit group. No pagination parameter is sent: RongCloud documents that
// page/size would make groupId ineffective and return app-wide information.
//
// https://docs.rongcloud.cn/platform-chat-api/group/mute/query-banned-state-or-list
// https://docs.rongcloud.cn/platform-chat-api/group/mute/query-group-ban-whitelist
func (r *RongCloud) ReadGroupWritePolicy(ctx context.Context, groupID string) (GroupWritePolicyObservation, error) {
	if err := ctx.Err(); err != nil {
		return GroupWritePolicyObservation{}, err
	}
	if !reactionTransportID(groupID) {
		return GroupWritePolicyObservation{}, domain.ErrInvalid
	}
	started := time.Now().UTC()
	muted, h1, err := r.readGroupBan(ctx, groupID)
	if err != nil {
		return GroupWritePolicyObservation{}, err
	}
	ids, h2, err := r.readGroupWhitelist(ctx, groupID)
	if err != nil {
		return GroupWritePolicyObservation{}, err
	}
	mutedAfter, h3, err := r.readGroupBan(ctx, groupID)
	if err != nil {
		return GroupWritePolicyObservation{}, err
	}
	idsAfter, h4, err := r.readGroupWhitelist(ctx, groupID)
	if err != nil {
		return GroupWritePolicyObservation{}, err
	}
	if muted != mutedAfter || !slices.Equal(ids, idsAfter) {
		return GroupWritePolicyObservation{}, ErrPolicyChanged
	}
	return GroupWritePolicyObservation{
		Schema: "renji.rongcloud.group-policy-observation.v1", GroupID: groupID,
		StartedAt: started, CompletedAt: time.Now().UTC(), GroupMuted: muted,
		WhitelistIDs: ids, RepeatedReadsEqual: true,
		ResponseSHA256: []string{h1, h2, h3, h4}, DirectClientSafe: false,
		UnverifiedPaths: []string{"private_send", "group_command_and_state", "recall", "modify", "reaction", "expansion", "hosted_group_mutation", "conversation_and_read_state", "other_conversation_types", "policy_revocation_atomicity"},
	}, nil
}

func (r *RongCloud) readGroupBan(ctx context.Context, groupID string) (bool, string, error) {
	var raw json.RawMessage
	if err := r.post(ctx, "/group/ban/query.json", url.Values{"groupId": {groupID}}, &raw); err != nil {
		return false, "", err
	}
	var result struct {
		GroupInfo []struct {
			GroupID string `json:"groupId"`
			Stat    *int   `json:"stat"`
		} `json:"groupinfo"`
	}
	if json.Unmarshal(raw, &result) != nil || len(result.GroupInfo) != 1 {
		return false, "", &ProviderError{Code: 200, Unknown: true}
	}
	item := result.GroupInfo[0]
	if item.GroupID != groupID || item.Stat == nil || (*item.Stat != 0 && *item.Stat != 1) {
		return false, "", &ProviderError{Code: 200, Unknown: true}
	}
	return *item.Stat == 1, policyHash(raw), nil
}

func (r *RongCloud) readGroupWhitelist(ctx context.Context, groupID string) ([]string, string, error) {
	var raw json.RawMessage
	if err := r.post(ctx, "/group/user/ban/whitelist/query.json", url.Values{"groupId": {groupID}}, &raw); err != nil {
		return nil, "", err
	}
	var result struct {
		UserIDs []string `json:"userIds"`
	}
	if json.Unmarshal(raw, &result) != nil || result.UserIDs == nil || len(result.UserIDs) > 3000 {
		return nil, "", &ProviderError{Code: 200, Unknown: true}
	}
	slices.Sort(result.UserIDs)
	for i, id := range result.UserIDs {
		if !reactionTransportID(id) || (i > 0 && id == result.UserIDs[i-1]) {
			return nil, "", &ProviderError{Code: 200, Unknown: true}
		}
	}
	return result.UserIDs, policyHash(raw), nil
}

func policyHash(raw []byte) string { h := sha256.Sum256(raw); return hex.EncodeToString(h[:]) }
