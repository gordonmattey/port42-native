# The relay (nautilus Phase 4). Build context: gateway/.
# BLD-08: bases pinned by digest (resolved 2026-09-28), so a moved tag cannot change what is built or
# shipped; the runtime image is distroless :nonroot, so the server does not run as root.
FROM golang:1.24-alpine@sha256:8bee1901f1e530bfb4a7850aa7a479d17ae3a18beb6e09064ed54cfd245b7191 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /port42-relay ./cmd/port42-relay

FROM gcr.io/distroless/static-debian12:nonroot@sha256:afa5c872c891853ca7fcf1f12c3edb23f7eeef36189728842dd51042ff57f7ab
COPY --from=build /port42-relay /port42-relay
ENV PORT=8080
EXPOSE 8080
ENTRYPOINT ["/port42-relay"]
