#!/usr/bin/env bash
# CI runner bootstrap —— SLES 16
#
# 這台是「用完即丟」的建置機：跑學員 repo 裡 agent 寫的 Dockerfile。
# 不裝任何跟客戶有關的東西，活動結束銷毀。
#
# 用法：sudo -E ./ks26-runner-bootstrap.sh
set -euo pipefail
BASE_IMAGES="${KS26_BASE_IMAGES:-golang:1-alpine}"
WORKDIR="${KS26_HOME:-/home/ec2-user/ks26}"
RUNAS="${KS26_USER:-ec2-user}"
say(){ printf '\n\033[32m▸\033[0m %s\n' "$*"; }

say "系統與時間"
zypper --non-interactive refresh
zypper --non-interactive update
# watcher 一定要 git；curl/tar 給後續步驟用
zypper --non-interactive install -y git curl tar
systemctl enable --now chronyd
timedatectl show -p NTPSynchronized --value

say "SELinux（SLES 16 預設 enforcing，不要關掉）"
getenforce || true

say "容器引擎"
# 兩個都可以，watcher 會自己偵測。先試 docker，沒有就用 podman。
# SLES 的 docker 在 Containers 模組裡，模組沒開就會裝不到——那是正常的，改用 podman。
ENGINE=""
if zypper --non-interactive install -y docker >/dev/null 2>&1 && command -v docker >/dev/null; then
  ENGINE=docker
  systemctl enable --now docker
  usermod -aG docker "$RUNAS" || true
elif zypper --non-interactive install -y podman >/dev/null 2>&1 && command -v podman >/dev/null; then
  ENGINE=podman
else
  echo "docker 與 podman 都裝不起來。先確認訂閱與模組：SUSEConnect --list-extensions" >&2
  exit 2
fi
echo "使用 $ENGINE：$($ENGINE --version)"

say "預先拉基底映像檔（關鍵）"
# watcher 建置時用 --network=none --pull=false，基底映像檔不在本機就一定失敗。
# 這裡的標籤必須跟 ai-output 分支 Dockerfile 的 FROM 一字不差。
for img in $BASE_IMAGES; do
  echo "  pull $img"
  $ENGINE pull --platform linux/amd64 "$img"
done
$ENGINE images

say "工作目錄（就地使用，不搬檔——selftest 要用到 ../ks26-constraints 的相對路徑）"
HERE="$(cd "$(dirname "$0")" && pwd)"
chown -R "$RUNAS":"$RUNAS" "$HERE" "$HERE/.." 2>/dev/null || true
chmod +x "$HERE"/*.sh "$HERE"/*.py 2>/dev/null || true
ls -l "$HERE"
git --version

cat <<EOF

下一步（用 $RUNAS 身分，不要用 root）：

  1. 登入 registry —— 只用互動輸入，不要用 -p，權杖不要出現在指令列
       $ENGINE login --username yansheng133

  2. 端到端自我測試（會真的 build 並推一次）
       cd "$HERE" && ./ks26-selftest.sh

  3. 活動當天：表單匯出的 CSV → groups.conf
       ./ks26-groups-from-form.py responses.csv --out groups.conf
       ./ks26-watcher.sh --check      # 先確認八組都讀得到
       ./ks26-watcher.sh              # 進迴圈，這個視窗投影出去

EOF
