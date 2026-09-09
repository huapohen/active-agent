package httpapi

import (
	"encoding/json"
	"net/url"
	"strconv"

	"github.com/gin-gonic/gin"
	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/huapohen/active-agent/services/collaboration/internal/harness"
	"github.com/huapohen/active-agent/services/collaboration/internal/store"
)

type profileCommand struct {
	ActionID        string `json:"action_id"`
	DisplayName     string `json:"display_name"`
	ExpectedVersion int64  `json:"expected_version"`
	RunID           string `json:"run_id,omitempty"`
}

func accountReader(c *gin.Context) store.AccountReader {
	if m, ok := machine(c); ok {
		return store.AccountReader{MachineIssuer: m.Issuer, MachineSubject: m.MachineSubject}
	}
	return store.AccountReader{PrincipalID: principal(c).ID}
}

func readAccountQuery(values url.Values) (store.AccountQuery, error) {
	out := store.AccountQuery{After: values.Get("after"), Limit: 100, RunID: values.Get("run_id")}
	if !allowedQuery(values, "after", "limit", "run_id") || (out.After != "" && !validID(out.After)) || (out.RunID != "" && !validID(out.RunID)) {
		return out, domain.ErrInvalid
	}
	if values.Has("limit") {
		n, err := strconv.Atoi(values.Get("limit"))
		if err != nil || n < 1 || n > 100 {
			return out, domain.ErrInvalid
		}
		out.Limit = n
	}
	return out, nil
}

func nativeProfileUpdate(c *gin.Context, s *store.Store, cmd profileCommand) (any, error) {
	m, isMachine := machine(c)
	if !isMachine {
		if cmd.RunID != "" {
			return nil, domain.ErrInvalid
		}
		return s.UpdateProfile(c.Request.Context(), principal(c).ID, domain.UpdateProfile{ActionID: cmd.ActionID, DisplayName: cmd.DisplayName, ExpectedVersion: cmd.ExpectedVersion})
	}
	if !validID(cmd.RunID) {
		return nil, domain.ErrInvalid
	}
	run, err := s.GetExecutionRun(c.Request.Context(), principal(c).ID, cmd.RunID)
	if err != nil {
		return nil, err
	}
	payload, _ := json.Marshal(map[string]any{"display_name": cmd.DisplayName, "expected_version": cmd.ExpectedVersion})
	return s.ExecuteAction(c.Request.Context(), m.Issuer, m.MachineSubject, run.Context,
		harness.Action{ID: cmd.ActionID, Type: "profile.update", Payload: payload})
}

func mountProfileWorkspace(v1 *gin.RouterGroup, s *store.Store) {
	v1.GET("/profile", func(c *gin.Context) {
		if !allowedQuery(c.Request.URL.Query(), "run_id") {
			fail(c, domain.ErrInvalid)
			return
		}
		profile, err := s.ReadProfile(c.Request.Context(), accountReader(c), c.Query("run_id"))
		if err != nil {
			fail(c, err)
			return
		}
		c.JSON(200, profile)
	})
	v1.POST("/profile", func(c *gin.Context) {
		if len(c.Request.URL.Query()) != 0 {
			fail(c, domain.ErrInvalid)
			return
		}
		var cmd profileCommand
		if !strictBody(c, &cmd) {
			return
		}
		receipt, err := nativeProfileUpdate(c, s, cmd)
		if err != nil {
			fail(c, err)
			return
		}
		c.JSON(200, receipt)
	})
	v1.GET("/workspaces", func(c *gin.Context) {
		q, err := readAccountQuery(c.Request.URL.Query())
		if err != nil {
			fail(c, err)
			return
		}
		page, err := s.Workspaces(c.Request.Context(), accountReader(c), q)
		if err != nil {
			fail(c, err)
			return
		}
		c.JSON(200, page)
	})
	v1.GET("/workspaces/:workspace/members", func(c *gin.Context) {
		q, err := readAccountQuery(c.Request.URL.Query())
		if err != nil || !validID(c.Param("workspace")) {
			fail(c, domain.ErrInvalid)
			return
		}
		page, err := s.WorkspaceMembers(c.Request.Context(), accountReader(c), c.Param("workspace"), q)
		if err != nil {
			fail(c, err)
			return
		}
		c.JSON(200, page)
	})
	v1.GET("/rooms/:room/members", func(c *gin.Context) {
		q, err := readAccountQuery(c.Request.URL.Query())
		if err != nil || !validID(c.Param("room")) {
			fail(c, domain.ErrInvalid)
			return
		}
		page, err := s.RoomMembers(c.Request.Context(), accountReader(c), c.Param("room"), q)
		if err != nil {
			fail(c, err)
			return
		}
		c.JSON(200, page)
	})
}
