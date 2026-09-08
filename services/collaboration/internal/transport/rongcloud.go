package transport

import (
	"context"
	"crypto/rand"
	"crypto/sha1" // Required by RongCloud's documented API signature protocol.
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
)

// RongCloud is required by the startup deployment. Business authorization and
// canonical message sequences stay in the collaboration kernel.
type RongCloud struct {
	base, key, secret string
	client            *http.Client
}
type ProviderError struct {
	Code    int
	Unknown bool
}

func (e *ProviderError) Error() string {
	return fmt.Sprintf("rongcloud_request_failed code=%d unknown=%t", e.Code, e.Unknown)
}

type Session struct {
	AppKey string `json:"app_key"`
	UserID string `json:"user_id"`
	Token  string `json:"token"`
}
type Delivery struct {
	Code        int `json:"code"`
	MessageUIDs []struct {
		GroupID    string `json:"groupId"`
		MessageUID string `json:"messageUID"`
	} `json:"messageUIDs"`
}

func NewRongCloud(base, key, secret string) (*RongCloud, error) {
	u, err := url.Parse(base)
	if err != nil || u.User != nil || u.RawQuery != "" || u.Fragment != "" || u.Path != "" || u.Hostname() == "" || key == "" || secret == "" {
		return nil, errors.New("RongCloud configuration incomplete")
	}
	if u.Scheme != "https" && !(u.Scheme == "http" && (u.Hostname() == "127.0.0.1" || u.Hostname() == "localhost")) {
		return nil, errors.New("RongCloud requires HTTPS")
	}
	return &RongCloud{base: base, key: key, secret: secret, client: &http.Client{Timeout: 8 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}}, nil
}
func (r *RongCloud) post(ctx context.Context, path string, form url.Values, out any) error {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return err
	}
	nonce := hex.EncodeToString(b)
	stamp := strconv.FormatInt(time.Now().Unix(), 10)
	h := sha1.Sum([]byte(r.secret + nonce + stamp))
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, r.base+path, strings.NewReader(form.Encode()))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("App-Key", r.key)
	req.Header.Set("Nonce", nonce)
	req.Header.Set("Timestamp", stamp)
	req.Header.Set("Signature", hex.EncodeToString(h[:]))
	resp, err := r.client.Do(req)
	if err != nil {
		return &ProviderError{Unknown: true}
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 262145))
	if err != nil || len(raw) > 262144 {
		return &ProviderError{Unknown: true}
	}
	var status struct {
		Code int `json:"code"`
	}
	if json.Unmarshal(raw, &status) != nil {
		return &ProviderError{Code: resp.StatusCode, Unknown: true}
	}
	if resp.StatusCode != 200 || status.Code != 200 {
		return &ProviderError{Code: status.Code, Unknown: resp.StatusCode >= 500}
	}
	if out != nil && json.Unmarshal(raw, out) != nil {
		return &ProviderError{Unknown: true}
	}
	return nil
}
func (r *RongCloud) Session(ctx context.Context, p domain.Principal) (Session, error) {
	var result struct {
		Code   int    `json:"code"`
		UserID string `json:"userId"`
		Token  string `json:"token"`
	}
	err := r.post(ctx, "/user/getToken.json", url.Values{"userId": {p.ID}, "name": {p.DisplayName}}, &result)
	if err != nil {
		return Session{}, err
	}
	if result.UserID != p.ID || result.Token == "" {
		return Session{}, &ProviderError{Unknown: true}
	}
	return Session{AppKey: r.key, UserID: p.ID, Token: result.Token}, nil
}
func (r *RongCloud) CreateGroup(ctx context.Context, room domain.Room, members []string) error {
	if len(members) == 0 {
		return errors.New("empty transport group")
	}
	return r.post(ctx, "/group/create.json", url.Values{"userId": members, "groupId": {room.ID}, "groupName": {room.Title}}, nil)
}
func (r *RongCloud) Publish(ctx context.Context, m domain.Message) (Delivery, error) {
	extra, _ := json.Marshal(map[string]any{"schema": "renji.message.v1", "room_id": m.RoomID, "message_id": m.ID, "seq": m.Seq})
	body, _ := json.Marshal(map[string]string{"content": m.Content, "extra": string(extra)})
	var d Delivery
	err := r.post(ctx, "/message/group/publish.json", url.Values{"fromUserId": {m.AuthorID}, "toGroupId": {m.RoomID}, "objectName": {"RC:TxtMsg"}, "content": {string(body)}, "isIncludeSender": {"1"}, "isPersisted": {"1"}}, &d)
	if err != nil {
		return d, err
	}
	for _, v := range d.MessageUIDs {
		if v.GroupID == m.RoomID && v.MessageUID != "" {
			return d, nil
		}
	}
	return d, &ProviderError{Unknown: true}
}
