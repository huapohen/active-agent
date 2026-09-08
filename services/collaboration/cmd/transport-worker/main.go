package main

import (
	"context"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/huapohen/active-agent/services/collaboration/internal/store"
	"github.com/huapohen/active-agent/services/collaboration/internal/transport"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	s, err := store.Open(ctx, os.Getenv("RENJI_DATABASE_URL"))
	if err != nil {
		log.Fatal("startup database unavailable")
	}
	defer s.Close()
	r, err := transport.NewRongCloud(os.Getenv("RONGCLOUD_API_URL"), os.Getenv("RONGCLOUD_APP_KEY"), os.Getenv("RONGCLOUD_APP_SECRET"))
	if err != nil {
		log.Fatal("RongCloud configuration required")
	}
	tick := time.NewTicker(100 * time.Millisecond)
	defer tick.Stop()
	log.Print("RongCloud transport worker started")
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
			if err = s.QuarantineStaleDeliveries(ctx); err != nil {
				log.Print("outbox quarantine unavailable")
				continue
			}
			if _, err = s.DispatchOne(ctx, r); err != nil {
				log.Print("outbox persistence unavailable")
			}
		}
	}
}
