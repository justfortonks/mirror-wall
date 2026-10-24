FROM golang:1.23-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY *.go ./
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /relay .

FROM gcr.io/distroless/static-debian12
COPY --from=build /relay /relay
EXPOSE 7000
ENTRYPOINT ["/relay"]
