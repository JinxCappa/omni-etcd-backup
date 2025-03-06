FROM gcr.io/etcd-development/etcd:v3.5.19 AS etcd

FROM alpine:3.21.3 AS builder

RUN apk add --no-cache wget

RUN wget https://github.com/peak/s5cmd/releases/download/v2.3.0/s5cmd_2.3.0_Linux-64bit.tar.gz -O /usr/local/bin/s5cmd.tar.gz && \
  tar -xvf /usr/local/bin/s5cmd.tar.gz -C /usr/local/bin/ && \
  chmod +x /usr/local/bin/s5cmd

FROM alpine:3.21.3
LABEL maintainer="JinxCappa <jinxcappa@fastmail.com>"
LABEL org.opencontainers.image.source=https://github.com/jinxcappa/omni-etcd-backup
LABEL org.opencontainers.image.description="This is a simple image that contain the requirement to backup an etcd omni instance to B2."
LABEL org.opencontainers.image.licenses=Apache-2.0

# Copy required binaries from etcd image
COPY --from=etcd /usr/local/bin/etcdctl /usr/local/bin/etcdctl
COPY --from=etcd /usr/local/bin/etcdutl /usr/local/bin/etcdutl
COPY --from=builder /usr/local/bin/s5cmd /usr/local/bin/s5cmd

RUN apk add --no-cache bash gnupg xz tini

ENV PATH="$PATH:/scripts"

WORKDIR /scripts

COPY backup.sh backup
RUN chmod +x backup

COPY restore.sh restore
RUN chmod +x restore

COPY daemon daemon
RUN chmod +x daemon

ENTRYPOINT [ "/sbin/tini", "--" ]

CMD [ "daemon" ]