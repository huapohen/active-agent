// transport-policy-check only observes the named group's provider mute policy.
// It cannot change settings, issue tokens, publish messages, or unlock clients.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/huapohen/active-agent/services/collaboration/internal/transport"
)

func main() {
	file := flag.String("env-file", "", "private 0600 rongcloud.env file")
	group := flag.String("group", "", "one exact controlled provider group ID")
	flag.Parse()
	if *file == "" || *group == "" || flag.NArg() != 0 {
		fail("arguments_invalid")
	}
	config, err := readConfig(*file)
	if err != nil {
		fail("configuration_unavailable")
	}
	r, err := transport.NewRongCloud(config["RONGCLOUD_API_URL"], config["RONGCLOUD_APP_KEY"], config["RONGCLOUD_APP_SECRET"])
	if err != nil {
		fail("configuration_invalid")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 40*time.Second)
	defer cancel()
	result, err := r.ReadGroupWritePolicy(ctx, *group)
	if err != nil {
		var pe *transport.ProviderError
		if errors.As(err, &pe) {
			fail(fmt.Sprintf("provider_observation_failed_%d_unknown_%t", pe.Code, pe.Unknown))
		}
		if errors.Is(err, transport.ErrPolicyChanged) {
			fail("provider_policy_changed")
		}
		fail("policy_observation_unavailable")
	}
	if json.NewEncoder(os.Stdout).Encode(result) != nil {
		fail("output_unavailable")
	}
}

func fail(code string) {
	_ = json.NewEncoder(os.Stderr).Encode(map[string]string{"state": "stopped", "code": code})
	os.Exit(1)
}

// Parse data, never source a shell file or expand substitutions. Reject broad
// permissions and duplicates so the inspected provider namespace is explicit.
func readConfig(path string) (map[string]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, errors.New("config")
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 || info.Size() > 65536 {
		return nil, errors.New("config")
	}
	values := map[string]string{}
	scan := bufio.NewScanner(f)
	for scan.Scan() {
		line := strings.TrimSpace(scan.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok {
			return nil, errors.New("config")
		}
		key, value = strings.TrimSpace(key), strings.TrimSpace(value)
		if key != "RONGCLOUD_API_URL" && key != "RONGCLOUD_APP_KEY" && key != "RONGCLOUD_APP_SECRET" {
			continue
		}
		if _, exists := values[key]; exists {
			return nil, errors.New("config")
		}
		if len(value) >= 2 && ((value[0] == '"' && value[len(value)-1] == '"') || (value[0] == '\'' && value[len(value)-1] == '\'')) {
			value = value[1 : len(value)-1]
		}
		if value == "" {
			return nil, errors.New("config")
		}
		values[key] = value
	}
	if scan.Err() != nil || len(values) != 3 {
		return nil, errors.New("config")
	}
	return values, nil
}
