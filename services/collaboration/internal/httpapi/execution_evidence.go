package httpapi

import (
	"github.com/gin-gonic/gin"
	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/huapohen/active-agent/services/collaboration/internal/store"
	"strconv"
)

func evidenceReader(c *gin.Context) store.EvidenceReader {
	if m, ok := machine(c); ok {
		return store.EvidenceReader{MachineIssuer: m.Issuer, MachineSubject: m.MachineSubject}
	}
	return store.EvidenceReader{PrincipalID: principal(c).ID}
}
func nativeExecutionEvidence(c *gin.Context, s *store.Store, runID string, q store.EvidenceQuery) (store.ExecutionEvidencePage, error) {
	return s.ReadExecutionEvidence(c.Request.Context(), evidenceReader(c), runID, q)
}
func mountExecutionEvidence(v1 *gin.RouterGroup, s *store.Store) {
	v1.GET("/runs/:run/evidence", func(c *gin.Context) {
		for key, values := range c.Request.URL.Query() {
			if len(values) != 1 || (key != "after" && key != "through" && key != "limit" && key != "mode") {
				fail(c, domain.ErrInvalid)
				return
			}
		}
		q := store.EvidenceQuery{Mode: c.Query("mode")}
		var err error
		if v, ok := c.GetQuery("after"); ok {
			q.After, err = strconv.ParseInt(v, 10, 64)
			if err != nil {
				fail(c, domain.ErrInvalid)
				return
			}
		}
		if v, ok := c.GetQuery("through"); ok {
			n, e := strconv.ParseInt(v, 10, 64)
			if e != nil {
				fail(c, domain.ErrInvalid)
				return
			}
			q.Through = &n
		}
		if v, ok := c.GetQuery("limit"); ok {
			q.Limit, err = strconv.Atoi(v)
			if err != nil || q.Limit < 1 {
				fail(c, domain.ErrInvalid)
				return
			}
		}
		result, err := nativeExecutionEvidence(c, s, c.Param("run"), q)
		if err != nil {
			fail(c, err)
			return
		}
		c.JSON(200, result)
	})
}
