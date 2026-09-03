#!/usr/bin/env bash
# 換掉 Docker Hub 帳號名（namespace）—— 它散在五個地方，這支一次改完。
# 用法：./ks26-set-registry.sh <新帳號名>
set -euo pipefail
NEW="${1:?用法：$0 <docker hub 帳號名>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

files=(
  "$ROOT/ks26-buildvm/ks26-watcher.sh"
  "$ROOT/ks26-buildvm/README.md"
  "$ROOT/ks26-sample/deploy/deployment.yaml"
  "$ROOT/ks26-sample/README.md"
  "$ROOT/ks26-constraints/examples/good/deploy/deployment.yaml"
)
for f in "${files[@]}"; do
  [ -f "$f" ] || { echo "找不到 $f"; exit 1; }
  # 這幾個檔裡的 docker.io/<名字> 全部都是活動用的 namespace，整批換掉即可
  sed -i "s|docker\.io/[A-Za-z0-9_-][A-Za-z0-9_-]*|docker.io/${NEW}|g" "$f"
  echo "改好 ${f#$ROOT/}"
done
echo
echo "確認："
grep -rn "docker\.io/" "${files[@]}" | sed "s|$ROOT/||"
echo
echo "注意：examples/good 是 ai-output 分支的內容，改完要重新推上 GitHub。"
