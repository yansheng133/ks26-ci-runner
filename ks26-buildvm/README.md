# ks26 CI runner

活動當天替八組建置映像檔的那台機器。**用完即丟**：它跑的是學員 repo 裡由 agent 產生的 Dockerfile，
`docker build` 的 `RUN` 就是執行任意指令，所以這件事不該發生在放著客戶資料的筆電上。

環境：SLES 16、m6i.large（2 vCPU／8 GB）、東京 ap-northeast-1、沒有任何對外入方向（只有 SSH）。

## 檔案

| 檔案 | 做什麼 |
|---|---|
| `ks26-runner-bootstrap.sh` | SLES 16 的開機設定：套件、時間、容器引擎、**預先拉基底映像檔**、目錄 |
| `ks26-watcher.sh` | 主程式。輪詢八組 repo，發現新 commit 就建置、推送、印出標籤 |
| `ks26-selftest.sh` | 端到端自我測試。真的 build、真的 push，14 項 |
| `ks26-groups-from-form.py` | Google Form 匯出的 CSV → `groups.conf` |
| `groups.conf.example` | 設定檔格式範例 |
| `ks26-board.py` / `ks26-board.html` | 建置看板。把 watcher 的狀態變成可投影的網頁,進度條讀 BuildKit 步驟 |

## 安裝

```bash
sudo -E ./ks26-runner-bootstrap.sh
# 然後用 ec2-user（不要 root）：
docker login -u <Docker Hub 帳號>     # 或 podman login。只用互動輸入，不要 -p
./ks26-selftest.sh                     # 應該 14/14
```

容器引擎 **docker 或 podman 都可以**，watcher 會自己偵測（`KS26_ENGINE` 可覆寫）。
兩者唯一的差別是 `--pull` 的寫法，腳本裡處理掉了。

## 活動當天

```bash
# 段 1 ⏱13:00，表單匯出 CSV 之後
./ks26-groups-from-form.py responses.csv --out groups.conf
./ks26-watcher.sh --check      # 八組都讀得到才往下；缺的組會被列出來
./ks26-watcher.sh              # 進迴圈。這個視窗投影出去
```

`--check` 只巡不建，是開跑前的確認動作。看到某組「讀不到遠端分支」就是網址填錯或 repo 不是 public。

## 它的行為

- **只讀，不執行**：永遠不跑學員 repo 裡的任何腳本。建置指令是固定的，寫死在 watcher 裡。
- **建置期沒有網路**：`--network=none`。約束表規定純標準庫、`CGO_ENABLED=0`，本來就不需要對外。
- **基底映像檔必須先在本機**：因為 `--pull=false`。bootstrap 會先拉；watcher 在建置前也會檢查並提醒。
  **`ai-output` 分支 Dockerfile 的 `FROM` 標籤要跟 bootstrap 拉的那個一字不差。**
- **只有建置輸入變了才重建**：對 `app/`、`Dockerfile`、`go.mod` 算雜湊。學員在段 4 把標籤填進
  `deploy/` 的那次 commit **不會**觸發第二次建置——否則每組會建兩次、投影幕上出現兩行標籤。
- **標籤 7 碼**：`<registry>/<image>:group<N>-<7 碼 SHA>`，跟 GitHub 網頁顯示的長度一致，方便肉眼比對。
- **安全閘門**（任一條沒過就跳過該組，不進 build）：外部 `# syntax=` frontend、`--mount=type=secret|ssh`、
  `security=insecure`、沒有 Dockerfile、repo 體積超過上限。

## 環境變數

| 變數 | 預設 | |
|---|---|---|
| `KS26_REGISTRY` | `docker.io/yansheng133` | 推去哪 |
| `KS26_IMAGE` | `ks26-app` | 映像檔名 |
| `KS26_ENGINE` | 自動偵測 | `docker` 或 `podman` |
| `KS26_INTERVAL` | `20` | 輪詢秒數 |
| `KS26_BUILD_TIMEOUT` / `KS26_PUSH_TIMEOUT` | `180` | 逾時 |
| `KS26_MAX_REPO_MB` | `50` | repo 體積上限 |

## 已驗證到哪裡

`ks26-selftest.sh` 在 Linux／Docker 29／BuildKit 上跑過 **14/14**：真的建置（`--network=none`）、
真的推上 registry、標籤格式與 7 碼 SHA、沒有新 commit 不重建、只改 `deploy/` 不重建、
改 `app/` 會重建、五道安全閘門。

**還沒驗證的**：對真實 Docker Hub 帳號的推送（需要憑證）、八組同時觸發時的排隊時間。
兩者都在 CI runner 上跑一次 `./ks26-selftest.sh` 與彩排時量。
