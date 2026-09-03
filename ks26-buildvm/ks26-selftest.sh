#!/usr/bin/env bash
# ks26 watcher 端到端自我測試
#
# 為什麼要有這支：watcher 的安全閘門好測，但「真的 build 出映像檔並推上去」
# 一直沒有被驗證過。這支用本機 git repo 當假的學員 fork，把整條路走一遍：
#   clone → 擋門 → build → push → 印標籤 → 沒有新 commit 就不動 → 只改 deploy/ 不重建
#
# 用法：
#   ./ks26-selftest.sh                      # 用預設 registry（需要能推）
#
# 標籤一律用 selftest-<sha>，不會跟活動當天的 group<N>-<sha> 混在一起。
# 跑完可以在 Docker Hub 上把 selftest-* 標籤刪掉。
#   KS26_REGISTRY=127.0.0.1:5000/ks26 ./ks26-selftest.sh
#
# 前置：容器引擎可用、基底映像檔已在本機（watcher 用 --pull=false --network=none）
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCHER="$HERE/ks26-watcher.sh"
SRC="${KS26_SELFTEST_SRC:-$HERE/../ks26-constraints/examples/good}"
REG="${KS26_REGISTRY:-127.0.0.1:5000/ks26workshop}"
IMG="${KS26_IMAGE:-ks26-app}"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
G=$'\033[32m'; R=$'\033[31m'; D=$'\033[2m'; N=$'\033[0m'; [ -t 1 ] || { G=; R=; D=; N=; }

ok(){ PASS=$((PASS+1)); printf '  %sPASS%s  %s\n' "$G" "$N" "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  %sFAIL%s  %s\n' "$R" "$N" "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }
head_(){ printf '\n%s\n' "$1"; }

[ -d "$SRC" ] || { echo "找不到參考產出物 $SRC"; exit 2; }
[ -x "$WATCHER" ] || chmod +x "$WATCHER"

# 造一個假的學員 repo（本機路徑，watcher 的 clone/ls-remote 都吃）
mkrepo(){ # mkrepo <dir> <srcdir>
  local d="$1" s="$2"
  rm -rf "$d"; mkdir -p "$d"; cp -a "$s"/. "$d"/
  git -C "$d" init -q -b main
  git -C "$d" -c user.email=t@t -c user.name=t add -A
  git -C "$d" -c user.email=t@t -c user.name=t commit -qm init
}
commit(){ git -C "$1" -c user.email=t@t -c user.name=t add -A
          git -C "$1" -c user.email=t@t -c user.name=t commit -qm "$2"; }
run(){ ( cd "$T" && KS26_REGISTRY="$REG" KS26_IMAGE="$IMG" \
          KS26_CONF="$T/groups.conf" KS26_STATE="$T/state" \
          KS26_WORK="$T/work" KS26_LOG="$T/watcher.log" \
          "$WATCHER" "$@" 2>&1 ); }

REPO="$T/studentrepo"
mkrepo "$REPO" "$SRC"
printf 'selftest %s main\n' "$REPO" > "$T/groups.conf"

head_ "1 · 首次建置"
out=$(run --once)
if grep -q "OK" <<<"$out"; then ok "建置並推送成功"; else no "建置失敗" "$(tail -5 "$T/watcher.log")"; fi
tag1=$(cat "$T/state/selftest.tag" 2>/dev/null)
if [[ "$tag1" == "$REG/$IMG:selftest-"* ]]; then ok "標籤格式正確：$tag1"; else no "標籤格式不對：$tag1"; fi
sha_part="${tag1##*-}"
if [ ${#sha_part} -eq 7 ]; then ok "SHA 為 7 碼（與 GitHub 顯示一致）"; else no "SHA 長度 ${#sha_part}，應為 7"; fi

head_ "2 · 沒有新 commit 就不該再建"
out=$(run --once)
if grep -q "OK" <<<"$out"; then no "重複建置了" "$out"; else ok "沒有新 commit，沒有重建"; fi

head_ "3 · 只改 deploy/ 不該重建（段 4 學員填標籤那一次 commit）"
sed -i 's|REPLACE_SHA|'"$sha_part"'|g' "$REPO/deploy/deployment.yaml" 2>/dev/null
commit "$REPO" "fill image tag"
out=$(run --once)
if grep -q "略過" <<<"$out"; then ok "只改宣告，映像檔沒有重建"; else no "又建了一次" "$out"; fi
tag2=$(cat "$T/state/selftest.tag")
if [ "$tag1" = "$tag2" ]; then ok "標籤沒有變（學員貼的那行仍然有效）"; else no "標籤變了：$tag1 → $tag2"; fi

head_ "4 · 改到 app/ 才該重建"
printf '\n// touch\n' >> "$REPO/app/main.go"
commit "$REPO" "change app"
out=$(run --once)
if grep -q "OK" <<<"$out"; then ok "程式碼變動觸發重建"; else no "沒有重建" "$(tail -5 "$T/watcher.log")"; fi
tag3=$(cat "$T/state/selftest.tag")
if [ "$tag3" != "$tag1" ]; then ok "產生新標籤：$tag3"; else no "標籤沒變"; fi

head_ "5 · 安全閘門（每一條都該擋下來，不進 build）"
guard(){ # guard <名稱> <改法>
  local name="$1" fn="$2" d="$T/bad"
  mkrepo "$d" "$SRC"; $fn "$d"; commit "$d" bad
  printf 'bad %s main\n' "$d" > "$T/groups.conf"
  local o; o=$(run --once)
  if grep -q "擋下" <<<"$o"; then ok "$name"; else no "$name 沒有被擋" "$o"; fi
}
g_syntax(){ sed -i '1i # syntax=docker/dockerfile:1-labs' "$1/Dockerfile"; }
g_secret(){ sed -i 's|^RUN CGO_ENABLED|RUN --mount=type=secret,id=x CGO_ENABLED|' "$1/Dockerfile"; }
g_insec(){ sed -i '1i # security = insecure' "$1/Dockerfile"; }
g_nodf(){ rm -f "$1/Dockerfile"; }
g_big(){ head -c 60000000 /dev/urandom > "$1/blob.bin"; }
guard "擋下外部 syntax frontend" g_syntax
guard "擋下 secret 掛載"        g_secret
guard "擋下 insecure 建置"      g_insec
guard "擋下沒有 Dockerfile"     g_nodf
guard "擋下超大 repo"           g_big

head_ "6 · 映像檔真的在 registry 上"
if [[ "$REG" == 127.0.0.1:5000/* ]] && curl -skf https://127.0.0.1:5000/_tags >/dev/null 2>&1; then
  if curl -sk https://127.0.0.1:5000/_tags | grep -q "selftest-"; then ok "registry 上找得到推上去的標籤"
  else no "registry 上沒有標籤"; fi
else
  printf '  %s略過%s  非本機測試 registry，跳過這一項\n' "$D" "$N"
fi

printf '\n────────────────────────────\n通過 %d 項，未通過 %d 項\n\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && echo "watcher 端到端可用。" || echo "有項目沒過，看上面的訊息與 $T/watcher.log"
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
