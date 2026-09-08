package httpapi

import (
	"bytes"
	"encoding/json"
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/huapohen/active-agent/services/collaboration/internal/store"
)

// This registry describes implemented protocol coverage, never desired scope.
// Dynamic object authorization still runs on every operation in Store.
type capability struct {
	ID            string          `json:"id"`
	Version       string          `json:"version"`
	Protocols     map[string]bool `json:"protocols"`
	Exportable    bool            `json:"exportable"`
	MachineAccess string          `json:"machine_access"`
}

func registry() []capability {
	out := []capability{}
	for _, id := range []string{"identity.read", "workspace.create", "room.list", "room.create", "message.read", "message.send", "room.execution_policy", "transport.session", "executor.register", "agent.execution_policy", "execution.run.create", "execution.run.read"} {
		mcp := id != "transport.session" && id != "executor.register" && id != "agent.execution_policy"
		access := "authenticated"
		switch id {
		case "message.send":
			access = "run_required"
		case "workspace.create", "room.create", "room.execution_policy", "executor.register", "agent.execution_policy":
			access = "gateway_action_pending"
		case "transport.session":
			access = "isolated_test_only"
		}
		out = append(out, capability{ID: id, MachineAccess: access, Version: "1", Protocols: map[string]bool{"api": true, "mcp": mcp, "a2a": false}, Exportable: id == "room.list" || id == "message.read" || id == "execution.run.read"})
	}
	return out
}
func mountNative(v1 *gin.RouterGroup, s *store.Store) {
	v1.GET("/mcp", func(c *gin.Context) { c.Header("Allow", "POST"); c.Status(405) })
	v1.GET("/capabilities", func(c *gin.Context) {
		c.JSON(200, gin.H{"schema": "renji.capabilities.v1", "capabilities": registry()})
	})
	v1.POST("/mcp", func(c *gin.Context) {
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
			respond(gin.H{"tools": visibleTools(c, []any{
				toolSchema("run_create", "Create an authorized persistent run; inherited source scopes come from the server.", []string{"action_id", "executor_id", "room_id", "scope_epoch", "goal"}, map[string]any{"action_id": schemaString(), "executor_id": schemaString(), "room_id": schemaString(), "scope_epoch": gin.H{"type": "integer", "minimum": 1}, "parent_run_id": schemaString(), "goal": schemaString()}),
				toolSchema("run_read", "Read the current authorized run and its recorded scope.", []string{"run_id"}, map[string]any{"run_id": schemaString()}),
				toolSchema("workspace_create", "Create an owned workspace with a durable action receipt.", []string{"action_id", "title"}, map[string]any{"action_id": schemaString(), "title": schemaString()}),
				toolSchema("room_create", "Create an authorized group for human and Agent members.", []string{"action_id", "workspace_id", "title"}, map[string]any{"action_id": schemaString(), "workspace_id": schemaString(), "title": schemaString(), "members": gin.H{"type": "array", "items": schemaString(), "maxItems": 100}}),
				toolSchema("room_execution_policy", "Stop or resume Agent execution as a current room owner or admin. Replay preserves the original receipt.", []string{"room_id", "action_id", "expected_version", "stopped"}, map[string]any{"room_id": schemaString(), "action_id": schemaString(), "expected_version": gin.H{"type": "integer", "minimum": 1}, "stopped": gin.H{"type": "boolean"}}),
				gin.H{"name": "identity_read", "description": "Read the authenticated Renji identity.", "inputSchema": gin.H{"type": "object", "properties": gin.H{}, "additionalProperties": false}},
				gin.H{"name": "room_list", "description": "List currently authorized rooms; paginate with after.", "inputSchema": gin.H{"type": "object", "properties": gin.H{"after": gin.H{"type": "string"}, "run_id": schemaString()}}},
				gin.H{"name": "message_read", "description": "Export authorized messages in sequence order; paginate after.", "inputSchema": gin.H{"type": "object", "required": []string{"room_id"}, "properties": gin.H{"room_id": gin.H{"type": "string"}, "after": gin.H{"type": "integer", "minimum": 0}, "run_id": schemaString()}}},
				gin.H{"name": "message_send", "description": "Send using the same permission, epoch and idempotency gate as the UI.", "inputSchema": gin.H{"type": "object", "required": []string{"room_id", "action_id", "content"}, "properties": gin.H{"room_id": gin.H{"type": "string"}, "action_id": gin.H{"type": "string"}, "content": gin.H{"type": "string"}, "scope_epoch": gin.H{"type": "integer"}, "run_id": schemaString()}}},
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
			for _, name := range []string{"identity_read", "room_list", "message_read", "message_send", "workspace_create", "room_create", "room_execution_policy", "run_create", "run_read"} {
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
				RoomID          string          `json:"room_id"`
				ExecutorID      string          `json:"executor_id"`
				ParentRunID     string          `json:"parent_run_id"`
				Goal            string          `json:"goal"`
				RunID           string          `json:"run_id"`
				WorkspaceID     string          `json:"workspace_id"`
				Title           string          `json:"title"`
				Members         []string        `json:"members"`
				ExpectedVersion int64           `json:"expected_version"`
				Stopped         *bool           `json:"stopped"`
				After           json.RawMessage `json:"after"`
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
			if err == nil {
				switch p.Name {
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
						cursor := ""
						if len(rooms) > 100 {
							rooms = rooms[:100]
							cursor = rooms[99].ID
						}
						result = gin.H{"rooms": rooms, "cursor": cursor}
					} else {
						err = domain.ErrInvalid
					}
				case "message_read":
					var after int64
					if len(q.After) > 0 {
						err = json.Unmarshal(q.After, &after)
					}
					if err == nil && validID(q.RoomID) && after >= 0 {
						messages, e := nativeMessages(c, s, q.RoomID, after, q.RunID)
						err = e
						more := len(messages) > 100
						if more {
							messages = messages[:100]
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
	return gin.H{"name": name, "description": description, "inputSchema": gin.H{"type": "object", "required": required, "properties": properties, "additionalProperties": false}}
}

func validToolArguments(name string, raw json.RawMessage) bool {
	fields := map[string]string{
		"identity_read": "", "room_list": "after run_id", "message_read": "room_id after run_id",
		"message_send": "room_id action_id content scope_epoch run_id", "workspace_create": "action_id title",
		"room_create": "action_id workspace_id title members", "room_execution_policy": "action_id room_id expected_version stopped",
		"run_create": "action_id executor_id room_id scope_epoch parent_run_id goal", "run_read": "run_id",
	}
	allowed := map[string]bool{}
	for _, field := range strings.Fields(fields[name]) {
		allowed[field] = true
	}
	var args map[string]json.RawMessage
	if json.Unmarshal(raw, &args) != nil || args == nil {
		return false
	}
	for field := range args {
		if !allowed[field] {
			return false
		}
	}
	return true
}

func visibleTools(c *gin.Context, tools []any) []any {
	if _, ok := machine(c); !ok {
		return tools
	}
	out := []any{}
	for _, entry := range tools {
		tool := entry.(gin.H)
		name := tool["name"].(string)
		if name == "workspace_create" || name == "room_create" || name == "room_execution_policy" {
			continue
		}
		if name == "message_send" {
			schema := tool["inputSchema"].(gin.H)
			schema["required"] = append(schema["required"].([]string), "run_id")
			properties := schema["properties"].(gin.H)
			properties["action_id"] = gin.H{"type": "string", "pattern": "^[a-fA-F0-9]{64}$"}
			tool["description"] = "Send through the registered run, current source scopes and durable action ledger. action_id is a 64-hex stable action ID."
		}
		out = append(out, tool)
	}
	return out
}
