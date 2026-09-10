# Multi-stage build example (Go). Replace with your language/runtime.
FROM golang:1.25-alpine AS build
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /app/server .

FROM alpine:3.21
RUN apk add --no-cache ca-certificates
COPY --from=build /app/server /server
USER 65534:65534
ENTRYPOINT ["/server"]
