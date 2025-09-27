FROM golang:1.25.1-alpine3.22 AS builder

WORKDIR /app

COPY go.mod go.sum ./

RUN go mod download

COPY *.go ./

RUN CGO_ENABLED=0 GOOS=linux go build -o /bin/chatbot-insights

FROM gcr.io/distroless/static-debian12

COPY --from=builder /bin/chatbot-insights /bin/chatbot-insights

USER nonroot:nonroot

EXPOSE 8080

ENTRYPOINT ["/bin/chatbot-insights"]
