#!/usr/bin/env bash
set -euo pipefail
: "${DOCKERHUB_USER:?請先設定 DOCKERHUB_USER}"
TAG="$(git rev-parse --short HEAD)"
IMG="docker.io/${DOCKERHUB_USER}/ks26-app:${TAG}"
docker build --platform linux/amd64 -t "${IMG}" .
docker push "${IMG}"
echo "接下來：把 deploy/deployment.yaml 的 image 換成 ${IMG}，commit 進 main"
