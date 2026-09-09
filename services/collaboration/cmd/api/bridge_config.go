package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"

	"github.com/huapohen/active-agent/services/collaboration/internal/transport"
)

func loadBridgeBindings(path string) ([]transport.BridgeBinding, error) {
	if path == "" {
		return nil, nil
	}
	invalid := errors.New("invalid_bridge_configuration")
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 || info.Size() > 65536 {
		return nil, invalid
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, invalid
	}
	defer f.Close()
	opened, err := f.Stat()
	if err != nil || !os.SameFile(info, opened) {
		return nil, invalid
	}
	raw, err := io.ReadAll(io.LimitReader(f, 65537))
	if err != nil || len(raw) > 65536 {
		return nil, invalid
	}
	var bindings []transport.BridgeBinding
	d := json.NewDecoder(bytes.NewReader(raw))
	d.DisallowUnknownFields()
	if d.Decode(&bindings) != nil || d.Decode(new(any)) != io.EOF || bindings == nil || len(bindings) > 100 {
		return nil, invalid
	}
	seen := map[string]bool{}
	for _, binding := range bindings {
		if !binding.Valid() || seen[binding.ID] {
			return nil, invalid
		}
		seen[binding.ID] = true
	}
	return bindings, nil
}
