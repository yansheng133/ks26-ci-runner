#!/usr/bin/env bash
# ks26 約束驗證器 —— 逐條檢查產出物是否符合硬性限制表
# 用法：./verify.sh [專案根目錄]   預設為當前目錄
# 回傳：全過 0；有任何一條沒過 1
set -uo pipefail

ROOT="${1:-.}"
PASS=0; FAIL=0
RED=$'\033[31m'; GRN=$'\033[32m'; DIM=$'\033[2m'; RST=$'\033[0m'
[ -t 1 ] || { RED=; GRN=; DIM=; RST=; }

# yq 不在本機就用容器跑，學員不必額外安裝任何東西
if ! command -v yq >/dev/null 2>&1; then
  for RT in docker podman nerdctl; do
    if command -v "$RT" >/dev/null 2>&1; then
      yq() { "$RT" run --rm -i -v "$PWD:/w" -w /w docker.io/mikefarah/yq:4 "$@"; }
      echo "${DIM}yq 不在本機，改用 $RT 執行容器版${RST}"
      break
    fi
  done
fi
command -v yq >/dev/null 2>&1 || declare -F yq >/dev/null || {
  echo "找不到 yq，也找不到容器工具。請擇一安裝後重跑。"; exit 2; }

# 冒煙測試：容器 daemon 沒起來時，yq 會安靜地回空字串，導致整份報告是假的
if ! printf 'a: 1\n' | yq -r '.a' - 2>/dev/null | grep -q '^1$'; then
  echo "yq 叫得到但讀不出東西（容器 daemon 沒起來？）。先修好再驗，否則這份報告是假的。"
  exit 2
fi

ok()   { PASS=$((PASS+1)); printf '  %sPASS%s  %s\n' "$GRN" "$RST" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  %sFAIL%s  %s\n' "$RED" "$RST" "$1"; printf '        %s\n' "$2"; }
head_() { printf '\n%s\n' "$1"; }

DEPLOY="$ROOT/deploy"
D="$DEPLOY/deployment.yaml"
S="$DEPLOY/service.yaml"
CM="$DEPLOY/configmap.yaml"
DF="$ROOT/Dockerfile"
BS="$ROOT/build.sh"
APP="$ROOT/app"

miss=0
for f in "$D" "$S" "$DF"; do
  [ -f "$f" ] || { echo "缺少必要檔案：$f"; miss=1; }
done
[ "$miss" -eq 0 ] || { echo; echo "產出物結構不完整，先補齊再驗。"; exit 2; }

q() { yq -r "$1" "$2" 2>/dev/null; }

head_ "C01 · 單一 HTTP 埠，埠號由環境變數指定"
CPORT=$(q '.spec.template.spec.containers[0].ports[0].containerPort // ""' "$D")
TPORT=$(q '.spec.ports[0].targetPort // ""' "$S")
if [ -n "$CPORT" ] && [ "$CPORT" = "$TPORT" ]; then
  ok "containerPort 與 service targetPort 一致 ($CPORT)"
else
  bad "containerPort 與 targetPort 對不上" "containerPort=[$CPORT] targetPort=[$TPORT]"
fi
ENVNAMES=$(q '.spec.template.spec.containers[0].env[].name' "$D")
if printf '%s\n' "$ENVNAMES" | grep -qiE '^(PORT|HTTP_PORT|LISTEN_PORT)$'; then
  ok "埠號以環境變數注入"
else
  bad "埠號沒有以環境變數注入" "容器 env 裡找不到 PORT／HTTP_PORT／LISTEN_PORT"
fi

head_ "C02 · 提供 /healthz，且探針指向它"
LP=$(q '.spec.template.spec.containers[0].livenessProbe.httpGet.path // ""' "$D")
RP=$(q '.spec.template.spec.containers[0].readinessProbe.httpGet.path // ""' "$D")
if [ "$LP" = "/healthz" ] && [ "$RP" = "/healthz" ]; then
  ok "liveness 與 readiness 都指向 /healthz"
else
  bad "探針沒有同時指向 /healthz" "liveness=[$LP] readiness=[$RP]"
fi
if [ -d "$APP" ] && grep -rq '/healthz' "$APP"; then
  ok "程式裡有 /healthz 路由"
elif [ -d "$APP" ]; then
  bad "程式裡找不到 /healthz 路由" "探針指向一個不存在的路徑，Pod 會一直重啟"
fi

head_ "C03 · 映像檔精簡（最終階段不含建置工具）"
FINAL=$(grep -iE '^[[:space:]]*FROM ' "$DF" | tail -1)
if echo "$FINAL" | grep -qiE 'FROM[[:space:]]+(--platform=[^[:space:]]+[[:space:]]+)?(scratch|gcr\.io/distroless|.*distroless)'; then
  ok "最終階段為 scratch／distroless"
else
  bad "最終階段不是 scratch／distroless" "實際：$FINAL"
fi
if [ "$(grep -ciE '^[[:space:]]*FROM ' "$DF")" -ge 2 ]; then
  ok "Dockerfile 為多階段建置"
else
  bad "Dockerfile 不是多階段建置" "建置工具會被打包進最終映像檔"
fi

head_ "C04 · 唯一標籤，且 imagePullPolicy 明寫"
IMG=$(q '.spec.template.spec.containers[0].image // ""' "$D")
TAG="${IMG##*:}"
if [ -z "$IMG" ]; then
  bad "找不到 image 欄位" "deployment 沒有指定映像檔"
elif [ "$IMG" = "$TAG" ]; then
  bad "映像檔沒有標籤" "$IMG —— 沒有標籤等同 latest"
elif [ "$TAG" = "latest" ]; then
  bad "標籤是 latest" "$IMG —— 標籤重複時節點快取會讓你跑到舊版"
else
  ok "映像檔標籤唯一 ($TAG)"
fi
IPP=$(q '.spec.template.spec.containers[0].imagePullPolicy // ""' "$D")
if [ -n "$IPP" ]; then ok "imagePullPolicy 明寫 ($IPP)"
else bad "imagePullPolicy 沒有明寫" "會吃預設值，行為隨標籤而變"; fi

head_ "C05 · 一定要宣告 resources.requests 與 limits"
RQ=$(q '.spec.template.spec.containers[0].resources.requests // ""' "$D")
LM=$(q '.spec.template.spec.containers[0].resources.limits // ""' "$D")
if [ -n "$RQ" ] && [ "$RQ" != "null" ]; then ok "有 resources.requests"
else bad "沒有 resources.requests" "不宣告就是向整座叢集賒帳，帳單由鄰居的穩定性支付"; fi
if [ -n "$LM" ] && [ "$LM" != "null" ]; then ok "有 resources.limits"
else bad "沒有 resources.limits" "單一容器可以吃光節點資源"; fi

head_ "C06 · 不得要求特權或 root"
PRIV=$(q '.spec.template.spec.containers[0].securityContext.privileged // false' "$D")
RAU=$(q '.spec.template.spec.containers[0].securityContext.runAsUser // ""' "$D")
RNR=$(q '.spec.template.spec.containers[0].securityContext.runAsNonRoot // ""' "$D")
if [ "$PRIV" != "true" ]; then ok "沒有要求 privileged"
else bad "要求了 privileged" "一支只聽 HTTP 的服務，爆炸半徑不該是整個節點"; fi
if [ "$RAU" != "0" ]; then ok "沒有以 root（uid 0）執行"
else bad "runAsUser 設為 0" "以 root 執行，容器逃逸的代價變高"; fi
if [ "$RNR" = "true" ]; then ok "明確宣告 runAsNonRoot"
else bad "沒有宣告 runAsNonRoot: true" "沒有明寫就是把判斷交給映像檔的預設值"; fi

head_ "C07 · 設定全部走環境變數，不得寫死"
HITS=$(grep -rnoEi '(https?://[a-z0-9.-]+|password[[:space:]]*[:=][[:space:]]*[^[:space:]"]+|secret[[:space:]]*[:=][[:space:]]*[^[:space:]"]+)' \
        "$APP" "$DEPLOY" 2>/dev/null \
        | grep -viE '(localhost|127\.0\.0\.1|example\.com|schema|w3\.org|golang\.org|k8s\.io|valueFrom|secretKeyRef)' || true)
if [ -z "$HITS" ]; then ok "程式與部署宣告裡沒有寫死的網址或密語"
else bad "有疑似寫死的網址或密語" "$(echo "$HITS" | head -3)"; fi
# registry 位址常常沒有 scheme，上面的樣式抓不到；build.sh 與程式裡的帳號必須是變數
REG=$(grep -rnoE '\b[a-z0-9.-]+\.(io|com|dev|org)/[a-z0-9._-]+/[a-z0-9._-]+' "$BS" "$APP" 2>/dev/null \
      | grep -v '\$' | grep -viE '(golang\.org|k8s\.io|example\.com|pkg\.go\.dev)' || true)
if [ -z "$REG" ]; then ok "建置腳本與程式裡沒有寫死的 registry 帳號"
else bad "registry 位址寫死了（沒有用變數）" "$(echo "$REG" | head -2)"; fi

head_ "C08 · 沒有推論後端時要能降級"
if [ -d "$APP" ] && grep -rq 'INFERENCE_URL' "$APP"; then
  if grep -rqiE 'degrad|降級|fallback' "$APP"; then
    ok "有 INFERENCE_URL 未設定時的降級分支"
  else
    bad "有讀 INFERENCE_URL，但看不到降級處理" "後端不在時應該回罐頭訊息並標示降級，而不是壞掉"
  fi
else
  bad "程式沒有處理 INFERENCE_URL" "應用的存活不該綁在推論後端上"
fi

head_ "C09 · 目標架構明確，且不靠模擬器建置"
if grep -qE 'FROM[[:space:]]+--platform=\$\{?BUILDPLATFORM' "$DF"; then
  ok "builder 階段釘在 BUILDPLATFORM（交叉編譯，不啟動模擬器）"
else
  bad "builder 階段沒有釘 BUILDPLATFORM" "跨架構建置會退回 QEMU 模擬，編譯時間可能差好幾倍"
fi
if grep -qE 'TARGETARCH|TARGETPLATFORM' "$DF"; then ok "有依 TARGETARCH 決定輸出架構"
else bad "沒有使用 TARGETARCH" "交叉編譯需要知道目標架構"; fi
if [ -f "$BS" ] && grep -qE '\-\-platform[= ]("?\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"?|linux/)' "$BS"; then
  ok "build.sh 明寫目標平台（字面值或變數皆可）"
elif [ -f "$BS" ]; then bad "build.sh 沒有明寫 --platform" "你的筆電架構可能跟叢集不同"; fi

head_ "C10 · 標明擁有者，不得留佔位字串"
OWN=$(q '.data.APP_OWNER // ""' "$CM" 2>/dev/null)
if [ -f "$CM" ]; then
  if [ -n "$OWN" ] && ! echo "$OWN" | grep -qiE 'TODO|CHANGE-ME|FIXME|填|xxx'; then
    ok "APP_OWNER 已填實名 ($OWN)"
  else
    bad "APP_OWNER 沒填或還是佔位字串" "值：[$OWN] —— 沒人認領的服務，出事沒人接電話"
  fi
fi
PLH=$(grep -rnoE 'TODO-[^[:space:]"]*|CHANGE-ME|REPLACE-[A-Z-]+|FIXME|<your-[^>]*>' "$DEPLOY" "$APP" 2>/dev/null || true)
if [ -z "$PLH" ]; then ok "產出物裡沒有殘留佔位字串"
else bad "還有佔位字串沒換掉" "$(echo "$PLH" | head -3)"; fi

head_ "C11 · 映像檔一律推送到 Docker Hub"
OTHER=$(grep -rnoE '\b(ghcr\.io|quay\.io|gcr\.io|[a-z0-9.-]*\.pkg\.dev|[0-9]+\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com|registry\.gitlab\.com|mcr\.microsoft\.com)' \
        "$BS" "$DF" "$DEPLOY" 2>/dev/null || true)
if [ -z "$OTHER" ]; then ok "沒有指向其他 registry"
else bad "用到了 Docker Hub 以外的 registry" "$(echo "$OTHER" | head -2)"; fi
if [ -f "$BS" ] && grep -qE 'docker\.io/' "$BS"; then
  ok "build.sh 推送目標是 Docker Hub"
elif [ -f "$BS" ]; then
  bad "build.sh 沒有明寫 docker.io/" "本場一律用 Docker Hub，且要明寫 registry，不吃隱含預設值"
fi
case "$IMG" in
  docker.io/*) ok "deployment 的 image 明寫 docker.io/" ;;
  "") : ;;
  *) bad "deployment 的 image 沒有明寫 docker.io/" "實際：$IMG —— 省略 registry 等於依賴用戶端的預設值" ;;
esac

printf '\n────────────────────────────\n'
printf '通過 %d 項，未通過 %s%d%s 項\n' "$PASS" "$([ "$FAIL" -gt 0 ] && echo "$RED")" "$FAIL" "$RST"
if [ "$FAIL" -gt 0 ]; then
  printf '\n未通過就是還不能交件。修正後重跑這支腳本，直到全部通過為止。\n'
  exit 1
fi
printf '\n全數通過。這份產出物符合硬性限制表，可以送審。\n'
