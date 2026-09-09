package httpapi

import (
	"bytes"
	"encoding/json"

	"github.com/gin-gonic/gin"
	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/huapohen/active-agent/services/collaboration/internal/store"
)

// HTTP and MCP share these verified identity and transaction entry points.
func nativeWorkspaceInvitationCreate(c *gin.Context, s *store.Store, workspace string, cmd domain.CreateWorkspaceInvitation) (domain.InvitationReceipt, error) {
	return s.CreateWorkspaceInvitation(c.Request.Context(), accountReader(c), workspace, cmd)
}
func nativeWorkspaceInvitationRevoke(c *gin.Context, s *store.Store, workspace, id string, cmd domain.RevokeWorkspaceInvitation) (domain.InvitationReceipt, error) {
	return s.RevokeWorkspaceInvitation(c.Request.Context(), accountReader(c), workspace, id, cmd)
}
func nativeWorkspaceInvitationAccept(c *gin.Context, s *store.Store, cmd domain.AcceptWorkspaceInvitation) (domain.InvitationReceipt, error) {
	return s.AcceptWorkspaceInvitation(c.Request.Context(), accountReader(c), cmd)
}
func nativeWorkspaceInvitationList(c *gin.Context, s *store.Store, workspace string, q store.AccountQuery) (domain.InvitationPage, error) {
	return s.WorkspaceInvitations(c.Request.Context(), accountReader(c), workspace, q)
}
func nativeWorkspaceInvitationAction(c *gin.Context, s *store.Store, action, runID string) (domain.InvitationActionReceipt, error) {
	return s.ReadWorkspaceInvitationAction(c.Request.Context(), accountReader(c), action, runID)
}

// Retain JSON presence: omitted TTL defaults, but null or explicit zero must
// not silently become a default. The ordinary decoder cannot distinguish them.
func strictInvitationBody(c *gin.Context, out any) bool {
	var raw json.RawMessage
	if !strictBody(c, &raw) {
		return false
	}
	var fields map[string]json.RawMessage
	if json.Unmarshal(raw, &fields) != nil || fields == nil {
		fail(c, domain.ErrInvalid)
		return false
	}
	for _, v := range fields {
		if bytes.Equal(bytes.TrimSpace(v), []byte("null")) {
			fail(c, domain.ErrInvalid)
			return false
		}
	}
	if raw, ok := fields["expires_in_seconds"]; ok {
		var n int64
		if json.Unmarshal(raw, &n) != nil || n < 60 || n > 604800 {
			fail(c, domain.ErrInvalid)
			return false
		}
	}
	if raw, ok := fields["run_id"]; ok {
		if _, isMachine := machine(c); !isMachine {
			fail(c, domain.ErrInvalid)
			return false
		}
		var id string
		if json.Unmarshal(raw, &id) != nil || !validID(id) {
			fail(c, domain.ErrInvalid)
			return false
		}
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if decoder.Decode(out) != nil {
		fail(c, domain.ErrInvalid)
		return false
	}
	return true
}
func mountWorkspaceInvitations(v1 *gin.RouterGroup, s *store.Store) {
	v1.POST("/workspaces/:workspace/invitations", func(c *gin.Context) {
		c.Header("Cache-Control", "no-store")
		if len(c.Request.URL.Query()) != 0 {
			fail(c, domain.ErrInvalid)
			return
		}
		var cmd domain.CreateWorkspaceInvitation
		if !strictInvitationBody(c, &cmd) {
			return
		}
		out, e := nativeWorkspaceInvitationCreate(c, s, c.Param("workspace"), cmd)
		if e != nil {
			fail(c, e)
			return
		}
		c.JSON(200, out)
	})
	v1.GET("/workspaces/:workspace/invitations", func(c *gin.Context) {
		c.Header("Cache-Control", "no-store")
		if _, isMachine := machine(c); !isMachine && c.Request.URL.Query().Has("run_id") {
			fail(c, domain.ErrInvalid)
			return
		}
		q, e := readAccountQuery(c.Request.URL.Query())
		if e != nil {
			fail(c, e)
			return
		}
		out, e := nativeWorkspaceInvitationList(c, s, c.Param("workspace"), q)
		if e != nil {
			fail(c, e)
			return
		}
		c.JSON(200, out)
	})
	v1.POST("/workspaces/:workspace/invitations/:invitation/revoke", func(c *gin.Context) {
		c.Header("Cache-Control", "no-store")
		if len(c.Request.URL.Query()) != 0 {
			fail(c, domain.ErrInvalid)
			return
		}
		var cmd domain.RevokeWorkspaceInvitation
		if !strictInvitationBody(c, &cmd) {
			return
		}
		out, e := nativeWorkspaceInvitationRevoke(c, s, c.Param("workspace"), c.Param("invitation"), cmd)
		if e != nil {
			fail(c, e)
			return
		}
		c.JSON(200, out)
	})
	v1.POST("/workspace-invitations/accept", func(c *gin.Context) {
		c.Header("Cache-Control", "no-store")
		if len(c.Request.URL.Query()) != 0 {
			fail(c, domain.ErrInvalid)
			return
		}
		var cmd domain.AcceptWorkspaceInvitation
		if !strictInvitationBody(c, &cmd) {
			return
		}
		out, e := nativeWorkspaceInvitationAccept(c, s, cmd)
		if e != nil {
			fail(c, e)
			return
		}
		c.JSON(200, out)
	})
	v1.GET("/workspace-invitation-actions/:action", func(c *gin.Context) {
		c.Header("Cache-Control", "no-store")
		if _, isMachine := machine(c); !isMachine && c.Request.URL.Query().Has("run_id") {
			fail(c, domain.ErrInvalid)
			return
		}
		if !allowedQuery(c.Request.URL.Query(), "run_id") {
			fail(c, domain.ErrInvalid)
			return
		}
		out, e := nativeWorkspaceInvitationAction(c, s, c.Param("action"), c.Query("run_id"))
		if e != nil {
			fail(c, e)
			return
		}
		c.JSON(200, out)
	})
}
