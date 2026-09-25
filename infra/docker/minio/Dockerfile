# MinIO built from source, at the release the development stack already uses
# (RELEASE.2025-09-07T16-13-09Z). quay.io refuses anonymous pulls of MinIO
# images and Docker Hub no longer carries them, so a fresh machine or a CI
# runner cannot download the image: it builds it instead. The commit is
# checked, so a moved tag cannot slip a different MinIO in.
#
# Which object store production uses is decided at Deployment (known-risks.md);
# this keeps development and CI working meanwhile, with the same MinIO.
FROM golang:1.24-alpine AS build
ARG MINIO_TAG=RELEASE.2025-09-07T16-13-09Z
ARG MINIO_COMMIT=07c3a429bfed433e49018cb0f78a52145d4bedeb
RUN apk add --no-cache git
RUN git clone --depth 1 --branch "$MINIO_TAG" https://github.com/minio/minio /src \
 && test "$(git -C /src rev-parse HEAD)" = "$MINIO_COMMIT"
WORKDIR /src
RUN CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o /out/minio .

FROM alpine:3.21
COPY --from=build /out/minio /usr/bin/minio
EXPOSE 9000 9001
# No mc here: the health endpoint is checked with busybox wget instead.
HEALTHCHECK --interval=5s --timeout=5s --retries=10 \
  CMD wget -q --spider http://127.0.0.1:9000/minio/health/live || exit 1
ENTRYPOINT ["minio"]
CMD ["server", "/data", "--console-address", ":9001"]
