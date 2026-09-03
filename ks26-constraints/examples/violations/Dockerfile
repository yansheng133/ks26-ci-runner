# 多階段：builder 釘在本機架構做交叉編譯，最終階段只放一支靜態執行檔
FROM --platform=$BUILDPLATFORM golang:1-alpine AS builder
ARG TARGETARCH
WORKDIR /src
COPY app/go.mod ./
COPY app/ ./
RUN CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} go build -ldflags="-s -w" -o /out/app .

FROM scratch
COPY --from=builder /out/app /app
ENTRYPOINT ["/app"]
