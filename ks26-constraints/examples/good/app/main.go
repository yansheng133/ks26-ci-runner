// ks26 內部知識問答服務 —— 完整可跑範例
// 行為全部服務於現場驗收與敘事：首頁大字顯示 IMAGE_TAG（＝commit SHA）。
package main

import (
	"fmt"
	"html"
	"io"
	"net/http"
	"os"
	"strings"
)

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func main() {
	port := env("PORT", "8080")
	tag := env("IMAGE_TAG", "dev")
	owner := env("APP_OWNER", "unknown")
	inference := os.Getenv("INFERENCE_URL")

	// 存活探針：永遠 200，跟推論後端無關
	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		io.WriteString(w, "ok\n")
	})

	// 首頁：大字顯示 SHA —— 第 5 段驗收就看這個
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		host, _ := os.Hostname()
		mode := "degraded"
		if inference != "" {
			mode = "live"
		}
		// 標籤格式 group<N>-<sha>：組號小字、SHA 大字，投影幕上肉眼比對只看 SHA
		group, sha := "", tag
		if i := strings.LastIndex(tag, "-"); i > 0 {
			group, sha = tag[:i], tag[i+1:]
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		fmt.Fprintf(w, page, html.EscapeString(group), html.EscapeString(sha), html.EscapeString(tag),
			html.EscapeString(owner), html.EscapeString(host), mode)
	})

	// 問答：有後端就轉呼叫，沒有就降級回罐頭
	http.HandleFunc("/ask", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		if inference == "" {
			w.Header().Set("X-Mode", "degraded")
			io.WriteString(w, `{"mode":"degraded","answer":"目前無推論後端，這是罐頭回覆。"}`)
			return
		}
		resp, err := http.Post(inference, "application/json", r.Body)
		if err != nil {
			w.Header().Set("X-Mode", "degraded")
			io.WriteString(w, `{"mode":"degraded","answer":"推論後端目前無法回應。"}`)
			return
		}
		defer resp.Body.Close()
		w.WriteHeader(resp.StatusCode)
		io.Copy(w, resp.Body)
	})

	_ = http.ListenAndServe(":"+port, nil)
}

const page = `<!doctype html><meta charset="utf-8">
<title>ks26</title>
<style>body{font-family:system-ui,'Noto Sans TC',sans-serif;margin:0;
background:#0C322C;color:#fff;display:grid;place-items:center;height:100vh;text-align:center}
.sha{font-size:14vw;font-weight:800;color:#30BA78;font-family:ui-monospace,monospace;letter-spacing:.05em}
.grp{color:#90EBCD;font-size:2rem;letter-spacing:.2em}
.tag{margin-top:.5rem;color:#9db;font-family:ui-monospace,monospace}
.meta{margin-top:1rem;color:#90EBCD;font-size:1.1rem}
.mode{margin-top:.5rem;font-size:.9rem;color:#9db}</style>
<div><div class="grp">%s</div><div class="sha">%s</div><div class="tag">image tag = %s</div>
<div class="meta">owner = %s ・ host = %s</div>
<div class="mode">推論後端：%s</div></div>`
