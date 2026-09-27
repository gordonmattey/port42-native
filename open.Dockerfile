# The invite page's server, open.port42.ai (nautilus Phase 4, 4.7). Build context: the repo root.
FROM golang:1.24-alpine AS build
WORKDIR /src
COPY gateway/go.mod gateway/go.sum ./
RUN go mod download
COPY gateway/ .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /port42-open ./cmd/port42-open

FROM gcr.io/distroless/static-debian12
COPY --from=build /port42-open /port42-open
COPY guest/invite.html guest/frame.html /site/
COPY guest/dist/port42-guest.js /site/dist/
ENV PORT=8080
EXPOSE 8080
ENTRYPOINT ["/port42-open", "-dir", "/site"]
