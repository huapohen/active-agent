package httpapi

import (
	"errors"
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/huapohen/active-agent/services/collaboration/internal/auth"
	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/huapohen/active-agent/services/collaboration/internal/emoji"
	"github.com/huapohen/active-agent/services/collaboration/internal/store"
	"github.com/huapohen/active-agent/services/collaboration/internal/transport"
)

type Option func(*config)
type config struct {
	machine                 auth.MachineVerifier
	transportTestPrincipals map[string]bool
	emoji                   emoji.Provider
	rongCloudBridges        []transport.BridgeBinding
}

func WithRongCloudBridges(bindings []transport.BridgeBinding) Option {
	return func(c *config) { c.rongCloudBridges = append([]transport.BridgeBinding(nil), bindings...) }
}

func WithMachineVerifier(v auth.MachineVerifier) Option { return func(c *config) { c.machine = v } }

// The catalog is selected once at service composition, shared with reaction
// validation, and is never an alternate identity or legacy API connection.
func WithEmojiProvider(p emoji.Provider) Option { return func(c *config) { c.emoji = p } }

// Ordinary RongCloud credentials currently permit SDK writes outside the Go
// authorization gateway. Until provider-side closure is verified, issue client
// tokens only to explicitly named isolated test principals, never generally.
func WithTransportTestPrincipals(ids []string) Option {
	return func(c *config) {
		c.transportTestPrincipals = map[string]bool{}
		for _, id := range ids {
			if validID(id) {
				c.transportTestPrincipals[id] = true
			}
		}
	}
}

func New(s *store.Store, v auth.Verifier, r *transport.RongCloud, origins []string, options ...Option) *gin.Engine {
	cfg := config{}
	for _, option := range options {
		option(&cfg)
	}
	// One Store belongs to one deployment composition. Explicit removal must
	// clear a previously installed validator, including internal action routes.
	s.SetReactionEmojiValidator(cfg.emoji)
	gin.SetMode(gin.ReleaseMode)
	g := gin.New()
	g.SetTrustedProxies(nil)
	g.Use(func(c *gin.Context) {
		defer func() {
			if recover() != nil {
				c.AbortWithStatusJSON(500, gin.H{"error": "internal_error"})
			}
		}()
		c.Header("Cache-Control", "no-store")
		c.Header("X-Content-Type-Options", "nosniff")
		if origin := c.GetHeader("Origin"); origin != "" {
			allowed := false
			for _, o := range origins {
				if origin == o {
					allowed = true
				}
			}
			if !allowed {
				c.AbortWithStatusJSON(403, gin.H{"error": "origin_not_allowed"})
				return
			}
			c.Header("Access-Control-Allow-Origin", origin)
			c.Header("Vary", "Origin")
			c.Header("Access-Control-Allow-Headers", "Authorization, Content-Type, MCP-Protocol-Version, If-Match, If-None-Match")
			c.Header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
		}
		if c.Request.Method == "OPTIONS" {
			c.AbortWithStatus(204)
			return
		}
		limit := int64(64 << 10)
		if c.Request.URL.Path == "/internal/harness/events" {
			limit = 2 << 20
		}
		c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, limit)
		c.Next()
	})
	g.GET("/healthz", func(c *gin.Context) {
		c.JSON(200, gin.H{"service": "renji-collaboration", "protocol": "renji.v1", "transport": "rongcloud"})
	})
	v1 := g.Group("/v1")
	v1.Use(func(c *gin.Context) {
		h := c.GetHeader("Authorization")
		if !strings.HasPrefix(h, "Bearer ") {
			c.AbortWithStatusJSON(401, gin.H{"error": "unauthenticated"})
			return
		}
		if strings.HasPrefix(h, "Bearer mt_") {
			machineAuth(s, cfg.machine)(c)
			return
		}
		identity, err := v.Verify(c.Request.Context(), strings.TrimPrefix(h, "Bearer "))
		if err != nil {
			c.AbortWithStatusJSON(401, gin.H{"error": "unauthenticated"})
			return
		}
		p, err := s.ResolveIdentity(c.Request.Context(), identity.Issuer, identity.Subject)
		if err != nil {
			fail(c, err)
			c.Abort()
			return
		}
		c.Set("principal", p)
		c.Next()
	})
	mountNative(v1, s, cfg)
	mountEmoji(v1, s, cfg.emoji)
	mountMessageInteractions(v1, s, cfg)
	mountProfileWorkspace(v1, s)
	mountWorkspaceInvitations(v1, s)
	if err := MountRongCloudIngress(g, v1, s, cfg.rongCloudBridges); err != nil {
		panic("invalid RongCloud receiver configuration")
	}
	mountExecution(g, v1, s, cfg)
	v1.GET("/me", func(c *gin.Context) { c.JSON(200, gin.H{"principal": principal(c)}) })
	v1.POST("/workspaces", func(c *gin.Context) {
		if denyUnscopedMachineMutation(c) {
			return
		}
		var q struct {
			ActionID string `json:"action_id"`
			Title    string `json:"title"`
		}
		if !strictBody(c, &q) {
			return
		}
		q.Title = strings.TrimSpace(q.Title)
		id, err := s.CreateWorkspace(c.Request.Context(), principal(c).ID, q.ActionID, q.Title)
		if err != nil {
			fail(c, err)
			return
		}
		c.JSON(201, gin.H{"workspace": gin.H{"id": id, "title": q.Title}})
	})
	v1.GET("/rooms", func(c *gin.Context) {
		after := c.Query("after")
		if after != "" && !validID(after) {
			fail(c, domain.ErrInvalid)
			return
		}
		rooms, err := nativeRooms(c, s, after, c.Query("run_id"))
		if err != nil {
			fail(c, err)
			return
		}
		c.JSON(200, roomListPage(rooms))
	})
	v1.POST("/rooms", func(c *gin.Context) {
		if denyUnscopedMachineMutation(c) {
			return
		}
		var q struct {
			ActionID    string   `json:"action_id"`
			WorkspaceID string   `json:"workspace_id"`
			Title       string   `json:"title"`
			Members     []string `json:"members"`
		}
		if !strictBody(c, &q) {
			return
		}
		if !validID(q.WorkspaceID) {
			fail(c, domain.ErrInvalid)
			return
		}
		for _, m := range q.Members {
			if !validID(m) {
				fail(c, domain.ErrInvalid)
				return
			}
		}
		room, err := s.CreateRoom(c.Request.Context(), principal(c).ID, q.ActionID, q.WorkspaceID, q.Title, q.Members)
		if err != nil {
			fail(c, err)
			return
		}
		c.JSON(201, gin.H{"room": room})
	})
	v1.GET("/rooms/:room/messages", func(c *gin.Context) {
		q, err := readMessageQuery(c.Request.URL.Query())
		if err != nil || !validID(c.Param("room")) {
			fail(c, domain.ErrInvalid)
			return
		}
		page, err := messagePage(c, s, c.Param("room"), q, c.Query("run_id"))
		if err != nil {
			fail(c, err)
			return
		}
		c.JSON(200, page)
	})
	v1.POST("/rooms/:room/messages", func(c *gin.Context) {
		var q struct {
			domain.SendMessage
			RunID string `json:"run_id"`
		}
		if !validID(c.Param("room")) {
			fail(c, domain.ErrInvalid)
			return
		}
		if !strictBody(c, &q) {
			return
		}
		receipt, err := nativeSend(c, s, c.Param("room"), q.SendMessage, q.RunID)
		if err != nil {
			fail(c, err)
			return
		}
		c.JSON(200, receipt)
	})
	v1.POST("/rooms/:room/execution-policy", func(c *gin.Context) {
		if denyUnscopedMachineMutation(c) {
			return
		}
		var q struct {
			ActionID string `json:"action_id"`
			Version  int64  `json:"expected_version"`
			Stopped  *bool  `json:"stopped"`
		}
		if !validID(c.Param("room")) || c.ShouldBindJSON(&q) != nil || q.Stopped == nil {
			fail(c, domain.ErrInvalid)
			return
		}
		r, err := s.SetStopped(c.Request.Context(), principal(c).ID, c.Param("room"), q.ActionID, q.Version, *q.Stopped)
		if err != nil {
			fail(c, err)
			return
		}
		c.JSON(200, gin.H{"room": r})
	})
	v1.POST("/transport/rongcloud/session", func(c *gin.Context) {
		if !cfg.transportTestPrincipals[principal(c).ID] {
			c.JSON(503, gin.H{"error": "rongcloud_client_write_policy_unverified"})
			return
		}
		if r == nil {
			c.JSON(503, gin.H{"error": "rongcloud_not_configured"})
			return
		}
		session, err := r.Session(c.Request.Context(), principal(c))
		if err != nil {
			c.JSON(502, gin.H{"error": "rongcloud_unavailable"})
			return
		}
		c.JSON(200, session)
	})
	return g
}
func principal(c *gin.Context) domain.Principal { return c.MustGet("principal").(domain.Principal) }
func validID(s string) bool                     { _, err := uuid.Parse(s); return err == nil }
func safeError(err error) (int, string) {
	code := 500
	message := "internal_error"
	switch {
	case errors.Is(err, domain.ErrForbidden):
		code = 403
		message = "forbidden"
	case errors.Is(err, domain.ErrInvalid):
		code = 400
		message = "invalid_request"
	case errors.Is(err, domain.ErrInvitationNotFound):
		code = 404
		message = "invitation_not_found"
	case errors.Is(err, domain.ErrInvitationExpired):
		code = 410
		message = "invitation_expired"
	case errors.Is(err, domain.ErrInvitationRevoked):
		code = 410
		message = "invitation_revoked"
	case errors.Is(err, domain.ErrInvitationUsed):
		code = 409
		message = "invitation_used"
	case errors.Is(err, domain.ErrProfileVersionConflict):
		code = 409
		message = "profile_version_conflict"
	case errors.Is(err, domain.ErrProfileBusy):
		code = 503
		message = "profile_update_busy"
	case errors.Is(err, domain.ErrConflict):
		code = 409
		message = "action_conflict"
	case errors.Is(err, domain.ErrStopped):
		code = 409
		message = "scope_stopped_or_stale"
	case errors.Is(err, errEmojiUnavailable):
		code = 503
		message = "emoji_catalog_unavailable"
	case errors.Is(err, emoji.ErrInvalidQuery):
		code = 400
		message = "invalid_emoji_query"
	case errors.Is(err, emoji.ErrRevisionChanged):
		code = 409
		message = "emoji_revision_changed"
	case errors.Is(err, emoji.ErrUnknownEmoji), errors.Is(err, emoji.ErrAssetNotFound):
		code = 404
		message = "emoji_not_found"
	}
	return code, message
}
func fail(c *gin.Context, err error) {
	code, message := safeError(err)
	c.JSON(code, gin.H{"error": message})
}
