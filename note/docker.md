```jsx
FROM python:3.9

WORKDIR /app

COPY . /app

EXPOSE 80

RUN mkdir /mnt/efs

ENV AWS_DEFAULT_REGION=us-east-1

CMD ["./server-root"]
```

```jsx
FROM golang:latest

WORKDIR /app

COPY . /app

RUN go mod tidy

RUN go build -o main .

EXPOSE 80

CMD ["./main"]
```

```docker

FROM public.ecr.aws/docker/library/tomcat:8.5.93-jdk8-corretto-al2

MAINTAINER Kai

COPY <test.war> /usr/local/tomcat/webapps/

CMD ["/usr/local/tomcat/bin/catalina.sh","run"]

```

```jsx
#!/bin/bash
cat > server.ini <<EOF
"LogLocation" = "./"
"FsPath" = "${FS_PATH}"
"PgsqlHost" = "${POSTGRES_HOST}"
"PgsqlPort" = "${POSTGRES_PORT}"
"PgsqlUser" = "${POSTGRES_USER}"
"PgsqlPass" = "${POSTGRES_PASSWORD}"
"PgsqlDb" = "${POSTGRES_DATABASE}"
"PgsqlTable" = "${POSTGRES_TABLE}"
"MysqlHost" = "${MYSQL_HOST:-localhost}"
"MysqlPort" = "${MYSQL_PORT:-3306}"
"MysqlUser" = "${MYSQL_USER}"
"MysqlPass" = "${MYSQL_PASSWORD}"
"MysqlDb" = "${MYSQL_DATABASE}"
"MongoDbHost" = "${MONGODB_HOST}"
"MongoDbPort" = "${MONGODB_PORT}"
"MongoDbUser" = "${MONGODB_USER}"
"MongoDbPass" = "${MONGODB_PASSWORD}"
"MongoDbDatabase" = "${MONGODB_DATABASE}"
"MongoDbCollection" = "${MONGODB_COLLECTION}"
"MongoDbCAFilePath" = "rds-combined-ca-bundle.pem"
"MongoDbEnableSSL" = ${MONGODB_ENABLE_SSL:-false}
"RedisHost" = "${REDIS_HOST:-localhost}"
"RedisPort" = "${REDIS_PORT:-6379}"
"MemcacheHost" = "${MEMCACHED_HOST}"
"MemcachePort" = "${MEMCACHED_PORT}"
"AwsRegion" = "${AWS_REGION}"
EOF
chmod -R ugo+rwx /root
/root/server -config /root/server.ini
```

```jsx
FROM alpine:latest

ARG SERVER_BINARY_URL

RUN apk update &&\
    apk upgrade &&\
    apk add libc6-compat python3 jq dos2unix ca-certificates --no-cache &&\
    rm -rf /var/cache/apk/* /root/.cache/* /usr/share/terminfo &&\
    update-ca-certificates 2>/dev/null || true

USER root
WORKDIR /root

ADD ${SERVER_BINARY_URL:-./server} server
ADD https://s3.amazonaws.com/rds-downloads/rds-combined-ca-bundle.pem rds-combined-ca-bundle.pem
ADD run.sh .
ADD *database.sql .
RUN chmod +x run.sh && \
    dos2unix run.sh && \
    apk --purge -v del dos2unix && rm -rf /var/cache/apk/* /root/.cache/* /usr/share/terminfo

CMD ["sh", "run.sh"]
```