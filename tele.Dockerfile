# The invite page's server, tele.port42.ai (nautilus Phase 4, 4.7). Build context: the repo root.
# BLD-08: bases pinned by digest (resolved 2026-09-28), so a moved tag cannot change what is built or
# shipped; the runtime image is distroless :nonroot, so the server does not run as root.
FROM golang:1.24-alpine@sha256:8bee1901f1e530bfb4a7850aa7a479d17ae3a18beb6e09064ed54cfd245b7191 AS build
WORKDIR /src
COPY gateway/go.mod gateway/go.sum ./
RUN go mod download
COPY gateway/ .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /port42-tele ./cmd/port42-tele

FROM gcr.io/distroless/static-debian12:nonroot@sha256:afa5c872c891853ca7fcf1f12c3edb23f7eeef36189728842dd51042ff57f7ab
COPY --from=build /port42-tele /port42-tele
COPY guest/invite.html guest/frame.html /site/
COPY guest/dist/port42-guest.js /site/dist/
ENV PORT=8080
EXPOSE 8080
ENTRYPOINT ["/port42-tele", "-dir", "/site"]
