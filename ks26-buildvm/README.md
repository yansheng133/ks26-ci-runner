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
| `ks26-measure-queue.sh` | 量冷建置耗時與八組排隊總長。會動 `groups.conf`／`state/`／`work/`，結束時還原 |
| `ks26-groups-from-form.py` | 提交表 → `groups.conf`。吃 CSV，也吃 markdown 表格（HackMD 匯出的 `.md` 可直接餵） |
| `groups.conf.example` | 設定檔格式範例 |
| `ks26-board.service` / `board-paths.conf` | 看板的 systemd 服務與正式路徑 drop-in |
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

## 建置看板（可投影）

兩種跑法。

**公開**——systemd 服務，`0.0.0.0:80`，現場所有人直接開網址：

```bash
sudo systemctl status ks26-board      # 已 enable，重開機會自己起來
```

`ks26-board.service` 以 **ec2-user** 執行，靠 `AmbientCapabilities=CAP_NET_BIND_SERVICE`
綁 80，不是用 root 跑。要在 AWS security group 放行 TCP 80 才連得到。

**私下**——不開對外埠，走 SSH tunnel：

```bash
./ks26-board.py                                               # 綁 127.0.0.1:8080
ssh -i rancher.pem -L 8080:127.0.0.1:8080 ec2-user@<runner>   # 然後開 http://127.0.0.1:8080
```

### 看板讀哪一組狀態

路徑**明寫**在 `/etc/systemd/system/ks26-board.service.d/paths.conf`：

```bash
sudo install -m 0644 board-paths.conf \
     /etc/systemd/system/ks26-board.service.d/paths.conf     # 正式路徑
sudo systemctl daemon-reload && sudo systemctl restart ks26-board
systemctl cat ks26-board | grep Environment                  # 確認讀的是哪裡
```

`board-paths-demo.conf` 是驗證沙箱用的，**不要留在正式機上**。

> **這個坑咬過一次。** 服務被留在驗證沙箱的路徑上，服務 `active`、頁面 200、API 正常回應——
> 沒有任何一個檢查會失敗，但投影出來的是一組叫 `demo1` 的假資料，八組什麼都看不到。
> 所以看板現在會把正在讀的 `groups.conf` 路徑印在標題下方，指到非預設路徑時右上角亮
> 「非正式路徑」警示。**驗收不能只看 `systemctl is-active`，要看畫面上的 conf 路徑。**

### 進度條為什麼是真的

watcher 把 `docker build` 的輸出也導進 `watcher.log`，看板解析 BuildKit 的步驟行。
三個不明顯的地方：

1. `x/y` 是**每個 stage 各自**的編號。多階段會有 `builder 1..4/4` 與 `stage-1 1/1`，
   總步數要各 stage 相加（=5）；取最大值的話一開始就會跳到 100%。
2. `#8 [builder 4/4] RUN ...` 是該步**開始**時印的，完成標記是後面的 `#8 DONE` 或
   `#8 CACHED`（CACHED 不會再印 DONE）。數開始行會讓建置一秒就顯示滿格。
3. 「封裝推送中」要用 `#N exporting to image` 判斷；用「已知步驟都做完了」的話，
   下一個 stage 還沒宣告時會誤報。

還在跑的建置進度上限停在 95%，不會提早顯示滿格。

公開版沒有任何驗證，`/api/state` 會露出各組 repo 網址、映像檔標籤，以及 `watcher.log`
最後 14 行（建置失敗時那裡有完整 build 輸出）。權杖不會出現在 log 裡。
狀態回應快取 1 秒——幾十個人同時看的話，不快取就是每秒數十次 `docker images`，會跟建置搶 CPU。

## 活動當天

```bash
# 段 1，收齊各組網址之後（HackMD 那頁加 /download 就是 .md）
./ks26-groups-from-form.py form.md --branch main --out groups.conf
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
- **某一組換了 repo 就重來**：`groups.conf` 裡某組的網址或分支換掉時（學員改用另一個 GitHub 帳號
  重新 fork），把該組舊狀態歸檔到 `state/changed/<組>-<時間>/`，重新建置。比對前會正規化大小寫、
  結尾的 `.git` 與斜線——這些不算換 repo。
- **標籤 7 碼**：`<registry>/<image>:group<N>-<7 碼 SHA>`，跟 GitHub 網頁顯示的長度一致，方便肉眼比對。
- **安全閘門**（任一條沒過就跳過該組，不進 build）：外部 `# syntax=` frontend、`--mount=type=secret|ssh`、
  `security=insecure`、沒有 Dockerfile、repo 體積超過上限。

### `state/` 裡有什麼

每組四個檔，**加上 `.repo` 是為了關掉一個靜默失敗**：

| 檔案 | 內容 |
|---|---|
| `<組>.sha` | 上次處理過的 commit |
| `<組>.src` | `app/`＋`Dockerfile`＋`go.mod` 的雜湊，決定要不要重建 |
| `<組>.tag` | 上次推出去的映像檔標籤 |
| `<組>.repo` | 上次看到的 `<repo網址> <分支>` |

> **這個坑咬過一次。** state 是用組號當鍵的，本身不記得那份狀態是哪個 repo 留下的。
> 學員中途改用另一個帳號重新 fork、`groups.conf` 改指新網址之後，舊 repo 的狀態會被拿去比對新
> repo，而且**兩條路都不會有錯誤訊息**：`.sha` 相同就判定「沒有新 commit」，這一組整場不建置；
> `.src` 相同就「略過不重建」，標籤還留在前一個 repo 建出來的映像檔上，看板上看起來像是成功了。
> 第一條特別容易中——八組都 fork 自同一個上游，**沒動過的 fork 全部停在同一個 commit**。
> 現在靠 `.repo` 偵測並自動重建，換 repo 時 log 會明寫「換 repo」與新舊網址。

**從沒有 `.repo` 的舊版升上來時**，watcher 會把當下的網址補記進去、不觸發整批重建。代價是
「換 repo 發生在升級之前」那一次抓不到，所以升級時先依現況補記，再換腳本：

```bash
awk '$1 ~ /^group/ {print $2, ($3==""?"main":$3) > ("state/" $1 ".repo")}' groups.conf
```

`--check` 只巡不改：偵測到換 repo 只報告，不動 `state/`、不產生歸檔。

## 環境變數

| 變數 | 預設 | |
|---|---|---|
| `KS26_REGISTRY` | `docker.io/DOCKERHUB_ACCOUNT` | 推去哪 |
| `KS26_IMAGE` | `ks26-app` | 映像檔名 |
| `KS26_ENGINE` | 自動偵測 | `docker` 或 `podman` |
| `KS26_INTERVAL` | `20` | 輪詢秒數 |
| `KS26_BUILD_TIMEOUT` / `KS26_PUSH_TIMEOUT` | `180` | 逾時 |
| `KS26_MAX_REPO_MB` | `50` | repo 體積上限 |

## 已驗證到哪裡

`ks26-selftest.sh` 在 Linux／Docker 29／BuildKit 上跑過 **14/14**：真的建置（`--network=none`）、
真的推上 registry、標籤格式與 7 碼 SHA、沒有新 commit 不重建、只改 `deploy/` 不重建、
改 `app/` 會重建、五道安全閘門。

**2026-09-11 活動當天實地驗證**：對真實 Docker Hub 帳號的推送成立——五組各自建置並推送成功，
沒有一次推送失敗。`--pull=false` 搭配預先拉好的基底映像檔、`--network=none` 建置、安全閘門
（未合併的骨架 repo 一律擋在「沒有 Dockerfile」）全部如預期。

換 repo 的偵測是活動後補的，用兩個「內容與 commit SHA 完全相同、只有網址不同」的 repo 測過六個
案例：換 repo、僅大小寫／`.git`／斜線不同不觸發、`--check` 無副作用、無 `.repo` 的升級路徑、
換分支、完全沒變的回歸。同一組 fixture 在舊版上**完全沒有輸出**——那正是它危險的地方。

**還沒驗證的**：八組同時觸發時的排隊時間（`ks26-measure-queue.sh` 已收錄但尚未實跑）。
