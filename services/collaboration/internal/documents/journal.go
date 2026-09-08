package documents

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sync"
)

type journalEntry struct {
	Previous string `json:"previous"`
	Record   Record `json:"record"`
	Hash     string `json:"hash"`
}
type FileJournal struct {
	file    *os.File
	records map[string]Record
	chain   string
	gate    chan struct{}
	mu      sync.Mutex
	failed  bool
}

// OpenFileJournal holds an OS lock for the worker lifetime. It is released on
// process exit, including crashes. Hash chaining detects accidental corruption;
// it does not protect against a privileged administrator rewriting the journal.
func OpenFileJournal(path string) (*FileJournal, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return nil, Failure("journal_unavailable")
	}
	if info, err := os.Lstat(path); err == nil && (info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0) {
		return nil, Failure("private_journal_required")
	} else if err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, Failure("journal_unavailable")
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR|os.O_APPEND, 0600)
	if err != nil {
		return nil, Failure("journal_unavailable")
	}
	if err := lockJournal(f); err != nil {
		f.Close()
		return nil, err
	}
	j := &FileJournal{file: f, records: map[string]Record{}, gate: make(chan struct{}, 1)}
	reader := bufio.NewReaderSize(f, 32000)
	for {
		line, err := reader.ReadSlice('\n')
		if err == io.EOF && len(line) == 0 {
			break
		}
		if err != nil || len(line) > 32000 {
			f.Close()
			return nil, Failure("journal_corrupt")
		}
		var entry journalEntry
		if json.Unmarshal(line, &entry) != nil || entry.Previous != j.chain {
			f.Close()
			return nil, Failure("journal_corrupt")
		}
		raw, _ := json.Marshal(entry.Record)
		old := j.records[entry.Record.BindingID]
		if entry.Hash != Hash(entry.Previous+"\n"+string(raw)) || entry.Record.BindingID == "" || entry.Record.Sequence != old.Sequence+1 {
			f.Close()
			return nil, Failure("journal_corrupt")
		}
		j.records[entry.Record.BindingID] = entry.Record
		j.chain = entry.Hash
	}
	// Persist the directory entry before the first external effect.
	dir, err := os.Open(filepath.Dir(path))
	if err != nil {
		f.Close()
		return nil, Failure("journal_unavailable")
	}
	err = dir.Sync()
	dir.Close()
	if err != nil {
		f.Close()
		return nil, Failure("journal_unavailable")
	}
	return j, nil
}
func (j *FileJournal) Lock(ctx context.Context) (func(), error) {
	select {
	case j.gate <- struct{}{}:
		return func() { <-j.gate }, nil
	case <-ctx.Done():
		return nil, Failure("cancelled")
	}
}
func (j *FileJournal) Latest(id string) (Record, bool) {
	j.mu.Lock()
	defer j.mu.Unlock()
	r, ok := j.records[id]
	return r, ok
}
func (j *FileJournal) Append(r Record) error {
	j.mu.Lock()
	defer j.mu.Unlock()
	if j.failed || r.Sequence != j.records[r.BindingID].Sequence+1 {
		return Failure("journal_unavailable")
	}
	raw, err := json.Marshal(r)
	if err != nil {
		return Failure("invalid_receipt")
	}
	entry := journalEntry{Previous: j.chain, Record: r, Hash: Hash(j.chain + "\n" + string(raw))}
	line, err := json.Marshal(entry)
	if err != nil {
		return Failure("invalid_receipt")
	}
	line = append(line, '\n')
	n, err := j.file.Write(line)
	if err != nil || n != len(line) {
		j.failed = true
		return Failure("journal_unavailable")
	}
	if err = j.file.Sync(); err != nil {
		j.failed = true
		return Failure("journal_unavailable")
	}
	j.chain = entry.Hash
	j.records[r.BindingID] = r
	return nil
}
func (j *FileJournal) Close() error { return j.file.Close() }
