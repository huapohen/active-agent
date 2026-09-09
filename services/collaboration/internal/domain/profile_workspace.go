package domain

import "time"

// Profile versions are separate from identity and room execution versions.
// A display name never changes the authenticated principal or its roles.
type Profile struct {
	Principal Principal `json:"principal"`
	Version   int64     `json:"version"`
}

type UpdateProfile struct {
	ActionID        string `json:"action_id"`
	DisplayName     string `json:"display_name"`
	ExpectedVersion int64  `json:"expected_version"`
}

type ProfileReceipt struct {
	Profile
	Replayed bool `json:"replayed"`
}

type Workspace struct {
	ID        string    `json:"id"`
	Title     string    `json:"title"`
	Role      string    `json:"role"`
	CreatedAt time.Time `json:"created_at"`
}

type WorkspacePage struct {
	Workspaces []Workspace `json:"workspaces"`
	Cursor     string      `json:"cursor"`
}

type Member struct {
	PrincipalID string `json:"principal_id"`
	Kind        string `json:"kind"`
	DisplayName string `json:"display_name"`
	Role        string `json:"role"`
}

type MemberPage struct {
	Members []Member `json:"members"`
	Cursor  string   `json:"cursor"`
}
