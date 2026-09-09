package httpapi

import (
	"bytes"
	"encoding/json"
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/huapohen/active-agent/services/collaboration/internal/emoji"
	"github.com/huapohen/active-agent/services/collaboration/internal/store"
)

// This registry describes implemented protocol coverage, never desired scope.
// Dynamic object authorization still runs on every operation in Store.
type capability struct {
	ID                string          `json:"id"`
	Version           string          `json:"version"`
	Protocols         map[string]bool `json:"protocols"`
	Exportable        bool            `json:"exportable"`
	MachineAccess     string          `json:"machine_access"`
	Available         bool            `json:"available"`
	UnavailableReason string          `json:"unavailable_reason,omitempty"`
}

func registry(cfg config) []capability {
	out := []capability{}
	for _, id := range []string{"identity.read", "profile.read", "profile.update", "workspace.list", "workspace.member.list", "room.member.list", "workspace.invitation.list", "workspace.invitation.create", "workspace.invitation.revoke", "workspace.invitation.accept", "workspace.invitation.action.read", "workspace.create", "room.list", "room.create", "message.read", "message.send", "message.reply", "message.reaction.set", "message.reaction.read", "emoji.read", "room.execution_policy", "transport.session", "transport.arrival.read", "executor.register", "agent.execution_policy", "execution.run.create", "execution.run.read", "execution.evidence.read"} {
		mcp := id != "transport.session" && id != "executor.register" && id != "agent.execution_policy"
		access := "authenticated"
		switch id {
		case "execution.evidence.read":
			access = "all_source_audit_or_live_execution"
		case "message.send", "message.reply", "message.reaction.set", "profile.update":
			access = "run_required"
		case "workspace.create", "room.create", "room.execution_policy", "executor.register", "agent.execution_policy":
			access = "gateway_action_pending"
		case "transport.session":
			access = "isolated_test_only"
		case "transport.arrival.read", "workspace.invitation.list", "workspace.invitation.create", "workspace.invitation.revoke", "workspace.invitation.accept", "workspace.invitation.action.read":
			access = "run_required"
		}
		entry := capability{ID: id, MachineAccess: access, Version: "1", Protocols: map[string]bool{"api": true, "mcp": mcp, "a2a": false}, Available: true, Exportable: id == "workspace.invitation.list" || id == "workspace.invitation.action.read" || id == "room.list" || id == "workspace.list" || id == "workspace.member.list" || id == "room.member.list" || id == "profile.read" || id == "message.read" || id == "message.reaction.read" || id == "emoji.read" || id == "execution.run.read" || id == "execution.evidence.read" || id == "transport.arrival.read"}
		if cfg.emoji == nil && (id == "message.reaction.set" || id == "emoji.read") {
			entry.Available = false
			entry.UnavailableReason = "emoji_catalog_unavailable"
		}
		out = append(out, entry)
	}
	return out
}
func mountNative(v1 *gin.RouterGroup, s *store.Store, cfg config) {
	v1.GET("/mcp", func(c *gin.Context) { c.Header("Allow", "POST"); c.Status(405) })
	v1.GET("/capabilities", func(c *gin.Context) {
		capabilities := registry(cfg)
		_, isMachine := machine(c)
		for i := range capabilities {
			entry := &capabilities[i]
			if entry.ID == "transport.session" && !cfg.transportTestPrincipals[principal(c).ID] {
				entry.Available = false
				entry.UnavailableReason = "rongcloud_client_write_policy_unverified"
			}
			if isMachine && entry.MachineAccess == "gateway_action_pending" {
				entry.Available = false
				entry.UnavailableReason = "machine_action_not_implemented"
			}
		}
		c.JSON(200, gin.H{"schema": "renji.capabilities.v1", "capabilities": capabilities})
	})
	v1.POST("/mcp", func(c *gin.Context) {
		c.Header("Cache-Control", "no-store")
		var req struct {
			JSONRPC string          `json:"jsonrpc"`
			ID      json.RawMessage `json:"id"`
			Method  string          `json:"method"`
			Params  json.RawMessage `json:"params"`
		}
		if c.ShouldBindJSON(&req) != nil || req.JSONRPC != "2.0" {
			c.JSON(400, gin.H{"jsonrpc": "2.0", "id": nil, "error": gin.H{"code": -32600, "message": "Invalid Request"}})
			return
		}
		if req.Method != "initialize" && c.GetHeader("MCP-Protocol-Version") != "2025-11-25" {
			c.JSON(400, gin.H{"error": "unsupported_protocol_version"})
			return
		}
		if req.Method == "notifications/initialized" && len(req.ID) == 0 {
			c.Status(202)
			return
		}
		if !rpcID(req.ID) {
			c.JSON(400, gin.H{"error": "request_id_required"})
			return
		}
		respond := func(result any) { c.JSON(200, gin.H{"jsonrpc": "2.0", "id": req.ID, "result": result}) }
		switch req.Method {
		case "initialize":
			var init struct {
				ProtocolVersion string         `json:"protocolVersion"`
				Capabilities    map[string]any `json:"capabilities"`
				ClientInfo      struct {
					Name    string `json:"name"`
					Version string `json:"version"`
				} `json:"clientInfo"`
			}
			if json.Unmarshal(req.Params, &init) != nil || init.ProtocolVersion == "" || init.Capabilities == nil || init.ClientInfo.Name == "" || init.ClientInfo.Version == "" {
				c.JSON(200, gin.H{"jsonrpc": "2.0", "id": req.ID, "error": gin.H{"code": -32602, "message": "Invalid initialization params"}})
				return
			}
			respond(gin.H{"protocolVersion": "2025-11-25", "serverInfo": gin.H{"name": "renji", "version": "0.1.0-startup"}, "capabilities": gin.H{"tools": gin.H{}}})
		case "ping":
			respond(gin.H{})
		case "tools/list":
			respond(gin.H{"tools": visibleTools(c, cfg, []any{
				toolSchema("workspace_invitation_create", "Issue a single-use member invitation as a current workspace owner/admin. The secret code is returned only once; never persist it in logs or agent transcripts. Replays and action readback return a sanitized receipt. Machine calls require a live Run and retain issuer source restrictions when accepted.", []string{"workspace_id", "action_id"}, map[string]any{"workspace_id": schemaString(), "action_id": schemaString(), "expires_in_seconds": gin.H{"type": "integer", "minimum": 60, "maximum": 604800}, "run_id": schemaString()}),
				toolSchema("workspace_invitation_list", "List invitation status as a current workspace owner/admin. Never returns secret codes.", []string{"workspace_id"}, map[string]any{"workspace_id": schemaString(), "after": schemaString(), "limit": gin.H{"type": "integer", "minimum": 1, "maximum": 100}, "run_id": schemaString()}),
				toolSchema("workspace_invitation_revoke", "Revoke one invitation using a stable action ID. Cannot revoke a consumed invitation. Requires current owner/admin rights and, for Agents, the original live Run fences.", []string{"workspace_id", "invitation_id", "action_id"}, map[string]any{"workspace_id": schemaString(), "invitation_id": schemaString(), "action_id": schemaString(), "run_id": schemaString()}),
				toolSchema("workspace_invitation_accept", "Join a workspace as this verified Human or Agent using a one-time code. Grants member only; never expands an Agent's executor workspace or Run scope. Keep the same action ID when retrying the same code. Never log the code.", []string{"action_id", "code"}, map[string]any{"action_id": schemaString(), "code": gin.H{"type": "string", "pattern": "^rji_[A-Za-z0-9_-]{43}$"}, "run_id": schemaString()}),
				toolSchema("workspace_invitation_action_read", "Reconcile this identity's original invitation action after an uncertain outcome. Returns a sanitized receipt without the secret code. A missing receipt is not permission to substitute a new action or code.", []string{"action_id"}, map[string]any{"action_id": schemaString(), "run_id": schemaString()}),
				toolSchema("transport_arrival_read", "Read this receiver's verified RongCloud SDK arrivals. Machine reads require a live Run and retain all inherited source fences. A heartbeat is not a received message.", []string{}, map[string]any{"run_id": schemaString(), "after": gin.H{"type": "integer", "minimum": 0, "maximum": 9007199254740991}, "limit": gin.H{"type": "integer", "minimum": 1, "maximum": 100}}),
				toolSchema("profile_read", "Read this authenticated identity's current display name and profile version; a machine run_id applies all original source fences.", []string{}, map[string]any{"run_id": schemaString()}),
				toolSchema("profile_update", "Update only this authenticated identity's display name using a durable action and current profile version. Never changes identity, roles or another colleague.", []string{"action_id", "display_name", "expected_version"}, map[string]any{"action_id": schemaString(), "display_name": gin.H{"type": "string", "minLength": 1, "maxLength": 80}, "expected_version": gin.H{"type": "integer", "minimum": 1}, "run_id": schemaString()}),
				toolSchema("workspace_list", "List currently authorized workspaces. Machine reads remain limited to their registered workspace; optional run_id retains all source checks.", []string{}, map[string]any{"after": schemaString(), "limit": gin.H{"type": "integer", "minimum": 1, "maximum": 100}, "run_id": schemaString()}),
				toolSchema("workspace_member_list", "List current authorized workspace colleagues, including human and Agent identities. Explicit Run reads include only colleagues in inherited rooms; no global directory lookup.", []string{"workspace_id"}, map[string]any{"workspace_id": schemaString(), "after": schemaString(), "limit": gin.H{"type": "integer", "minimum": 1, "maximum": 100}, "run_id": schemaString()}),
				toolSchema("room_member_list", "List current human and Agent members of an authorized room using an exclusive principal cursor.", []string{"room_id"}, map[string]any{"room_id": schemaString(), "after": schemaString(), "limit": gin.H{"type": "integer", "minimum": 1, "maximum": 100}, "run_id": schemaString()}),
				toolSchema("run_create", "Create an authorized persistent run; inherited source scopes come from the server.", []string{"action_id", "executor_id", "room_id", "scope_epoch", "goal"}, map[string]any{"action_id": schemaString(), "executor_id": schemaString(), "room_id": schemaString(), "scope_epoch": gin.H{"type": "integer", "minimum": 1}, "parent_run_id": schemaString(), "goal": schemaString()}),
				toolSchema("run_evidence", "Export complete durable Run actions, raw events and transport facts. Audit remains readable after stop with current all-source membership; execution additionally enforces current executor epochs.", []string{"run_id"}, map[string]any{"run_id": schemaString(), "after": gin.H{"type": "integer", "minimum": 0}, "through": gin.H{"type": "integer", "minimum": 0}, "limit": gin.H{"type": "integer", "minimum": 1, "maximum": 100}, "mode": gin.H{"type": "string", "enum": []string{"audit", "execution"}}}),
				toolSchema("run_read", "Read the current authorized run and its recorded scope.", []string{"run_id"}, map[string]any{"run_id": schemaString()}),
				toolSchema("workspace_create", "Create an owned workspace with a durable action receipt.", []string{"action_id", "title"}, map[string]any{"action_id": schemaString(), "title": schemaString()}),
				toolSchema("room_create", "Create an authorized group for human and Agent members.", []string{"action_id", "workspace_id", "title"}, map[string]any{"action_id": schemaString(), "workspace_id": schemaString(), "title": schemaString(), "members": gin.H{"type": "array", "items": schemaString(), "maxItems": 100}}),
				toolSchema("room_execution_policy", "Stop or resume Agent execution as a current room owner or admin. Replay preserves the original receipt.", []string{"room_id", "action_id", "expected_version", "stopped"}, map[string]any{"room_id": schemaString(), "action_id": schemaString(), "expected_version": gin.H{"type": "integer", "minimum": 1}, "stopped": gin.H{"type": "boolean"}}),
				gin.H{"name": "identity_read", "description": "Read the authenticated Renji identity.", "inputSchema": gin.H{"type": "object", "properties": gin.H{}, "additionalProperties": false}},
				gin.H{"name": "room_list", "description": "List currently authorized rooms; paginate with after.", "inputSchema": gin.H{"type": "object", "properties": gin.H{"after": gin.H{"type": "string"}, "run_id": schemaString()}}},
				toolSchema("message_read", "Export authorized messages in ascending sequence order. Default after=0 exports forward; before=0 selects the latest page, positive before excludes that sequence. after and before are mutually exclusive.", []string{"room_id"}, map[string]any{"room_id": schemaString(), "after": gin.H{"type": "integer", "minimum": 0}, "before": gin.H{"type": "integer", "minimum": 0}, "limit": gin.H{"type": "integer", "minimum": 1, "maximum": 100}, "run_id": schemaString()}),
				toolSchema("message_send", "Send or reply through the same permission, epoch and idempotency gate as the UI. reply_to must name an authorized message in the same room.", []string{"room_id", "action_id", "content"}, map[string]any{"room_id": schemaString(), "action_id": schemaString(), "content": schemaString(), "scope_epoch": gin.H{"type": "integer", "minimum": 1}, "reply_to": schemaString(), "run_id": schemaString()}),
				toolSchema("message_get", "Read one currently authorized canonical message, including reply metadata and reactions.", []string{"room_id", "message_id"}, map[string]any{"room_id": schemaString(), "message_id": schemaString(), "run_id": schemaString()}),
				toolSchema("message_reaction_set", "Set this identity's reaction to an explicit active state using a stable action ID; never toggle. Requires an available emoji catalog.", []string{"room_id", "message_id", "action_id", "emoji", "active"}, map[string]any{"room_id": schemaString(), "message_id": schemaString(), "action_id": schemaString(), "emoji": schemaString(), "active": gin.H{"type": "boolean"}, "scope_epoch": gin.H{"type": "integer", "minimum": 1}, "run_id": schemaString()}),
				toolSchema("message_reaction_read", "Read current reaction aggregates under this identity's room and run authorization. Fence pagination using expected_version.", []string{"room_id", "message_id"}, map[string]any{"room_id": schemaString(), "message_id": schemaString(), "after": schemaString(), "limit": gin.H{"type": "integer", "minimum": 1, "maximum": 50}, "expected_version": gin.H{"type": "integer", "minimum": 0}, "run_id": schemaString()}),
				toolSchema("emoji_list", "Search the configured local emoji snapshot. Images use authenticated API paths. Optional run_id enforces current machine source scopes before and after reading.", []string{}, map[string]any{"q": schemaString(), "category": schemaString(), "offset": gin.H{"type": "integer", "minimum": 0}, "limit": gin.H{"type": "integer", "minimum": 1, "maximum": 200}, "revision": schemaString(), "run_id": schemaString()}),
				toolSchema("emoji_get", "Read one exact stable emoji ID from the configured local snapshot; no invented IDs or remote asset lookup.", []string{"id"}, map[string]any{"id": schemaString(), "run_id": schemaString()}),
			})})
		case "tools/call":
			var p struct {
				Name      string          `json:"name"`
				Arguments json.RawMessage `json:"arguments"`
			}
			if json.Unmarshal(req.Params, &p) != nil {
				c.JSON(200, gin.H{"jsonrpc": "2.0", "id": req.ID, "error": gin.H{"code": -32602, "message": "Invalid params"}})
				return
			}

			known := false
			for _, name := range []string{"workspace_invitation_create", "workspace_invitation_list", "workspace_invitation_revoke", "workspace_invitation_accept", "workspace_invitation_action_read", "transport_arrival_read", "profile_read", "profile_update", "workspace_list", "workspace_member_list", "room_member_list", "identity_read", "room_list", "message_read", "message_send", "message_get", "message_reaction_set", "message_reaction_read", "emoji_list", "emoji_get", "workspace_create", "room_create", "room_execution_policy", "run_create", "run_read", "run_evidence"} {
				if p.Name == name {
					known = true
				}
			}
			if !known {
				c.JSON(200, gin.H{"jsonrpc": "2.0", "id": req.ID, "error": gin.H{"code": -32602, "message": "Unknown tool"}})
				return
			}
			if len(p.Arguments) == 0 {
				p.Arguments = json.RawMessage(`{}`)
			}
			if !bytes.HasPrefix(bytes.TrimSpace(p.Arguments), []byte("{")) {
				c.JSON(200, gin.H{"jsonrpc": "2.0", "id": req.ID, "error": gin.H{"code": -32602, "message": "Arguments must be an object"}})
				return
			}
			if !validToolArguments(p.Name, p.Arguments) {
				c.JSON(200, gin.H{"jsonrpc": "2.0", "id": req.ID, "error": gin.H{"code": -32602, "message": "Unknown or invalid tool arguments"}})
				return
			}
			var q struct {
				InvitationID            string          `json:"invitation_id"`
				Code                    string          `json:"code"`
				ExpiresInSeconds        int64           `json:"expires_in_seconds"`
				RoomID                  string          `json:"room_id"`
				ExecutorID              string          `json:"executor_id"`
				ParentRunID             string          `json:"parent_run_id"`
				Goal                    string          `json:"goal"`
				RunID                   string          `json:"run_id"`
				Through                 *int64          `json:"through"`
				Limit                   int             `json:"limit"`
				Mode                    string          `json:"mode"`
				WorkspaceID             string          `json:"workspace_id"`
				Title                   string          `json:"title"`
				DisplayName             string          `json:"display_name"`
				Members                 []string        `json:"members"`
				ExpectedVersion         int64           `json:"expected_version"`
				Stopped                 *bool           `json:"stopped"`
				After                   json.RawMessage `json:"after"`
				Before                  *int64          `json:"before"`
				MessageID               string          `json:"message_id"`
				Emoji                   string          `json:"emoji"`
				Active                  *bool           `json:"active"`
				ExpectedReactionVersion *int64          `json:"-"`
				ID                      string          `json:"id"`
				Q                       string          `json:"q"`
				Category                string          `json:"category"`
				Offset                  int             `json:"offset"`
				Revision                string          `json:"revision"`
				domain.SendMessage
			}
			err := json.Unmarshal(p.Arguments, &q)
			if err != nil {
				err = domain.ErrInvalid
			}
			var result any
			actor := principal(c)
			ctx := c.Request.Context()
			if _, isMachine := machine(c); isMachine && (p.Name == "workspace_create" || p.Name == "room_create" || p.Name == "room_execution_policy") {
				err = domain.ErrForbidden
			}
			if strings.HasPrefix(p.Name, "workspace_invitation_") {
				if _, isMachine := machine(c); !isMachine {
					var args map[string]json.RawMessage
					_ = json.Unmarshal(p.Arguments, &args)
					if _, present := args["run_id"]; present {
						err = domain.ErrInvalid
					}
				}
			}
			if err == nil {
				switch p.Name {
				case "workspace_invitation_create":
					result, err = nativeWorkspaceInvitationCreate(c, s, q.WorkspaceID, domain.CreateWorkspaceInvitation{ActionID: q.ActionID, ExpiresInSeconds: q.ExpiresInSeconds, RunID: q.RunID})
				case "workspace_invitation_revoke":
					result, err = nativeWorkspaceInvitationRevoke(c, s, q.WorkspaceID, q.InvitationID, domain.RevokeWorkspaceInvitation{ActionID: q.ActionID, RunID: q.RunID})
				case "workspace_invitation_accept":
					result, err = nativeWorkspaceInvitationAccept(c, s, domain.AcceptWorkspaceInvitation{ActionID: q.ActionID, Code: q.Code, RunID: q.RunID})
				case "workspace_invitation_action_read":
					result, err = nativeWorkspaceInvitationAction(c, s, q.ActionID, q.RunID)
				case "workspace_invitation_list":
					var after string
					if len(q.After) > 0 && json.Unmarshal(q.After, &after) != nil {
						err = domain.ErrInvalid
						break
					}
					result, err = nativeWorkspaceInvitationList(c, s, q.WorkspaceID, store.AccountQuery{After: after, Limit: q.Limit, RunID: q.RunID})
				case "transport_arrival_read":
					var after int64
					if len(q.After) > 0 && json.Unmarshal(q.After, &after) != nil {
						err = domain.ErrInvalid
						break
					}
					var args map[string]json.RawMessage
					_ = json.Unmarshal(p.Arguments, &args)
					if _, ok := machine(c); !ok {
						if _, present := args["run_id"]; present {
							err = domain.ErrInvalid
							break
						}
					}
					if q.Limit == 0 {
						q.Limit = 50
					}
					result, err = nativeTransportArrivals(c, s, q.RunID, after, q.Limit, cfg.rongCloudBridges)
				case "profile_read":
					result, err = s.ReadProfile(ctx, accountReader(c), q.RunID)
				case "profile_update":
					result, err = nativeProfileUpdate(c, s, profileCommand{ActionID: q.ActionID, DisplayName: q.DisplayName, ExpectedVersion: q.ExpectedVersion, RunID: q.RunID})
				case "workspace_list", "workspace_member_list", "room_member_list":
					var after string
					if len(q.After) > 0 && json.Unmarshal(q.After, &after) != nil {
						err = domain.ErrInvalid
						break
					}
					query := store.AccountQuery{After: after, Limit: q.Limit, RunID: q.RunID}
					switch p.Name {
					case "workspace_list":
						result, err = s.Workspaces(ctx, accountReader(c), query)
					case "workspace_member_list":
						result, err = s.WorkspaceMembers(ctx, accountReader(c), q.WorkspaceID, query)
					case "room_member_list":
						result, err = s.RoomMembers(ctx, accountReader(c), q.RoomID, query)
					}
				case "run_create":
					if q.ScopeEpoch == nil {
						err = domain.ErrInvalid
						break
					}
					if _, ok := machine(c); ok {
						b := c.MustGet("executor").(store.ExecutorBinding)
						if b.ExecutorID != q.ExecutorID {
							err = domain.ErrForbidden
							break
						}
					}
					var run store.ExecutionRun
					run, err = s.CreateExecutionRun(ctx, actor.ID, store.CreateExecutionRunCommand{ActionID: q.ActionID, ExecutorID: q.ExecutorID, RoomID: q.RoomID, ScopeEpoch: *q.ScopeEpoch, ParentRunID: q.ParentRunID, Goal: q.Goal})
					result = gin.H{"run": run}
				case "run_evidence":
					var after int64
					if len(q.After) > 0 {
						err = json.Unmarshal(q.After, &after)
					}
					if err == nil {
						result, err = nativeExecutionEvidence(c, s, q.RunID, store.EvidenceQuery{After: after, Through: q.Through, Limit: q.Limit, Mode: q.Mode})
					} else {
						err = domain.ErrInvalid
					}
				case "run_read":
					var run store.ExecutionRun
					run, err = s.GetExecutionRun(ctx, actor.ID, q.RunID)
					if err == nil {
						if _, ok := machine(c); ok {
							b := c.MustGet("executor").(store.ExecutorBinding)
							if b.ExecutorID != run.Context.ExecutorID {
								err = domain.ErrForbidden
							}
						}
					}
					result = gin.H{"run": run}
				case "workspace_create":
					q.Title = strings.TrimSpace(q.Title)
					var id string
					id, err = s.CreateWorkspace(ctx, actor.ID, q.ActionID, q.Title)
					result = gin.H{"workspace": gin.H{"id": id, "title": q.Title}}
				case "room_create":
					if !validID(q.WorkspaceID) {
						err = domain.ErrInvalid
						break
					}
					var r domain.Room
					r, err = s.CreateRoom(ctx, actor.ID, q.ActionID, q.WorkspaceID, q.Title, q.Members)
					result = gin.H{"room": r}
				case "room_execution_policy":
					if !validID(q.RoomID) || q.Stopped == nil {
						err = domain.ErrInvalid
						break
					}
					var r domain.Room
					r, err = s.SetStopped(ctx, actor.ID, q.RoomID, q.ActionID, q.ExpectedVersion, *q.Stopped)
					result = gin.H{"room": r}
				case "identity_read":
					result = gin.H{"principal": actor}
				case "room_list":
					var after string
					if len(q.After) > 0 {
						err = json.Unmarshal(q.After, &after)
					}
					if err == nil && (after == "" || validID(after)) {
						rooms, e := nativeRooms(c, s, after, q.RunID)
						err = e
						result = roomListPage(rooms)
					} else {
						err = domain.ErrInvalid
					}
				case "message_read":
					if q.Limit == 0 {
						q.Limit = 100
					}
					if q.Before != nil {
						if !validID(q.RoomID) || *q.Before < 0 || len(q.After) != 0 {
							err = domain.ErrInvalid
							break
						}
						result, err = beforeMessagePage(c, s, q.RoomID, *q.Before, q.Limit, q.RunID)
						break
					}
					var after int64
					if len(q.After) > 0 {
						err = json.Unmarshal(q.After, &after)
					}
					if err == nil && validID(q.RoomID) && after >= 0 {
						messages, e := nativeMessages(c, s, q.RoomID, after, q.RunID)
						err = e
						more := len(messages) > q.Limit
						if more {
							messages = messages[:q.Limit]
						}
						next := after
						if len(messages) > 0 {
							next = messages[len(messages)-1].Seq
						}
						result = gin.H{"messages": messages, "cursor": next, "has_more": more}
					} else {
						err = domain.ErrInvalid
					}
				case "message_send":
					if !validID(q.RoomID) {
						err = domain.ErrInvalid
					} else {
						result, err = nativeSend(c, s, q.RoomID, q.SendMessage, q.RunID)
					}
				case "message_get":
					var m domain.Message
					m, err = nativeMessage(c, s, q.RoomID, q.MessageID, q.RunID)
					result = gin.H{"message": m}
				case "message_reaction_set":
					if cfg.emoji == nil {
						err = errEmojiUnavailable
						break
					}
					result, err = nativeReactionSet(c, s, q.RoomID, q.MessageID, reactionCommand{ActionID: q.ActionID, Emoji: q.Emoji, Active: q.Active, ScopeEpoch: q.ScopeEpoch, RunID: q.RunID})
				case "message_reaction_read":
					var after string
					if len(q.After) > 0 {
						err = json.Unmarshal(q.After, &after)
					}
					var fields map[string]json.RawMessage
					_ = json.Unmarshal(p.Arguments, &fields)
					if raw, ok := fields["expected_version"]; ok {
						var n int64
						if json.Unmarshal(raw, &n) != nil || n < 0 {
							err = domain.ErrInvalid
						} else {
							q.ExpectedReactionVersion = &n
						}
					}
					if err != nil {
						err = domain.ErrInvalid
						break
					}
					result, err = nativeReactionRead(c, s, q.RoomID, q.MessageID, q.RunID, store.ReactionQuery{After: after, Limit: q.Limit, ExpectedVersion: q.ExpectedReactionVersion})
				case "emoji_list", "emoji_get":
					if err = authorizeEmojiRun(c, s, q.RunID); err != nil {
						break
					}
					if p.Name == "emoji_list" {
						result, err = emojiPage(ctx, cfg.emoji, emoji.Query{Q: q.Q, Category: q.Category, Offset: q.Offset, Limit: q.Limit, Revision: q.Revision})
					} else {
						var entry emoji.Entry
						entry, err = emojiEntry(ctx, cfg.emoji, q.ID)
						result = gin.H{"entry": entry}
					}
					if err == nil {
						err = authorizeEmojiRun(c, s, q.RunID)
					}
				default:
					err = domain.ErrInvalid
				}
			}
			if err != nil {
				_, code := safeError(err)
				respond(gin.H{"isError": true, "structuredContent": gin.H{"error": code}, "content": []any{gin.H{"type": "text", "text": code}}})
				return
			}
			text, _ := json.Marshal(result)
			respond(gin.H{"structuredContent": result, "content": []any{gin.H{"type": "text", "text": string(text)}}})
		default:
			c.JSON(200, gin.H{"jsonrpc": "2.0", "id": req.ID, "error": gin.H{"code": -32601, "message": "Method not found"}})
		}
	})
}

func rpcID(raw json.RawMessage) bool {
	var id any
	d := json.NewDecoder(bytes.NewReader(raw))
	d.UseNumber()
	if d.Decode(&id) != nil {
		return false
	}
	switch id.(type) {
	case string, json.Number:
		return true
	}
	return false
}
func schemaString() gin.H { return gin.H{"type": "string"} }
func toolSchema(name, description string, required []string, properties map[string]any) gin.H {
	return gin.H{"name": name, "description": description, "inputSchema": gin.H{"type": "object", "required": required, "properties": gin.H(properties), "additionalProperties": false}}
}

func validToolArguments(name string, raw json.RawMessage) bool {
	fields := map[string]string{
		"workspace_invitation_create":      "workspace_id action_id expires_in_seconds run_id",
		"workspace_invitation_list":        "workspace_id after limit run_id",
		"workspace_invitation_revoke":      "workspace_id invitation_id action_id run_id",
		"workspace_invitation_accept":      "action_id code run_id",
		"workspace_invitation_action_read": "action_id run_id",
		"transport_arrival_read":           "run_id after limit",
		"profile_read":                     "run_id", "profile_update": "action_id display_name expected_version run_id",
		"workspace_list": "after limit run_id", "workspace_member_list": "workspace_id after limit run_id", "room_member_list": "room_id after limit run_id",
		"identity_read": "", "room_list": "after run_id", "message_read": "room_id after before limit run_id",
		"message_send": "room_id action_id content scope_epoch run_id reply_to", "workspace_create": "action_id title",
		"message_get": "room_id message_id run_id", "message_reaction_set": "room_id message_id action_id emoji active scope_epoch run_id",
		"message_reaction_read": "room_id message_id after limit expected_version run_id", "emoji_list": "q category offset limit revision run_id", "emoji_get": "id run_id",
		"room_create": "action_id workspace_id title members", "room_execution_policy": "action_id room_id expected_version stopped",
		"run_create": "action_id executor_id room_id scope_epoch parent_run_id goal", "run_read": "run_id", "run_evidence": "run_id after through limit mode",
	}
	allowed := map[string]bool{}
	for _, field := range strings.Fields(fields[name]) {
		allowed[field] = true
	}
	var args map[string]json.RawMessage
	if json.Unmarshal(raw, &args) != nil || args == nil {
		return false
	}
	if name == "workspace_invitation_list" || name == "transport_arrival_read" || name == "run_evidence" || name == "message_read" || name == "message_reaction_read" || name == "emoji_list" || name == "workspace_list" || name == "workspace_member_list" || name == "room_member_list" {
		if raw, ok := args["limit"]; ok {
			var n int
			max := 100
			if name == "message_reaction_read" {
				max = 50
			}
			if name == "emoji_list" {
				max = 200
			}
			if json.Unmarshal(raw, &n) != nil || n < 1 || n > max {
				return false
			}
		}
	}
	for _, field := range []string{"before", "offset", "expected_version"} {
		if raw, ok := args[field]; ok {
			var n *int64
			if json.Unmarshal(raw, &n) != nil || n == nil || *n < 0 {
				return false
			}
		}
	}
	if name == "transport_arrival_read" {
		if raw, ok := args["after"]; ok {
			var n *int64
			if json.Unmarshal(raw, &n) != nil || n == nil || *n < 0 || *n > 9007199254740991 {
				return false
			}
		}
	}
	if name == "message_read" {
		if raw, ok := args["after"]; ok {
			var n *int64
			if json.Unmarshal(raw, &n) != nil || n == nil || *n < 0 {
				return false
			}
		}
		if _, before := args["before"]; before {
			if _, after := args["after"]; after {
				return false
			}
		}
	}
	// An explicitly supplied null run/filter is not an absent run/filter. Do
	// not silently broaden a caller's requested read by dropping invalid input.
	for _, field := range []string{"run_id", "q", "category", "revision", "id", "reply_to"} {
		if raw, ok := args[field]; ok {
			var value *string
			if json.Unmarshal(raw, &value) != nil || value == nil {
				return false
			}
		}
	}
	if name == "workspace_invitation_list" || name == "workspace_list" || name == "workspace_member_list" || name == "room_member_list" {
		if raw, ok := args["after"]; ok {
			var value *string
			if json.Unmarshal(raw, &value) != nil || value == nil {
				return false
			}
		}
	}
	if strings.HasPrefix(name, "workspace_invitation_") {
		for _, field := range []string{"workspace_id", "invitation_id", "action_id", "code"} {
			if raw, present := args[field]; present {
				var value *string
				if json.Unmarshal(raw, &value) != nil || value == nil || *value == "" {
					return false
				}
			}
		}
		if raw, present := args["expires_in_seconds"]; present {
			var n *int64
			if json.Unmarshal(raw, &n) != nil || n == nil || *n < 60 || *n > 604800 {
				return false
			}
		}
	}
	for field := range args {
		if !allowed[field] {
			return false
		}
	}
	return true
}

func visibleTools(c *gin.Context, cfg config, tools []any) []any {
	_, isMachine := machine(c)
	out := []any{}
	for _, entry := range tools {
		tool := entry.(gin.H)
		name := tool["name"].(string)
		if cfg.emoji == nil && (name == "emoji_list" || name == "emoji_get" || name == "message_reaction_set") {
			continue
		}
		if name == "transport_arrival_read" {
			schema := tool["inputSchema"].(gin.H)
			if isMachine {
				schema["required"] = []string{"run_id"}
			} else {
				delete(schema["properties"].(gin.H), "run_id")
			}
		}
		if strings.HasPrefix(name, "workspace_invitation_") {
			schema := tool["inputSchema"].(gin.H)
			if isMachine {
				schema["required"] = append(schema["required"].([]string), "run_id")
				if name != "workspace_invitation_list" {
					schema["properties"].(gin.H)["action_id"] = gin.H{"type": "string", "pattern": "^[a-fA-F0-9]{64}$"}
				}
			} else {
				delete(schema["properties"].(gin.H), "run_id")
			}
		}
		if !isMachine {
			out = append(out, tool)
			continue
		}
		if name == "workspace_create" || name == "room_create" || name == "room_execution_policy" {
			continue
		}
		if name == "message_send" || name == "message_reaction_set" || name == "profile_update" {
			schema := tool["inputSchema"].(gin.H)
			schema["required"] = append(schema["required"].([]string), "run_id")
			properties := schema["properties"].(gin.H)
			properties["action_id"] = gin.H{"type": "string", "pattern": "^[a-fA-F0-9]{64}$"}
			tool["description"] = "Act through the registered run, current source scopes and durable action ledger. action_id is a 64-hex stable action ID; reaction active must be explicit, never toggle."
			if name == "profile_update" {
				tool["description"] = "Update this Agent's own display name through its live registered Run and all inherited source fences. Read the current profile version first; action_id must be a stable 64-hex ID. Cannot change identity, roles or another principal."
			}
		}
		out = append(out, tool)
	}
	return out
}
