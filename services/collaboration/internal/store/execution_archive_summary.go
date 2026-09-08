package store

import (
	"encoding/json"
	"fmt"
	"reflect"
	"sort"
	"strconv"
	"strings"
	"unicode"

	"github.com/huapohen/active-agent/services/collaboration/internal/harness"
)

func archiveStatusLabel(status string) string {
	switch status {
	case "running":
		return "执行中"
	case "completed":
		return "执行完成"
	case "failed":
		return "执行失败"
	case "stopped":
		return "已停止"
	case "reconciliation_required":
		return "结果待核对"
	default:
		return "状态未识别"
	}
}

func archiveReadableTitle(run ExecutionRun, part int) string {
	// User goals are untrusted rich text. Keep them out of headings and titles.
	id := strings.ReplaceAll(run.Context.RunID, "-", "")
	if len(id) > 8 {
		id = id[:8]
	}
	if !executionUUIDs(run.Context.RunID) {
		id = "unknown"
	}
	return fmt.Sprintf("人机执行档案 · %s · %s · %s · 第%d册", archiveStatusLabel(run.Status), run.CreatedAt.UTC().Format("2006-01-02"), id, part)
}

// This is a navigation aid over a frozen evidence prefix, never an LLM
// summary. Only recognized server ledger shapes contribute to fact counts.
func archiveReadableSummary(run ExecutionRun, through int64, entries []ExecutionEvidenceEntry) string {
	var b strings.Builder
	b.WriteString("## 任务与结果\n\n")
	goal := []rune(run.Goal)
	truncated := len(goal) > 640
	if truncated {
		goal = goal[:640]
	}
	// Keep bidi/control text out of the human overview. The JSON below retains
	// the complete original bytes for every reader, including Agents.
	cleanGoal := strings.Map(func(r rune) rune {
		if (unicode.IsControl(r) && r != '\n' && r != '\t') || unicode.In(r, unicode.Cf) {
			return '\uFFFD'
		}
		return r
	}, string(goal))
	if cleanGoal == "" {
		b.WriteString("任务目标未提供。\n\n")
	} else {
		fence := archiveFence(cleanGoal)
		fmt.Fprintf(&b, "任务目标（原文预览）：\n\n%stext\n%s\n%s\n\n", fence, cleanGoal, fence)
		if truncated {
			b.WriteString("目标预览已截短；完整内容见下方 Run 元数据。\n\n")
		}
	}
	fmt.Fprintf(&b, "- 当前状态：%s。\n- 创建时间：%s（UTC）。\n", archiveStatusLabel(run.Status), run.CreatedAt.UTC().Format("2006-01-02 15:04:05"))
	// Deduplicate by the canonical object ID and choose the greatest evidence
	// cursor. In particular an unknown later transport state cannot resurrect
	// a previously delivered state, even if input entries are not sorted.
	actions, transports := map[string]ExecutionEvidenceEntry{}, map[string]ExecutionEvidenceEntry{}
	stages := map[int]map[int]bool{}
	legacy, unreadable := 0, 0
	for _, e := range entries {
		if e.Seq <= 0 || e.Seq > through {
			continue
		}
		if e.LegacySnapshot {
			legacy++
		}
		switch e.Kind {
		case "action", "transport":
			target := actions
			if e.Kind == "transport" {
				target = transports
			}
			if e.ObjectID == "" {
				unreadable++
			} else if old, ok := target[e.ObjectID]; !ok || old.Seq < e.Seq {
				target[e.ObjectID] = e
			}
		case "event":
			var row struct {
				Event harness.Event `json:"event"`
			}
			if json.Unmarshal(e.Data, &row) != nil || row.Event.Type != "stage.input" {
				continue
			}
			var input harness.StageInput
			if json.Unmarshal(row.Event.Data, &input) != nil || input.Stage != row.Event.Stage || input.Stage < 0 || input.Stage >= 32 || input.Attempt < 1 || input.Attempt > 1000 || !reflect.DeepEqual(input.Context, run.Context) || input.Goal != run.Goal {
				unreadable++
				continue
			}
			if stages[input.Stage] == nil {
				stages[input.Stage] = map[int]bool{}
			}
			stages[input.Stage][input.Attempt] = true
		}
	}
	committed := 0
	for id, e := range actions {
		var row struct {
			ActionID  string          `json:"action_id"`
			Type      string          `json:"action_type"`
			MessageID string          `json:"message_id"`
			Receipt   harness.Receipt `json:"receipt"`
		}
		var result struct {
			MessageID string `json:"message_id"`
			RoomID    string `json:"room_id"`
			Seq       int64  `json:"seq"`
			Canonical string `json:"canonical_status"`
		}
		if json.Unmarshal(e.Data, &row) != nil || json.Unmarshal(row.Receipt.Result, &result) != nil || row.ActionID != id || row.Receipt.ActionID != id || row.Type != "message.send" || row.Receipt.Status != "succeeded" || result.Canonical != "committed" || result.MessageID == "" || result.MessageID != row.MessageID || result.RoomID != run.Context.RoomID || result.Seq <= 0 {
			unreadable++
			continue
		}
		committed++
	}
	fmt.Fprintf(&b, "- 已提交消息动作：%d 条。依据服务端动作账本。\n", committed)
	counts := map[string]int{}
	for id, e := range transports {
		var row struct {
			ID       int64  `json:"outbox_id"`
			Provider string `json:"provider"`
			Status   string `json:"status"`
		}
		if json.Unmarshal(e.Data, &row) != nil || row.ID <= 0 || strconv.FormatInt(row.ID, 10) != id || row.Provider != "rongcloud" {
			unreadable++
			continue
		}
		switch row.Status {
		case "pending", "in_flight", "delivered", "unknown", "blocked", "rejected":
			counts[row.Status]++
		default:
			unreadable++
		}
	}
	if len(transports) == 0 {
		b.WriteString("- 融云运输：本次证据范围内没有运输记录。\n")
	} else {
		fmt.Fprintf(&b, "- 融云运输账本（各任务最近状态）：融云已受理 %d，待发送 %d，发送中 %d，结果未知 %d，已阻止 %d，已拒绝 %d。\n", counts["delivered"], counts["pending"], counts["in_flight"], counts["unknown"], counts["blocked"], counts["rejected"])
		b.WriteString("\n融云已受理不代表成员设备已收到或成员已读。\n")
	}
	stageIDs := make([]int, 0, len(stages))
	for stage := range stages {
		stageIDs = append(stageIDs, stage)
	}
	sort.Ints(stageIDs)
	if len(stageIDs) == 0 {
		b.WriteString("- 阶段输入记录：0 条。\n")
	} else {
		for _, stage := range stageIDs {
			fmt.Fprintf(&b, "- 阶段 %d：记录了 %d 次输入尝试。\n", stage+1, len(stages[stage]))
		}
		b.WriteString("\n输入尝试不代表模型已返回，也不代表动作已提交。\n")
	}
	if legacy > 0 {
		fmt.Fprintf(&b, "\n包含 %d 条旧数据快照；这些快照不能还原原始提交先后。\n", legacy)
	}
	if unreadable > 0 {
		fmt.Fprintf(&b, "\n另有 %d 条记录不符合当前摘要契约，请查看原始证据；未将其计为成功。\n", unreadable)
	}
	return strings.TrimRight(b.String(), "\n")
}
