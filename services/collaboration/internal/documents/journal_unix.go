//go:build darwin || linux || freebsd || openbsd || netbsd

package documents

import (
	"os"
	"syscall"
)

func lockJournal(f *os.File) error {
	if syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB) != nil {
		return Failure("journal_in_use")
	}
	return nil
}
