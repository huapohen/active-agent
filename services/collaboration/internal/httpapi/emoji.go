package httpapi

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/huapohen/active-agent/services/collaboration/internal/emoji"
	"github.com/huapohen/active-agent/services/collaboration/internal/store"
)

var errEmojiUnavailable = errors.New("emoji_catalog_unavailable")

// Reject unknown and repeated query parameters instead of treating a typo as
// a broader read. Both UI and native exports can fence pages by revision.
func allowedQuery(q url.Values, fields ...string) bool {
	allowed := map[string]bool{}
	for _, key := range fields {
		allowed[key] = true
	}
	for key, values := range q {
		if !allowed[key] || len(values) != 1 {
			return false
		}
	}
	return true
}

func readEmojiQuery(q url.Values) (emoji.Query, error) {
	out := emoji.Query{Q: q.Get("q"), Category: q.Get("category"), Revision: q.Get("revision")}
	if !allowedQuery(q, "q", "category", "revision", "offset", "limit", "run_id") {
		return out, domain.ErrInvalid
	}
	for key, dest := range map[string]*int{"offset": &out.Offset, "limit": &out.Limit} {
		if value, exists := q[key]; exists {
			n, err := strconv.Atoi(value[0])
			if err != nil || n < 0 || (key == "limit" && (n == 0 || n > 200)) {
				return out, domain.ErrInvalid
			}
			*dest = n
		}
	}
	return out, nil
}

func emojiPage(ctx context.Context, provider emoji.Provider, q emoji.Query) (emoji.Page, error) {
	if provider == nil {
		return emoji.Page{}, errEmojiUnavailable
	}
	page, err := provider.List(ctx, q)
	if err != nil {
		return emoji.Page{}, err
	}
	for i := range page.Entries {
		if page.Entries[i].Asset != "" {
			page.Entries[i].Asset = "/v1/emoji/assets/" + page.Entries[i].Asset
		}
	}
	return page, nil
}

func emojiEntry(ctx context.Context, provider emoji.Provider, id string) (emoji.Entry, error) {
	if provider == nil {
		return emoji.Entry{}, errEmojiUnavailable
	}
	entry, err := provider.Get(ctx, id)
	if err != nil {
		return emoji.Entry{}, err
	}
	if entry.Asset != "" {
		entry.Asset = "/v1/emoji/assets/" + entry.Asset
	}
	return entry, nil
}

// Catalog data is shared, but a run-bound native tool must stop when its current
// executor or any inherited source scope no longer authorizes execution.
func authorizeEmojiRun(c *gin.Context, s *store.Store, runID string) error {
	if runID == "" {
		return nil
	}
	m, ok := machine(c)
	if !ok || !validID(runID) {
		return domain.ErrInvalid
	}
	_, err := s.ExecutionRooms(c.Request.Context(), m.Issuer, m.MachineSubject, runID, "")
	return err
}

func mountEmoji(v1 *gin.RouterGroup, s *store.Store, provider emoji.Provider) {
	v1.GET("/emoji", func(c *gin.Context) {
		q, err := readEmojiQuery(c.Request.URL.Query())
		if err != nil {
			fail(c, err)
			return
		}
		if err := authorizeEmojiRun(c, s, c.Query("run_id")); err != nil {
			fail(c, err)
			return
		}
		page, err := emojiPage(c.Request.Context(), provider, q)
		if err != nil {
			fail(c, err)
			return
		}
		if err := authorizeEmojiRun(c, s, c.Query("run_id")); err != nil {
			fail(c, err)
			return
		}
		encoded, err := json.Marshal(page)
		if err != nil {
			fail(c, err)
			return
		}
		digest := sha256.Sum256(encoded)
		c.Header("ETag", "\""+hex.EncodeToString(digest[:])+"\"")
		c.Header("Access-Control-Expose-Headers", "ETag")
		c.Data(http.StatusOK, "application/json; charset=utf-8", encoded)
	})
	v1.GET("/emoji/entries/:emoji", func(c *gin.Context) {
		if !allowedQuery(c.Request.URL.Query(), "run_id") {
			fail(c, domain.ErrInvalid)
			return
		}
		if err := authorizeEmojiRun(c, s, c.Query("run_id")); err != nil {
			fail(c, err)
			return
		}
		entry, err := emojiEntry(c.Request.Context(), provider, c.Param("emoji"))
		if err != nil {
			fail(c, err)
			return
		}
		if err := authorizeEmojiRun(c, s, c.Query("run_id")); err != nil {
			fail(c, err)
			return
		}
		c.JSON(http.StatusOK, gin.H{"entry": entry})
	})
	v1.GET("/emoji/assets/*path", func(c *gin.Context) {
		if provider == nil {
			fail(c, errEmojiUnavailable)
			return
		}
		if !allowedQuery(c.Request.URL.Query(), "run_id") {
			fail(c, domain.ErrInvalid)
			return
		}
		if err := authorizeEmojiRun(c, s, c.Query("run_id")); err != nil {
			fail(c, err)
			return
		}
		path := strings.TrimPrefix(c.Param("path"), "/")
		asset, err := provider.Asset(c.Request.Context(), path)
		if err != nil {
			fail(c, err)
			return
		}
		if err := authorizeEmojiRun(c, s, c.Query("run_id")); err != nil {
			fail(c, err)
			return
		}
		// Authentication always precedes conditional reads. Credentials cannot be
		// put in a URL, nor can a public cache serve another identity's request.
		c.Header("ETag", asset.ETag)
		c.Header("Access-Control-Expose-Headers", "ETag")
		if match := c.GetHeader("If-Match"); match != "" && match != "*" && match != asset.ETag {
			c.JSON(http.StatusPreconditionFailed, gin.H{"error": "emoji_asset_changed"})
			return
		}
		if c.GetHeader("If-None-Match") == asset.ETag {
			c.Status(http.StatusNotModified)
			return
		}
		c.Data(http.StatusOK, asset.ContentType, asset.Data)
	})
}
