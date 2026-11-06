package main

import (
	"context"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestCheckHealth(t *testing.T) {
	t.Run("healthy server", func(t *testing.T) {
		srv := httptest.NewServer(newRouter())
		defer srv.Close()

		if err := checkHealth(t.Context(), srv.URL+"/"); err != nil {
			t.Fatalf("checkHealth() = %v, want nil", err)
		}
	})

	t.Run("server returns an error status", func(t *testing.T) {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(http.StatusInternalServerError)
		}))
		defer srv.Close()

		if err := checkHealth(t.Context(), srv.URL+"/"); err == nil {
			t.Fatal("checkHealth() = nil, want an error")
		}
	})

	t.Run("nothing listening", func(t *testing.T) {
		srv := httptest.NewServer(newRouter())
		url := srv.URL + "/"
		srv.Close()

		if err := checkHealth(t.Context(), url); err == nil {
			t.Fatal("checkHealth() = nil, want an error")
		}
	})
}

func TestServeAnswersThenShutsDownGracefully(t *testing.T) {
	var lc net.ListenConfig
	ln, err := lc.Listen(t.Context(), "tcp", "127.0.0.1:0") // port 0: any free port
	if err != nil {
		t.Fatalf("listen: %v", err)
	}

	ctx, cancel := context.WithCancel(t.Context())
	done := make(chan error, 1)
	go func() { done <- serve(ctx, slog.New(slog.DiscardHandler), ln) }()

	// The listener is already bound, so the request cannot race the start-up.
	if err := checkHealth(t.Context(), "http://"+ln.Addr().String()+"/"); err != nil {
		t.Fatalf("server did not answer: %v", err)
	}

	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("serve() = %v, want nil after graceful shutdown", err)
		}
	case <-time.After(shutdownTimeout + time.Second):
		t.Fatal("serve() did not return after the context was cancelled")
	}
}

func TestPortFromEnv(t *testing.T) {
	tests := []struct {
		name    string
		value   string
		want    string
		wantErr bool
	}{
		{name: "unset uses default", value: "", want: defaultPort},
		{name: "valid port", value: "9090", want: "9090"},
		{name: "not a number", value: "http", wantErr: true},
		{name: "zero", value: "0", wantErr: true},
		{name: "too large", value: "70000", wantErr: true},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("PORT", tc.value)

			got, err := portFromEnv()
			if (err != nil) != tc.wantErr {
				t.Fatalf("portFromEnv() error = %v, wantErr %v", err, tc.wantErr)
			}
			if got != tc.want {
				t.Errorf("portFromEnv() = %q, want %q", got, tc.want)
			}
		})
	}
}
