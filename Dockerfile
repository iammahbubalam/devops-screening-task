# syntax=docker/dockerfile:1

# ---- Build stage -------------------------------------------------------------
# Runs on the build machine's own platform and cross-compiles for the target
# platform, so building the arm64 image needs no QEMU emulation.
# Tags are written out (not taken from ARG) so Dependabot can bump them.
FROM --platform=$BUILDPLATFORM golang:1.27.3-alpine@sha256:fa3d596898d9f126af7c01d14ee7597bab3f39cccf392ef36b69fe77cd681f18 AS build

WORKDIR /src

# go.mod is copied on its own so the dependency layer stays cached when only
# source files change. The app uses the standard library only, so today this
# step downloads nothing; the layer order is ready for when that changes.
COPY app/go.mod ./
RUN go mod download

COPY app/ ./

ARG TARGETOS
ARG TARGETARCH
# CGO_ENABLED=0       static binary, so the runtime image needs no libc
# -trimpath           no local file paths inside the binary
# -ldflags="-s -w"    drop the symbol table and debug info (smaller binary)
RUN --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags="-s -w" -o /out/server .

# ---- Runtime stage -----------------------------------------------------------
# distroless/static has no shell and no package manager. It contains only CA
# certificates, tzdata and an unprivileged "nonroot" user.
FROM gcr.io/distroless/static-debian13:nonroot@sha256:aafe993665bf6200db38a02c11a9351e782a84b6a45e7f33b6695638c88e3931

COPY --from=build /out/server /server

# 65532 is distroless's "nonroot" user. A numeric UID lets Kubernetes
# (runAsNonRoot) confirm the user is not root without reading /etc/passwd.
USER 65532:65532

EXPOSE 8080

# No curl in the image, so the binary probes itself.
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD ["/server", "-healthcheck"]

ENTRYPOINT ["/server"]
