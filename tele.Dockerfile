# The invite page's server, tele.port42.ai (nautilus Phase 4, 4.7). Build context: the repo root.
FROM golang:1.24-alpine AS build
WORKDIR /src
COPY gateway/go.mod gateway/go.sum ./
RUN go mod download
COPY gateway/ .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /port42-tele ./cmd/port42-tele

FROM gcr.io/distroless/static-debian12
COPY --from=build /port42-tele /port42-tele
COPY guest/invite.html guest/frame.html /site/
COPY guest/dist/port42-guest.js /site/dist/
ENV PORT=8080
EXPOSE 8080
ENTRYPOINT ["/port42-tele", "-dir", "/site"]
