#!/usr/bin/env bash
# 換掉 Docker Hub 帳號名（namespace）—— 它散在好幾個地方，這支一次改完。
# 預設值是佔位字串 DOCKERHUB_ACCOUNT，拿到這份 repo 的人跑一次這支就能用自己的帳號。
#
# 用法：./ks26-set-registry.sh <新帳號名>
set -euo pipefail
NEW="${1:?用法：$0 <docker hub 帳號名>}"

case "$NEW" in
  *[!A-Za-z0-9_-]*) echo "帳號名只能有英數字、底線與連字號：$NEW"; exit 2 ;;
  DOCKERHUB_ACCOUNT) echo "DOCKERHUB_ACCOUNT 是佔位字串本身，不是帳號名"; exit 2 ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# 這些檔裡的 docker.io/<名字> 全部都是活動用的 namespace，整批換掉即可。
files=(
  "$ROOT/ks26-buildvm/ks26-watcher.sh"
  "$ROOT/ks26-buildvm/ks26-board.py"
  "$ROOT/ks26-buildvm/ks26-board.html"
  "$ROOT/ks26-buildvm/README.md"
  "$ROOT/ks26-buildvm/ks26-runner-bootstrap.sh"
  "$ROOT/ks26-constraints/examples/good/deploy/deployment.yaml"
)

for f in "${files[@]}"; do
  [ -f "$f" ] || { echo "找不到 $f"; exit 1; }
  sed -i "s|docker\.io/[A-Za-z0-9_-][A-Za-z0-9_-]*|docker.io/${NEW}|g" "$f"
  # bootstrap 印出來的登入提示用的是同一個 Docker Hub 帳號
  sed -i "s|login --username [^ ]*|login --username ${NEW}|g" "$f"
  echo "改好 ${f#"$ROOT"/}"
done

echo
echo "確認："
grep -rn "docker\.io/\|login --username" "${files[@]}" | sed "s|$ROOT/||"
echo
echo "沒有被這支動到、需要時自己改的兩個地方："
echo "  - ks26-measure-queue.sh 的 KS26_MEASURE_REPO 預設值（那是 GitHub 帳號，不是 Docker Hub）"
echo "  - examples/good 是 ai-output 分支的內容，改完要重新推上 GitHub"
