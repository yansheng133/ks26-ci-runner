# 給 agent 的產出規則

任何 coding agent 讀這份檔案都應該能產出通過驗證的結果。這份檔案刻意不綁定任何特定工具或模型。

## 你要產出什麼

```
./Dockerfile              多階段建置
./build.sh                建置與推送腳本
./app/main.go             應用程式（純 Go，CGO_ENABLED=0）
./app/go.mod
./deploy/configmap.yaml   設定
./deploy/deployment.yaml  部署宣告
./deploy/service.yaml
./deploy/ingress.yaml     對外入口
```

需求見 `REQUEST.md`。硬性限制見 `hard-constraints.md`，共十條，每一條都會被機器檢查。

## 交件條件（這是唯一的驗收標準）

產出之後，**你自己執行 `./verify.sh`**。

- 沒有全部通過，就是還沒做完。看它指出哪一條沒過，修正，重跑。
- **重複到全部通過為止，才算交件。**
- 不要回報「大致完成」「應該可以了」。驗證器說全過，才是完成。

這一點是整份規則的核心：**約束的價值不在寫得漂亮，在於它可以被自動檢查。**
檢查不了的約束只是願望；能檢查的約束才會真的成立。

## 十條硬性限制（摘要，完整說明見 hard-constraints.md）

1. 服務聽單一 HTTP 埠，埠號由環境變數指定，`service.targetPort` 與 `containerPort` 一致。
2. 提供 `GET /healthz` 回 200，且 liveness 與 readiness 探針都指向它。
3. 容器映像檔要小：多階段建置，最終階段用 `scratch` 或 distroless，只放靜態執行檔。
4. 映像檔標籤必須唯一（用 commit SHA），不得用 `latest`；`imagePullPolicy` 必須明寫。
5. 容器一定要宣告 `resources.requests` 與 `resources.limits`。
6. 不得要求 `privileged`，不得以 uid 0 執行，必須明寫 `runAsNonRoot: true`。
7. 所有設定走環境變數注入，程式與宣告裡不得有寫死的網址、帳號或密語。
8. 沒有推論後端（`INFERENCE_URL` 未設定或連不上）時要降級運作：`/healthz` 照常 200，問答回罐頭訊息並標示降級。
9. `Dockerfile` 的 builder 階段必須釘 `FROM --platform=$BUILDPLATFORM`，並以 `ARG TARGETARCH` 決定 `GOARCH`；`build.sh` 必須明寫 `--platform`。
10. `configmap` 的 `APP_OWNER` 必須填實名，產出物裡不得留 `TODO-` / `CHANGE-ME` / `FIXME` / `REPLACE-*` 之類的佔位字串。
11. 映像檔一律推送到 **Docker Hub**：`build.sh` 與 `deployment.yaml` 都要明寫 `docker.io/` 開頭，
    帳號用變數（例如 `docker.io/${DOCKERHUB_USER}/...`），**不得改用 ghcr.io、quay.io、gcr.io 或任何其他 registry**。

## 不要做的事

- 不要為了讓檢查通過而改 `verify.sh`。驗證器是規格的一部分，不是你的產出物。
- 不要新增規則以外的相依套件。純標準庫就做得到。
- 不要把設定寫死在程式或映像檔裡，即使那樣比較短。
- 不要在產出物裡放任何真實憑證、token 或內部位址。
- 不確定的地方選**比較保守**的那一個（權限給少、資源宣告寫明、預設值明寫）。
