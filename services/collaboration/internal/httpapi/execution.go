package httpapi

import (
	"encoding/json"
	"errors"
	"io"
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/huapohen/active-agent/services/collaboration/internal/auth"
	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/huapohen/active-agent/services/collaboration/internal/harness"
	"github.com/huapohen/active-agent/services/collaboration/internal/store"
)

func strictBody(c *gin.Context, out any) bool {
	d := json.NewDecoder(c.Request.Body)
	d.DisallowUnknownFields()
	if d.Decode(out) != nil || d.Decode(new(any)) != io.EOF {
		fail(c, domain.ErrInvalid)
		return false
	}
	return true
}
func machine(c *gin.Context) (auth.MachineIdentity, bool) {
	v, ok := c.Get("machine")
	if !ok {
		return auth.MachineIdentity{}, false
	}
	m, ok := v.(auth.MachineIdentity)
	return m, ok
}
func machineAuth(s *store.Store, v auth.MachineVerifier) gin.HandlerFunc {
	return func(c *gin.Context) {
		header := c.GetHeader("Authorization")
		if v == nil || !strings.HasPrefix(header, "Bearer mt_") {
			c.AbortWithStatusJSON(401, gin.H{"error": "machine_unauthenticated"})
			return
		}
		m, err := v.VerifyMachine(c.Request.Context(), strings.TrimPrefix(header, "Bearer "))
		if err != nil {
			c.AbortWithStatusJSON(401, gin.H{"error": "machine_unauthenticated"})
			return
		}
		b, err := s.ResolveExecutor(c.Request.Context(), m.Issuer, m.MachineSubject)
		if err != nil {
			fail(c, err)
			c.Abort()
			return
		}
		c.Set("principal", b.Principal)
		c.Set("machine", m)
		c.Set("executor", b)
		c.Next()
	}
}
func denyUnscopedMachineMutation(c *gin.Context) bool {
	if _, ok := machine(c); ok {
		c.JSON(403, gin.H{"error": "machine_action_requires_registered_gateway"})
		return true
	}
	return false
}
func nativeSend(c *gin.Context, s *store.Store, room string, cmd domain.SendMessage, runID string) (any, error) {
	m, ok := machine(c)
	if !ok {
		return s.Send(c.Request.Context(), principal(c).ID, room, cmd)
	}
	if !validID(runID) {
		return nil, domain.ErrInvalid
	}
	run, err := s.GetExecutionRun(c.Request.Context(), principal(c).ID, runID)
	if err != nil {
		return nil, err
	}
	if run.Context.RoomID != room || (cmd.ScopeEpoch != nil && *cmd.ScopeEpoch != run.Context.ScopeEpoch) {
		return nil, domain.ErrStopped
	}
	payload, _ := json.Marshal(map[string]string{"room_id": room, "content": cmd.Content})
	return s.ExecuteAction(c.Request.Context(), m.Issuer, m.MachineSubject, run.Context, harness.Action{ID: cmd.ActionID, Type: "message.send", Payload: payload})
}

func nativeRooms(c *gin.Context, s *store.Store, after, runID string) ([]domain.Room, error) {
	m, ok := machine(c)
	if !ok {
		if runID != "" {
			return nil, domain.ErrInvalid
		}
		return s.Rooms(c.Request.Context(), principal(c).ID, after)
	}
	if runID != "" {
		return s.ExecutionRooms(c.Request.Context(), m.Issuer, m.MachineSubject, runID, after)
	}
	return s.ExecutorRooms(c.Request.Context(), m.Issuer, m.MachineSubject, after)
}
func nativeMessages(c *gin.Context, s *store.Store, room string, after int64, runID string) ([]domain.Message, error) {
	m, ok := machine(c)
	if !ok {
		if runID != "" {
			return nil, domain.ErrInvalid
		}
		return s.Messages(c.Request.Context(), principal(c).ID, room, after)
	}
	if runID != "" {
		return s.ExecutionMessages(c.Request.Context(), m.Issuer, m.MachineSubject, runID, room, after)
	}
	return s.ExecutorMessages(c.Request.Context(), m.Issuer, m.MachineSubject, room, after)
}
func mountExecution(g *gin.Engine, v1 *gin.RouterGroup, s *store.Store, cfg config) {
	v1.POST("/executors", func(c *gin.Context) {
		if denyUnscopedMachineMutation(c) {
			return
		}
		var q store.RegisterExecutorCommand
		if !strictBody(c, &q) {
			return
		}
		b, err := s.RegisterExecutor(c.Request.Context(), principal(c).ID, q)
		if err != nil {
			fail(c, err)
			return
		}
		c.JSON(200, gin.H{"executor": b})
	})
	v1.POST("/agents/execution-policy", func(c *gin.Context) {
		if denyUnscopedMachineMutation(c) {
			return
		}
		var q store.AgentExecutionPolicyCommand
		if !strictBody(c, &q) {
			return
		}
		p, err := s.SetAgentExecutionPolicy(c.Request.Context(), principal(c).ID, q)
		if err != nil {
			fail(c, err)
			return
		}
		c.JSON(200, gin.H{"policy": p})
	})
	v1.POST("/runs", func(c *gin.Context) {
		var q store.CreateExecutionRunCommand
		if !strictBody(c, &q) {
			return
		}
		if _, ok := machine(c); ok {
			b := c.MustGet("executor").(store.ExecutorBinding)
			if b.ExecutorID != q.ExecutorID {
				fail(c, domain.ErrForbidden)
				return
			}
		}
		run, err := s.CreateExecutionRun(c.Request.Context(), principal(c).ID, q)
		if err != nil {
			fail(c, err)
			return
		}
		c.JSON(201, gin.H{"run": run})
	})
	v1.GET("/runs/:run", func(c *gin.Context) {
		run, err := s.GetExecutionRun(c.Request.Context(), principal(c).ID, c.Param("run"))
		if err != nil {
			fail(c, err)
			return
		}
		if _, ok := machine(c); ok {
			b := c.MustGet("executor").(store.ExecutorBinding)
			if b.ExecutorID != run.Context.ExecutorID {
				fail(c, domain.ErrForbidden)
				return
			}
		}
		c.JSON(200, gin.H{"run": run})
	})
	internal := g.Group("/internal/harness")
	internal.Use(machineAuth(s, cfg.machine))
	internal.POST("/binding", func(c *gin.Context) {
		var q struct {
			PrincipalID string `json:"principal_id"`
			ExecutorID  string `json:"executor_id"`
		}
		if !strictBody(c, &q) {
			return
		}
		b := c.MustGet("executor").(store.ExecutorBinding)
		if q.PrincipalID != b.Principal.ID || q.ExecutorID != b.ExecutorID {
			fail(c, domain.ErrForbidden)
			return
		}
		c.JSON(200, gin.H{"protocol": "renji-harness-v1", "principal_id": b.Principal.ID, "executor_id": b.ExecutorID, "server_bound": true, "actions_idempotent": true, "scope_epochs_enforced": true})
	})
	internal.POST("/check", func(c *gin.Context) {
		var q struct {
			Context harness.RunContext `json:"context"`
		}
		if !strictBody(c, &q) {
			return
		}
		m, _ := machine(c)
		if err := s.CheckExecution(c.Request.Context(), m.Issuer, m.MachineSubject, q.Context); err != nil {
			executionFail(c, err)
			return
		}
		c.JSON(200, gin.H{"allowed": true})
	})
	internal.POST("/actions", func(c *gin.Context) {
		var q struct {
			Context harness.RunContext `json:"context"`
			Action  harness.Action     `json:"action"`
		}
		if !strictBody(c, &q) {
			return
		}
		m, _ := machine(c)
		receipt, err := s.ExecuteAction(c.Request.Context(), m.Issuer, m.MachineSubject, q.Context, q.Action)
		if err != nil {
			executionFail(c, err)
			return
		}
		c.JSON(200, receipt)
	})
	internal.POST("/events", func(c *gin.Context) {
		var q struct {
			Context harness.RunContext `json:"context"`
			Event   harness.Event      `json:"event"`
		}
		if !strictBody(c, &q) {
			return
		}
		m, _ := machine(c)
		if err := s.AppendExecutionEvent(c.Request.Context(), m.Issuer, m.MachineSubject, q.Context, q.Event); err != nil {
			executionFail(c, err)
			return
		}
		c.Status(204)
	})
}
func executionFail(c *gin.Context, err error) {
	status, code := safeError(err)
	if errors.Is(err, domain.ErrStopped) {
		code = "scope_stopped"
	}
	c.JSON(status, gin.H{"code": code, "error": code})
}
