package httpapi

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/huapohen/active-agent/services/collaboration/internal/store"
	"github.com/huapohen/active-agent/services/collaboration/internal/transport"
)

// MountRongCloudIngress receives operator-scoped notices from a trusted local
// SDK process. It is not a public RongCloud webhook and never issues SDK tokens.
// v1 must already have normal human/machine authentication middleware.
func MountRongCloudIngress(g *gin.Engine, v1 *gin.RouterGroup, s *store.Store, configured []transport.BridgeBinding) error {
	bindings := append([]transport.BridgeBinding(nil), configured...)
	byID := map[string]transport.BridgeBinding{}
	for _, b := range bindings {
		if !b.Valid() {
			return domain.ErrInvalid
		}
		if _, ok := byID[b.ID]; ok {
			return domain.ErrInvalid
		}
		byID[b.ID] = b
	}
	authorized := func(c *gin.Context) (transport.BridgeBinding, bool) {
		b, exists := byID[c.Param("bridge")]
		host, _, err := net.SplitHostPort(c.Request.RemoteAddr)
		ip := net.ParseIP(host)
		provided := strings.TrimPrefix(c.GetHeader("Authorization"), "Bearer ")
		wantHash, gotHash := sha256.Sum256([]byte(b.Secret)), sha256.Sum256([]byte(provided))
		if !exists || err != nil || ip == nil || !ip.IsLoopback() || c.GetHeader("Origin") != "" || !strings.HasPrefix(c.GetHeader("Authorization"), "Bearer ") || subtle.ConstantTimeCompare(wantHash[:], gotHash[:]) != 1 {
			c.AbortWithStatusJSON(403, gin.H{"error": "bridge_not_authorized"})
			return transport.BridgeBinding{}, false
		}
		return b, true
	}
	readBody := func(c *gin.Context) ([]byte, bool) {
		raw, err := io.ReadAll(io.LimitReader(c.Request.Body, 65537))
		if err != nil || len(raw) > 65536 {
			c.JSON(400, gin.H{"error": "invalid_request"})
			return nil, false
		}
		return raw, true
	}
	g.POST("/internal/transport/rongcloud/:bridge/received", func(c *gin.Context) {
		b, ok := authorized(c)
		if !ok {
			return
		}
		raw, ok := readBody(c)
		if !ok {
			return
		}
		receipt, err := s.RecordTransportIngress(c.Request.Context(), b, raw)
		if errors.Is(err, store.ErrIngressAwaitingAcceptance) {
			c.JSON(425, gin.H{"error": "canonical_acceptance_pending"})
			return
		}
		if err != nil {
			fail(c, err)
			return
		}
		c.JSON(200, gin.H{"schema": "renji.transport.ingress-receipt.v1", "arrival": receipt})
	})
	g.POST("/internal/transport/rongcloud/:bridge/heartbeat", func(c *gin.Context) {
		b, ok := authorized(c)
		if !ok {
			return
		}
		raw, ok := readBody(c)
		if !ok {
			return
		}
		var body struct {
			State    string `json:"state"`
			Sequence int64  `json:"sequence"`
		}
		d := json.NewDecoder(strings.NewReader(string(raw)))
		d.DisallowUnknownFields()
		if d.Decode(&body) != nil || d.Decode(new(any)) != io.EOF {
			c.JSON(400, gin.H{"error": "invalid_request"})
			return
		}
		if err := s.RecordTransportHeartbeat(c.Request.Context(), b, body.State, body.Sequence); err != nil {
			fail(c, err)
			return
		}
		c.JSON(200, gin.H{"accepted": true})
	})
	v1.GET("/transport/events", func(c *gin.Context) {
		q := c.Request.URL.Query()
		_, isMachine := machine(c)
		if !allowedQuery(q, "after", "limit", "run_id") || (!isMachine && q.Has("run_id")) {
			fail(c, domain.ErrInvalid)
			return
		}
		after := int64(0)
		limit := 50
		if q.Has("after") {
			n, e := strconv.ParseInt(q.Get("after"), 10, 64)
			if e != nil || n < 0 || n > 9007199254740991 {
				fail(c, domain.ErrInvalid)
				return
			}
			after = n
		}
		if q.Has("limit") {
			n, e := strconv.Atoi(q.Get("limit"))
			if e != nil || n < 1 || n > 100 {
				fail(c, domain.ErrInvalid)
				return
			}
			limit = n
		}
		page, err := nativeTransportArrivals(c, s, q.Get("run_id"), after, limit, bindings)
		if err != nil {
			fail(c, err)
			return
		}
		c.JSON(http.StatusOK, page)
	})
	return nil
}

// HTTP and MCP resolve the same authenticated receiver. A machine supplies only
// its Run ID, never a receiver ID, bridge scope or alternative principal.
func nativeTransportArrivals(c *gin.Context, s *store.Store, runID string, after int64, limit int, bindings []transport.BridgeBinding) (store.TransportArrivalPage, error) {
	if after < 0 || after > 9007199254740991 || limit < 1 || limit > 100 {
		return store.TransportArrivalPage{}, domain.ErrInvalid
	}
	if identity, ok := machine(c); ok {
		return s.ExecutionTransportArrivals(c.Request.Context(), identity.Issuer, identity.MachineSubject, runID, after, limit, bindings)
	}
	if runID != "" {
		return store.TransportArrivalPage{}, domain.ErrInvalid
	}
	return s.TransportArrivals(c.Request.Context(), principal(c).ID, after, limit, bindings)
}
