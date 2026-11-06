// Command server is the HTTP service for the DevOps screening task.
//
// It listens on $PORT (default 8080) and stops gracefully on SIGINT or
// SIGTERM. Run with -healthcheck to probe a running instance; the container
// image uses this for its HEALTHCHECK because it has no shell or curl.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"
)

const (
	defaultPort = "8080"

	// Go's http.Server has no timeouts by default, which lets slow clients
	// hold connections open forever (Slowloris).
	readHeaderTimeout = 5 * time.Second
	readTimeout       = 10 * time.Second
	writeTimeout      = 10 * time.Second
	idleTimeout       = 60 * time.Second

	// shutdownTimeout stays below Docker's default 10s stop grace period, so
	// in-flight requests finish before the container would receive SIGKILL.
	shutdownTimeout = 5 * time.Second

	healthcheckTimeout = 2 * time.Second
)

func main() {
	healthcheck := flag.Bool("healthcheck", false, "probe the server on $PORT and exit 0 if healthy, 1 if not")
	flag.Parse()

	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))

	port, err := portFromEnv()
	if err != nil {
		logger.Error("invalid configuration", "error", err)
		os.Exit(1)
	}

	if *healthcheck {
		url := "http://" + net.JoinHostPort("127.0.0.1", port) + "/"
		if err := checkHealth(context.Background(), url); err != nil {
			fmt.Fprintln(os.Stderr, "unhealthy:", err)
			os.Exit(1)
		}
		return
	}

	if err := run(context.Background(), logger, port); err != nil {
		logger.Error("server stopped", "error", err)
		os.Exit(1)
	}
}

// run listens on port and serves until the process receives SIGINT or
// SIGTERM, then drains open connections before returning.
func run(ctx context.Context, logger *slog.Logger, port string) error {
	ctx, stop := signal.NotifyContext(ctx, os.Interrupt, syscall.SIGTERM)
	defer stop()

	// Bind before serving so a port that is already in use fails right away
	// with a clear error, and "listening" is only logged once it is true.
	var lc net.ListenConfig
	ln, err := lc.Listen(ctx, "tcp", ":"+port)
	if err != nil {
		return fmt.Errorf("listen on port %s: %w", port, err)
	}
	return serve(ctx, logger, ln)
}

// serve handles HTTP requests on ln until ctx is cancelled, then shuts the
// server down gracefully. It takes a listener so tests can use a free port.
func serve(ctx context.Context, logger *slog.Logger, ln net.Listener) error {
	srv := &http.Server{
		Handler:           newRouter(),
		ReadHeaderTimeout: readHeaderTimeout,
		ReadTimeout:       readTimeout,
		WriteTimeout:      writeTimeout,
		IdleTimeout:       idleTimeout,
		ErrorLog:          slog.NewLogLogger(logger.Handler(), slog.LevelError),
	}
	logger.Info("server listening", "addr", ln.Addr().String())

	serveErr := make(chan error, 1)
	go func() { serveErr <- srv.Serve(ln) }()

	select {
	case err := <-serveErr:
		return fmt.Errorf("serve: %w", err)
	case <-ctx.Done():
	}

	logger.Info("shutdown signal received, draining connections", "timeout", shutdownTimeout.String())
	shutdownCtx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		return fmt.Errorf("graceful shutdown: %w", err)
	}
	if err := <-serveErr; !errors.Is(err, http.ErrServerClosed) {
		return fmt.Errorf("serve: %w", err)
	}
	logger.Info("shutdown complete")
	return nil
}

// portFromEnv returns $PORT, or defaultPort when it is unset.
func portFromEnv() (string, error) {
	port := os.Getenv("PORT")
	if port == "" {
		return defaultPort, nil
	}
	n, err := strconv.Atoi(port)
	if err != nil || n < 1 || n > 65535 {
		return "", fmt.Errorf("PORT must be a number from 1 to 65535, got %q", port)
	}
	return port, nil
}

// checkHealth returns nil if a GET request to url answers 200 OK in time.
func checkHealth(ctx context.Context, url string) error {
	ctx, cancel := context.WithTimeout(ctx, healthcheckTimeout)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("unexpected status %d from %s", resp.StatusCode, url)
	}
	return nil
}
