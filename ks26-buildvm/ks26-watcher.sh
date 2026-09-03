#!/usr/bin/env bash
# ks26 建置 watcher —— 跑在專用的建置 VM 上，不在講師筆電上
#
# 它做什麼：輪詢各組 fork 的指定分支（預設 main），發現新 commit 就建置映像檔並推上 registry。
# 它不做什麼：**永遠不執行學員 repo 裡的任何腳本**。建置指令是固定的，寫在這支腳本裡。
#
# 用法：
#   ./ks26-watcher.sh --check          只做一次巡檢，印出狀態，不建置
#   ./ks26-watcher.sh --once           巡一輪，該建的建完就結束
#   ./ks26-watcher.sh                  持續輪詢（預設每 20 秒）
set -uo pipefail

CONF="${KS26_CONF:-./groups.conf}"
STATE="${KS26_STATE:-./state}"
WORK="${KS26_WORK:-./work}"
LOG="${KS26_LOG:-./watcher.log}"
REGISTRY="${KS26_REGISTRY:-docker.io/yansheng133}"
IMAGE="${KS26_IMAGE:-ks26-app}"
INTERVAL="${KS26_INTERVAL:-20}"
BUILD_TIMEOUT="${KS26_BUILD_TIMEOUT:-180}"
PUSH_TIMEOUT="${KS26_PUSH_TIMEOUT:-180}"
MAX_REPO_MB="${KS26_MAX_REPO_MB:-50}"

MODE="loop"; [ "${1:-}" = "--once" ] && MODE="once"; [ "${1:-}" = "--check" ] && MODE="check"

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; DIM=$'\033[2m'; RST=$'\033[0m'
[ -t 1 ] || { RED=; GRN=; YEL=; DIM=; RST=; }

log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" >> "$LOG"; }
say() { printf '%s\n' "$*"; log "$*"; }

command -v git >/dev/null 2>&1 || { echo "找不到 git"; exit 2; }

# 容器引擎：docker 與 podman 都可以。我們用到的旗標兩邊相容，
# 只有 --pull 的寫法不同（docker 吃布林，podman 吃策略字串）。
if [ -n "${KS26_ENGINE:-}" ]; then
  ENGINE="$KS26_ENGINE"
elif command -v docker >/dev/null 2>&1; then
  ENGINE=docker
elif command -v podman >/dev/null 2>&1; then
  ENGINE=podman
else
  echo "找不到 docker 或 podman"; exit 2
fi
command -v "$ENGINE" >/dev/null 2>&1 || { echo "找不到容器引擎 $ENGINE"; exit 2; }
case "$ENGINE" in
  podman) PULL_FLAG="--pull=never" ;;
  *)      PULL_FLAG="--pull=false" ;;
esac
[ -f "$CONF" ] || { echo "找不到設定檔 $CONF —— 一行一組：group1 <repo網址> <分支>"; exit 2; }
mkdir -p "$STATE" "$WORK"

# git 一律關閉 hooks 與外部設定，避免 clone 過程被塞東西
GIT="git -c core.hooksPath=/dev/null -c protocol.ext.allow=never"

# ── 安全閘門：只看，不執行 ────────────────────────────────────────────────
# 這些檢查全部只讀檔案內容。任何一條沒過就跳過該組，不建置。
guard() {
  local dir="$1" why=""
  local df="$dir/Dockerfile"

  [ -f "$df" ] || { echo "沒有 Dockerfile"; return 1; }

  # 1) # syntax= 會讓 BuildKit 去拉一個外部 frontend 映像檔並執行它
  if grep -qiE '^[[:space:]]*#[[:space:]]*syntax[[:space:]]*=' "$df"; then
    why="Dockerfile 指定了外部 syntax frontend"; echo "$why"; return 1; fi

  # 2) 建置期要求掛載 secret／ssh，本場不提供，出現即視為異常
  if grep -qE 'RUN[^\n]*--mount=type=(ssh|secret)' "$df"; then
    why="Dockerfile 要求掛載 secret 或 ssh"; echo "$why"; return 1; fi

  # 3) 要求特權建置（需要 --allow 才會生效，出現即視為異常）
  if grep -qiE 'security[[:space:]]*=[[:space:]]*insecure' "$df"; then
    why="Dockerfile 要求 insecure 建置"; echo "$why"; return 1; fi

  # 4) repo 體積：擋掉把大檔塞進建置脈絡的情況
  local mb; mb=$(du -sm --apparent-size "$dir" 2>/dev/null | cut -f1 || du -sm "$dir" 2>/dev/null | cut -f1)
  if [ -n "$mb" ] && [ "$mb" -gt "$MAX_REPO_MB" ]; then
    why="repo 體積 ${mb}MB 超過上限 ${MAX_REPO_MB}MB"; echo "$why"; return 1; fi

  return 0
}

remote_sha() { $GIT ls-remote "$1" "refs/heads/$2" 2>/dev/null | awk '{print $1}' | head -1; }

build_group() {
  local g="$1" url="$2" br="$3" sha="$4"
  local short="${sha:0:7}"
  local dir="$WORK/$g"
  local tag="${REGISTRY}/${IMAGE}:${g}-${short}"

  rm -rf "$dir"
  if ! $GIT clone --depth 1 --branch "$br" --single-branch "$url" "$dir" >>"$LOG" 2>&1; then
    say "  ${RED}FAIL${RST} $g 取不到程式碼"; return 1
  fi
  # 只有「建置輸入」變了才重建：學員把標籤填進 deploy/ 的那次 commit 不該再建一次
  local srchash lasthash=""
  srchash=$(cd "$dir" && $GIT ls-tree -r HEAD -- app Dockerfile go.mod 2>/dev/null | sha256sum | cut -c1-16)
  [ -f "$STATE/$g.src" ] && lasthash=$(cat "$STATE/$g.src")
  if [ -n "$lasthash" ] && [ "$srchash" = "$lasthash" ]; then
    echo "$sha" > "$STATE/$g.sha"
    say "  ${DIM}略過${RST} $g  只改了 deploy/，不重建（標籤仍是 $(cat "$STATE/$g.tag" 2>/dev/null)）"
    return 0
  fi
  rm -rf "$dir/.git"          # 之後不需要版本歷史，也少一份可被利用的東西

  local df_path="$dir/Dockerfile"
  local reason
  if ! reason=$(guard "$dir"); then
    say "  ${RED}擋下${RST} $g —— $reason"; return 1
  fi

  # --pull=false ＋ --network=none 的代價：基底映像檔一定要先在本機。
  # 不在的話 build 會噴很難懂的錯，這裡先講清楚（只提醒，不擋——解析錯了不該卡住學員）
  local from_img
  while read -r from_img; do
    [ -z "$from_img" ] && continue
    case "$from_img" in scratch|*'$'*) continue;; esac
    "$ENGINE" image inspect "$from_img" >/dev/null 2>&1 || \
      say "  ${YEL}注意${RST} $g 的基底映像檔 $from_img 不在本機——先在這台 pull 它，否則建置一定失敗"
  done < <(grep -iE '^[[:space:]]*FROM[[:space:]]' "$df_path" 2>/dev/null \
           | sed -E 's/^[[:space:]]*[Ff][Rr][Oo][Mm][[:space:]]+//; s/--[a-z-]+=[^[:space:]]+[[:space:]]*//g; s/[[:space:]]+[Aa][Ss][[:space:]]+.*$//; s/[[:space:]]*$//')

  # 固定的建置指令。--network=none：建置期沒有網路，
  # 約束表已規定純標準庫、CGO_ENABLED=0，所以本來就不需要對外連線。
  say "  ${DIM}建置中${RST} $g  $short"
  if ! timeout "$BUILD_TIMEOUT" "$ENGINE" build \
        --network=none \
        --platform linux/amd64 \
        "$PULL_FLAG" \
        -t "$tag" \
        -f "$dir/Dockerfile" \
        "$dir" >>"$LOG" 2>&1; then
    say "  ${RED}FAIL${RST} $g 建置失敗或逾時（看 $LOG）"; return 1
  fi

  if ! timeout "$PUSH_TIMEOUT" "$ENGINE" push "$tag" >>"$LOG" 2>&1; then
    say "  ${RED}FAIL${RST} $g 推送失敗（看 $LOG）"; return 1
  fi

  echo "$sha" > "$STATE/$g.sha"
  echo "$tag" > "$STATE/$g.tag"
  echo "$srchash" > "$STATE/$g.src"
  say "  ${GRN}OK${RST}   $g  →  $tag"
  printf '        %s\n' "請這一組把 deployment.yaml 的 image 換成上面那一行，commit 進去"
  return 0
}

sweep() {
  local built=0
  while read -r g url br; do
    case "$g" in ''|\#*) continue;; esac
    br="${br:-main}"
    local sha; sha=$(remote_sha "$url" "$br")
    if [ -z "$sha" ]; then say "  ${YEL}?${RST}    $g 讀不到遠端分支 $br"; continue; fi
    local last=""; [ -f "$STATE/$g.sha" ] && last=$(cat "$STATE/$g.sha")
    if [ "$sha" = "$last" ]; then
      [ "$MODE" = "check" ] && say "  ${DIM}—${RST}    $g 沒有新 commit  $(cat "$STATE/$g.tag" 2>/dev/null)"
      continue
    fi
    if [ "$MODE" = "check" ]; then say "  ${YEL}新${RST}   $g 有新 commit ${sha:0:7}（--check 不建置）"; continue; fi
    build_group "$g" "$url" "$br" "$sha" && built=$((built+1))
  done < "$CONF"
  return 0
}

say "ks26 watcher — 引擎 ${ENGINE}，registry ${REGISTRY}/${IMAGE}，設定檔 $CONF"
say "${DIM}只讀取學員 repo 的內容，不執行其中任何腳本${RST}"
if [ "$MODE" = "loop" ]; then
  while true; do sweep; sleep "$INTERVAL"; done
else
  sweep
fi
