package main

import (
	"context"
	"flag"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/huapohen/active-agent/services/collaboration/internal/auth"
	"github.com/huapohen/active-agent/services/collaboration/internal/emoji"
	"github.com/huapohen/active-agent/services/collaboration/internal/httpapi"
	"github.com/huapohen/active-agent/services/collaboration/internal/store"
	"github.com/huapohen/active-agent/services/collaboration/internal/transport"
)

func main() {
	migrate := flag.Bool("migrate", false, "apply versioned startup schema before serving")
	flag.Parse()
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	dsn := os.Getenv("RENJI_DATABASE_URL")
	if dsn == "" {
		log.Fatal("RENJI_DATABASE_URL required")
	}
	s, err := store.Open(ctx, dsn)
	if err != nil {
		log.Fatal("startup PostgreSQL unavailable; connection details withheld")
	}
	defer s.Close()
	if *migrate {
		if err = s.Migrate(ctx); err != nil {
			log.Fatal("schema migration failed; details withheld")
		}
	}
	origins := strings.Split(os.Getenv("RENJI_AUTHORIZED_PARTIES"), ",")
	v, err := auth.NewClerk(os.Getenv("CLERK_ISSUER"), origins)
	if err != nil {
		log.Fatal("Clerk issuer and authorized parties required")
	}
	r, err := transport.NewRongCloud(os.Getenv("RONGCLOUD_API_URL"), os.Getenv("RONGCLOUD_APP_KEY"), os.Getenv("RONGCLOUD_APP_SECRET"))
	if err != nil {
		log.Fatal("RongCloud is required; configure API URL, App Key and App Secret")
	}
	addr := os.Getenv("RENJI_LISTEN")
	if addr == "" {
		addr = "127.0.0.1:3318"
	}
	options := []httpapi.Option{httpapi.WithTransportTestPrincipals(strings.FieldsFunc(os.Getenv("RENJI_RONGCLOUD_TEST_PRINCIPALS"), func(r rune) bool { return r == ',' || r == ' ' || r == '\n' }))}
	bridges, err := loadBridgeBindings(os.Getenv("RENJI_RONGCLOUD_BRIDGE_CONFIG"))
	if err != nil {
		log.Fatal("RongCloud receiver configuration invalid; verify private file permissions and bindings")
	}
	options = append(options, httpapi.WithRongCloudBridges(bridges))
	if dir := os.Getenv("RENJI_EMOJI_DIR"); dir != "" {
		catalog, err := emoji.NewLocal(dir)
		if err != nil {
			log.Fatal("Emoji bundle invalid; verify explicit absolute RENJI_EMOJI_DIR and pinned asset manifest")
		}
		options = append(options, httpapi.WithEmojiProvider(catalog))
	}
	if os.Getenv("CLERK_RECEIVER_MACHINE_ID") != "" || os.Getenv("CLERK_MACHINE_SECRET_KEY") != "" {
		machine, err := auth.NewClerkMachine(auth.ClerkMachineConfig{Issuer: os.Getenv("CLERK_ISSUER"), ReceiverMachineID: os.Getenv("CLERK_RECEIVER_MACHINE_ID"), MachineSecretKey: os.Getenv("CLERK_MACHINE_SECRET_KEY"), AllowNonExpiring: os.Getenv("CLERK_ALLOW_NONEXPIRING_MACHINE_TOKENS") == "true"})
		if err != nil {
			log.Fatal("Clerk machine verification configuration incomplete; details withheld")
		}
		options = append(options, httpapi.WithMachineVerifier(machine))
	}
	server := &http.Server{Addr: addr, Handler: httpapi.New(s, v, r, origins, options...), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 15 * time.Second, WriteTimeout: 20 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 32 << 10}
	go func() {
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		server.Shutdown(shutdown)
	}()
	log.Print("Renji startup API starting; transport=rongcloud; auth=clerk")
	if err = server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatal("API listener failed")
	}
}
