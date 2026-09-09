package httpapi

import (
	"github.com/gin-gonic/gin"
	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
)

// Only list reads attest to an empty conversation. A policy/create receipt
// must not erase a client's real message summary by inventing an empty preview.
type roomListItem struct {
	domain.Room
	LastMessage *domain.RoomPreview `json:"last_message"`
}

func roomListPage(rooms []domain.Room) gin.H {
	cursor := ""
	if len(rooms) > 100 {
		rooms = rooms[:100]
		cursor = rooms[99].ID
	}
	items := make([]roomListItem, len(rooms))
	for i := range rooms {
		items[i] = roomListItem{Room: rooms[i], LastMessage: rooms[i].LastMessage}
	}
	return gin.H{"rooms": items, "cursor": cursor}
}
