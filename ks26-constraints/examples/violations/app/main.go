package main

import (
	"fmt"
	"net/http"
	"os"
)

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	tag := os.Getenv("IMAGE_TAG")
	owner := os.Getenv("APP_OWNER")
	inference := os.Getenv("INFERENCE_URL")

	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		fmt.Fprintln(w, "ok")
	})

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		host, _ := os.Hostname()
		fmt.Fprintf(w, "<h1 style=\"font-size:64px\">%s</h1><p>owner=%s host=%s</p>", tag, owner, host)
	})

	http.HandleFunc("/ask", func(w http.ResponseWriter, r *http.Request) {
		if inference == "" {
			// degraded mode：沒有推論後端時回罐頭答案，服務照常存活
			w.Header().Set("X-Mode", "degraded")
			fmt.Fprintln(w, "degraded mode - no inference backend configured")
			return
		}
		resp, err := http.Post(inference, "application/json", r.Body)
		if err != nil {
			w.Header().Set("X-Mode", "degraded")
			fmt.Fprintln(w, "degraded mode - inference backend unreachable")
			return
		}
		defer resp.Body.Close()
		w.WriteHeader(resp.StatusCode)
	})

	_ = http.ListenAndServe(":"+port, nil)
}
