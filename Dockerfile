FROM golang:1.21-alpine3.19 as builder

RUN apk --no-cache add --virtual \
    build-dependencies \
    git \
  && GOPATH=/tmp/gocode go install github.com/mailhog/MailHog@v1.0.1

FROM alpine:3.19
WORKDIR /bin
COPY --from=builder tmp/gocode/bin/MailHog /bin/MailHog
EXPOSE 1025 8025
ENTRYPOINT ["MailHog"]
