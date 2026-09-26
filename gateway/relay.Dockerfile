# The relay (nautilus Phase 4). Build context: gateway/.
FROM golang:1.24-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /port42-relay ./cmd/port42-relay

FROM gcr.io/distroless/static-debian12
COPY --from=build /port42-relay /port42-relay
ENV PORT=8080
EXPOSE 8080
ENTRYPOINT ["/port42-relay"]
