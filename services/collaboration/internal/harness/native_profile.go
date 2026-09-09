package harness

import (
	"context"
	"encoding/json"
	"net/http"
	"net/url"
	"unicode/utf8"

	"github.com/cloudwego/eino/components/tool"
	"github.com/cloudwego/eino/components/tool/utils"
	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
)

// Optional capability; older gateway fixtures and stored workflow versions do
// not need to implement profile reads or enable profile mutations.
type NativeProfileReader interface {
	NativeReadCapabilities() []string
	ReadProfile(context.Context, RunContext) (domain.Profile, error)
}

func validateNativeProfile(r RunContext, p domain.Profile) error {
	if p.Principal.ID != r.PrincipalID || p.Principal.Kind != "agent" {
		return ErrDenied
	}
	if p.Version < 1 || p.Principal.DisplayName == "" || !utf8.ValidString(p.Principal.DisplayName) || len(p.Principal.DisplayName) > 320 {
		return ErrInvalid
	}
	return nil
}

func (g *HTTPGateway) ReadProfile(ctx context.Context, r RunContext) (domain.Profile, error) {
	var out domain.Profile
	if !g.supportsNativeRead("profile.read") {
		return out, ErrDenied
	}
	if err := g.Check(ctx, r); err != nil {
		return out, err
	}
	query := url.Values{"run_id": {r.RunID}}
	if err := g.request(ctx, http.MethodGet, "/v1/profile?"+query.Encode(), nil, &out); err != nil {
		return domain.Profile{}, err
	}
	if err := validateNativeProfile(r, out); err != nil {
		return domain.Profile{}, err
	}
	if err := g.Check(ctx, r); err != nil {
		return domain.Profile{}, err
	}
	return out, nil
}

func nativeProfileTools(reader NativeProfileReader, trace *stageTrace) ([]tool.BaseTool, error) {
	available := false
	for _, capability := range reader.NativeReadCapabilities() {
		available = available || capability == "profile.read"
	}
	if !available {
		return nil, nil
	}
	t, err := utils.InferTool("im_profile_read", "Read this Agent's own canonical display name and optimistic profile version under all original Run scopes. Read before proposing profile.update; cannot select another identity.", func(ctx context.Context, _ struct{}) (string, error) {
		if err := trace.check(ctx); err != nil {
			return "", err
		}
		profile, err := reader.ReadProfile(ctx, trace.input.Context)
		if err != nil {
			return "", err
		}
		if err := validateNativeProfile(trace.input.Context, profile); err != nil {
			return "", err
		}
		if err := trace.check(ctx); err != nil {
			return "", err
		}
		raw, err := json.Marshal(profile)
		return string(raw), err
	})
	if err != nil {
		return nil, err
	}
	return []tool.BaseTool{t}, nil
}
