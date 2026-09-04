# ks26 CI runner

活動當天替各組建置容器映像檔的那台機器,以及它的建置看板。

**用完即丟**:它跑的是學員 repo 裡由 agent 產生的 Dockerfile,`docker build` 的 `RUN`
就是執行任意指令,所以這件事不該發生在放著客戶資料的筆電上。

驗證環境:SLES 16、2 vCPU／8 GB、docker 29.4、SELinux enforcing。

## 兩個目錄

| | |
|---|---|
| [`ks26-buildvm/`](ks26-buildvm/) | 建置機:bootstrap、watcher、selftest、建置看板 |
| [`ks26-constraints/`](ks26-constraints/) | 「約束驅動」教材包:約束表、合格與違規範例、`verify.sh` |

兩個目錄要**並排**放:`ks26-selftest.sh` 預設用 `../ks26-constraints/examples/good`
當參考產出物。

## 快速開始

```bash
# 在建置機上
cd ks26-buildvm && sudo -E ./ks26-runner-bootstrap.sh
docker login --username <你的 Docker Hub 帳號>     # 只用互動輸入,不要用 -p
KS26_REGISTRY=docker.io/<帳號> ./ks26-selftest.sh   # 應得 13 PASS / 0 FAIL
```

換掉 Docker Hub 帳號:`./ks26-set-registry.sh <新帳號>`(它散在五個檔案裡)。

細節看 [`ks26-buildvm/README.md`](ks26-buildvm/README.md)。

## 建置看板

`ks26-board.py` ＋ `ks26-board.html`,把 watcher 的狀態變成一頁可投影的網頁:
各組進度條、已建好的映像檔清單、watcher 最近輸出。SUSE 配色。

**進度條讀的是真實的 BuildKit 步驟**,不是動畫。有三個不明顯的地方:

1. BuildKit 的 `x/y` 是**每個 stage 各自**的編號。多階段會有 `builder 1..4/4` 與
   `stage-1 1/1`,總步數要各 stage 相加(=5);取最大值的話一開始就會跳到 100%。
2. `#8 [builder 4/4] RUN ...` 是該步**開始**時印的,完成標記是後面的 `#8 DONE` 或
   `#8 CACHED`(CACHED 不會再印 DONE)。數開始行會讓建置一秒就顯示滿格。
3. 「封裝推送中」要用 `#N exporting to image` 判斷;用「已知步驟都做完了」的話,
   下一個 stage 還沒宣告時會誤報。

還在跑的建置進度上限停在 95%,不會提早顯示滿格。

**看板會把自己正在讀的 `groups.conf` 路徑顯示在標題下方**,指到非預設路徑時右上角亮
「非正式路徑」警示。這是被真實事故逼出來的:服務曾經被留在驗證沙箱的路徑上,
畫面一切正常、沒有任何錯誤,只是投影出來的是一組叫 `demo1` 的假資料。
這種錯不會自己叫,只能讓它顯示在臉上。

正式路徑由 `board-paths.conf` 裝到
`/etc/systemd/system/ks26-board.service.d/paths.conf`;`board-paths-demo.conf` 是驗證用的,
**不要留在正式機上**。`systemctl cat ks26-board` 一眼就看得到目前讀的是哪裡。

跑法兩種,見 [`ks26-buildvm/README.md`](ks26-buildvm/README.md#建置看板選用可投影)。

## 安全邊界

- **只讀,不執行**:watcher 永遠不跑學員 repo 裡的任何腳本,建置指令寫死在 watcher 裡。
- **建置期沒有網路**:`--network=none`,基底映像檔必須先在本機(`--pull=false`)。
- **五道閘門**:外部 `# syntax=` frontend、`--mount=type=secret|ssh`、`security=insecure`、
  沒有 Dockerfile、repo 體積超標——任一條沒過就跳過該組,不進 build。
- 看板只讀檔,不寫 watcher 的任何狀態;以非 root 執行,靠
  `AmbientCapabilities=CAP_NET_BIND_SERVICE` 綁 80。
