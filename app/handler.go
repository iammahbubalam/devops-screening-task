package main

import (
	"encoding/json"
	"net/http"
)

// statusResponse is the body returned by the root endpoint.
type statusResponse struct {
	Message string `json:"message"`
	Status  string `json:"status"`
}

// newRouter returns the service's HTTP handler.
//
// "GET /{$}" matches the exact path "/" only. The mux answers 404 for any
// other path and 405 for any other method on "/". GET routes also serve HEAD.
func newRouter() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", handleRoot)
	return mux
}

func handleRoot(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, statusResponse{
		Message: "Hello from DevOps Intern Task!",
		Status:  "running",
	})
}

// writeJSON sends v as a JSON response with the given status code.
func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(status)
	// The status line is already sent, so an encoding error could only be
	// logged here. Every value passed in is a fixed struct that always encodes.
	_ = json.NewEncoder(w).Encode(v)
}
