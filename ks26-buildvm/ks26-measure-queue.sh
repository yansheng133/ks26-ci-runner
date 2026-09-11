#!/usr/bin/env bash
# ks26 #41 量測：八組同時 merge 時，CI runner 要花多久
#
# 量兩個數字：
#   A 冷建置  —— 清掉建置快取後的單組耗時（全場第一組會遇到的）
#   B 排隊總長 —— 接著八組連續跑完的牆鐘時間（八組同時 merge 的最壞情況）
#
# 為什麼八組指同一個 repo 也算數：真實情況下八組都是同一份 ai-output 的 fork，
# Go 原始碼一模一樣，建置快取本來就會命中；而段 3 那個「順手改 APP_OWNER」
# 只動 deploy/，watcher 對 deploy/ 底下的修改不重建。所以真實世界也是
# 「一次冷建置 ＋ 七次熱建置」，這個測法就是它。
#
# 用法：
#   ./ks26-measure-queue.sh              # 量 8 組，會先問你一次
#   ./ks26-measure-queue.sh 16 --yes     # 量 16 組，不問
#
# 它會動到什麼：groups.conf、state/、work/、docker 的「建置快取」。
# 三樣都會在結束時還原；建置快取還原不了，但那正是 A 要量的東西。
# 它不會動：映像檔本身（golang 基底不會被刪掉）、登入狀態、你的 repo。
set -uo pipefail

N=8; ASSUME_YES=0
for a in "$@"; do
  case "$a" in
    --yes|-y) ASSUME_YES=1 ;;
    [0-9]*)   N="$a" ;;
    *) echo "不認得的參數：$a"; exit 2 ;;
  esac
done

REPO="${KS26_MEASURE_REPO:-https://github.com/GITHUB_ACCOUNT/ks26-app}"
BRANCH="${KS26_MEASURE_BRANCH:-ai-output}"
CONF="./groups.conf"; STATE="./state"; WORK="./work"; LOG="./watcher.log"
BK=".measure-backup"

red=$'\033[31m'; grn=$'\033[32m'; yel=$'\033[33m'; dim=$'\033[2m'; bld=$'\033[1m'; rst=$'\033[0m'
[ -t 1 ] || { red=; grn=; yel=; dim=; bld=; rst=; }
die(){ printf '%s%s%s\n' "$red" "$*" "$rst" >&2; exit 1; }
hdr(){ printf '\n%s──— %s ———%s\n' "$bld" "$*" "$rst"; }

# ── 前置檢查 ──────────────────────────────────────────────
[ -x ./ks26-watcher.sh ] || die "這裡沒有 ks26-watcher.sh。先 cd ~/ks26/ks26-buildvm"
ENGINE=$(command -v docker || command -v podman) || die "找不到 docker／podman"
ENGINE=$(basename "$ENGINE")
$ENGINE info >/dev/null 2>&1 || die "$ENGINE 不能用（daemon 沒起來？）"

# 基底映像檔要在本機：watcher 用 --network=none 建置，不在的話一定失敗（#47）
BASE=$($ENGINE image ls --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -c '^golang:' || true)
[ "$BASE" -gt 0 ] || printf '%s注意%s 本機沒有 golang 基底映像檔，建置會失敗。先 %s pull golang:1.24-bookworm\n' \
                            "$yel" "$rst" "$ENGINE"

printf '%s量測設定%s\n' "$bld" "$rst"
printf '  組數      %s\n' "$N"
printf '  來源      %s（分支 %s）\n' "$REPO" "$BRANCH"
printf '  引擎      %s\n' "$ENGINE"
printf '\n%s這會清掉 %s 的建置快取%s（映像檔本身不動）。冷建置就是要量這個。\n' "$yel" "$ENGINE" "$rst"
if [ "$ASSUME_YES" -eq 0 ]; then
  printf '要繼續嗎？[y/N] '; read -r ans
  case "$ans" in y|Y|yes) ;; *) echo "取消。"; exit 0 ;; esac
fi

# ── 備份 ──────────────────────────────────────────────────
rm -rf "$BK"; mkdir -p "$BK"
[ -f "$CONF" ]  && cp "$CONF" "$BK/groups.conf"
[ -d "$STATE" ] && cp -r "$STATE" "$BK/state"
restore(){
  rm -rf "$STATE" "$WORK"
  if [ -f "$BK/groups.conf" ]; then cp "$BK/groups.conf" "$CONF"; else : > "$CONF"; fi
  [ -d "$BK/state" ] && cp -r "$BK/state" "$STATE"
  printf '\n%s已還原 groups.conf 與 state/%s\n' "$dim" "$rst"
}
trap restore EXIT INT TERM

logsize(){ [ -f "$LOG" ] && wc -l < "$LOG" || echo 0; }
strip_ansi(){ sed -E 's/\x1b\[[0-9;]*m//g'; }

# 從新增的 log 行算每組耗時（建置中 → OK）
per_group(){
  local from="$1"
  tail -n +"$((from+1))" "$LOG" 2>/dev/null | strip_ansi | awk '
    /建置中/ { t=$1; g=$3; start[g]=t }
    /^[0-9:]+ +OK/ { g=$3; if (g in start) printf "  %-8s %s → %s\n", g, start[g], $1 }
    /擋下|FAIL/ { print "  " $0 }
  '
}

run_phase(){   # run_phase <標題> <組數>
  local title="$1" n="$2" i t0 t1 before
  : > "$CONF"
  for ((i=1;i<=n;i++)); do printf 'group%s %s %s\n' "$i" "$REPO" "$BRANCH" >> "$CONF"; done
  rm -rf "$STATE" "$WORK"; mkdir -p "$STATE"
  before=$(logsize)
  hdr "$title"
  t0=$(date +%s)
  ./ks26-watcher.sh --once
  t1=$(date +%s)
  ELAPSED=$((t1-t0))
  printf '%s每組時間軸%s\n' "$dim" "$rst"; per_group "$before"
  printf '%s%s 耗時 %d 秒%s\n' "$grn" "$title" "$ELAPSED" "$rst"
}

# ── A：冷建置 ─────────────────────────────────────────────
hdr "清掉建置快取"
$ENGINE builder prune -af >/dev/null 2>&1 || $ENGINE system prune -f --filter 'type=build-cache' >/dev/null 2>&1 || true
echo "done"
run_phase "A · 冷建置（1 組）" 1
COLD=$ELAPSED

# ── B：排隊 ───────────────────────────────────────────────
run_phase "B · 排隊（${N} 組，快取已熱）" "$N"
QUEUE=$ELAPSED

# ── 報告 ──────────────────────────────────────────────────
WARM=$(( QUEUE / N ))
BUDGET=360   # 段 4 是 6 分鐘

hdr "#41 量測結果"
printf '  A 冷建置（第一組）      %s%3d 秒%s\n' "$bld" "$COLD" "$rst"
printf '  B %s 組排隊總長         %s%3d 秒%s\n' "$N" "$bld" "$QUEUE" "$rst"
printf '  平均每組（熱）          %3d 秒\n' "$WARM"
printf '  段 4 預算               %3d 秒（6 分鐘）\n' "$BUDGET"
printf '  結論                    '
if [ "$QUEUE" -le $((BUDGET*70/100)) ]; then
  printf '%s夠，而且有餘裕（用掉 %d%%）%s\n' "$grn" $((QUEUE*100/BUDGET)) "$rst"
elif [ "$QUEUE" -le "$BUDGET" ]; then
  printf '%s塞得進去，但很緊（用掉 %d%%）%s\n' "$yel" $((QUEUE*100/BUDGET)) "$rst"
else
  printf '%s不夠，超出 %d 秒%s\n' "$red" $((QUEUE-BUDGET)) "$rst"
fi
[ "$WARM" -gt 0 ] && printf '  這台在 6 分鐘內大約撐得住   %d 組\n' $(( BUDGET / WARM ))

cat <<NOTE

  ${dim}B 才是 #41 的答案。${rst}活動當天 runner 的建置快取已經是熱的（籌備期建過
  同一份 ai-output），而八組的 Go 原始碼一模一樣，所以現場就是「N 次熱建置」。
  A 是悲觀情境：runner 重裝、或快取被清掉時，第一組要多花的時間。
NOTE

cat <<TXT

${dim}兩件收尾：${rst}
  1. groups.conf 與 state/ 已自動還原（備份留在 ${BK}/，確認沒問題可以刪）
  2. Docker Hub 上會多出 ${N} 個 group<N>-<SHA> 測試標籤 —— 跟 #17 一樣從網頁刪掉
TXT
