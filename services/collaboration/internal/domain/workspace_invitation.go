package domain

import (
	"errors"
	"time"
)

var (
	ErrInvitationNotFound = errors.New("invitation_not_found")
	ErrInvitationExpired  = errors.New("invitation_expired")
	ErrInvitationRevoked  = errors.New("invitation_revoked")
	ErrInvitationUsed     = errors.New("invitation_used")
)

type WorkspaceInvitation struct {
	ID             string     `json:"id"`
	WorkspaceID    string     `json:"workspace_id"`
	CreatedBy      string     `json:"created_by"`
	CreateActionID string     `json:"create_action_id"`
	Role           string     `json:"role"`
	Status         string     `json:"status"`
	CreatedAt      time.Time  `json:"created_at"`
	ExpiresAt      time.Time  `json:"expires_at"`
	AcceptedBy     string     `json:"accepted_by,omitempty"`
	AcceptedAt     *time.Time `json:"accepted_at,omitempty"`
	RevokedAt      *time.Time `json:"revoked_at,omitempty"`
	IssuedRunID    string     `json:"issued_run_id,omitempty"`
}

type CreateWorkspaceInvitation struct {
	ActionID         string `json:"action_id"`
	ExpiresInSeconds int64  `json:"expires_in_seconds,omitempty"`
	RunID            string `json:"run_id,omitempty"`
}

type RevokeWorkspaceInvitation struct {
	ActionID string `json:"action_id"`
	RunID    string `json:"run_id,omitempty"`
}

type AcceptWorkspaceInvitation struct {
	ActionID string `json:"action_id"`
	Code     string `json:"code"`
	RunID    string `json:"run_id,omitempty"`
}

// Code is a one-response secret. Stored actions, events and execution receipts
// always use a copy with Code empty and CodeAvailable false.
type InvitationReceipt struct {
	Invitation             WorkspaceInvitation `json:"invitation"`
	Code                   string              `json:"code,omitempty"`
	CodeAvailable          bool                `json:"code_available"`
	WorkspaceID            string              `json:"workspace_id"`
	PrincipalID            string              `json:"principal_id"`
	Role                   string              `json:"role"`
	AlreadyMember          bool                `json:"already_member"`
	ExecutionScopeExtended bool                `json:"execution_scope_extended"`
	Replayed               bool                `json:"replayed"`
}

type InvitationPage struct {
	Invitations []WorkspaceInvitation `json:"invitations"`
	Cursor      string                `json:"cursor"`
}

type InvitationActionReceipt struct {
	ActionID string            `json:"action_id"`
	Kind     string            `json:"kind"`
	Receipt  InvitationReceipt `json:"receipt"`
}
