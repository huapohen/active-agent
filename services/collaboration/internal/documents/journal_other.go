//go:build !darwin && !linux && !freebsd && !openbsd && !netbsd

package documents

import "os"

func lockJournal(*os.File) error { return Failure("transactional_store_required_on_this_platform") }
