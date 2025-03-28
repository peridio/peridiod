FROM hexpm/elixir:1.18.3-erlang-27.3-alpine-3.21.3 AS build

ARG MIX_ENV=prod
ARG UBOOT_ENV_SIZE=0x20000
ARG PERIDIO_META_PRODUCT=peridiod
ARG PERIDIO_META_DESCRIPTION=peridiod
ARG PERIDIO_META_VERSION
ARG PERIDIO_META_PLATFORM=alpine
ARG PERIDIO_META_ARCHITECTURE
ARG PERIDIO_META_AUTHOR=peridio

RUN apk add --no-cache \
    linux-headers \
    build-base \
    gcc \
    automake \
    u-boot-tools \
    libsodium-dev \
    autoconf \
    libtool \
    libmnl-dev \
    libarchive-dev \
    confuse-dev \
    xdelta3 \
    dosfstools \
    help2man \
    curl \
    mtools \
    unzip \
    zip \
    make \
    git

RUN mix archive.install github hexpm/hex branch latest --force
RUN /usr/local/bin/mix local.rebar --force

# Build fwup here to ensure that its built for the arch
WORKDIR /opt
RUN git clone https://github.com/fwup-home/fwup --depth 1 --branch v1.12.0
WORKDIR /opt/fwup
RUN ./autogen.sh && PKG_CONFIG_PATH=$PKG_CONFIG_PATH ./configure --enable-shared=no && make && make install

RUN mkdir -p /opt/app
ADD . /opt/app/

WORKDIR /opt/app

RUN echo "/etc/peridiod/uboot.env 0x0000 ${UBOOT_ENV_SIZE}" > /opt/app/support/fw_env.config
RUN mkenvimage -s ${UBOOT_ENV_SIZE} -o /opt/app/support/uboot.env /opt/app/support/uEnv.txt
RUN PERIDIO_META_PRODUCT=${PERIDIO_META_PRODUCT} \
    PERIDIO_META_DESCRIPTION=${PERIDIO_META_DESCRIPTION} \
    PERIDIO_META_VERSION=${PERIDIO_META_VERSION} \
    PERIDIO_META_PLATFORM=${PERIDIO_META_PLATFORM} \
    PERIDIO_META_ARCHITECTURE=${PERIDIO_META_ARCHITECTURE} \
    PERIDIO_META_AUTHOR=${PERIDIO_META_AUTHOR} \
    fwup -c -f support/fwup.conf -o support/peridiod.fw
RUN fwup -a -t complete -i support/peridiod.fw -d support/peridiod.img
RUN mix deps.get --only $MIX_ENV
RUN mix release --overwrite

FROM alpine:3.21 AS app

RUN apk add --no-cache \
    agetty \
    confuse \
    libarchive \
    libstdc++ \
    libgcc \
    socat \
    iproute2  \
    iptables \
    uuidgen \
    openssl \
    wireguard-tools-wg-quick \
    openssh-server \
    coreutils

RUN apk add opkg --repository=https://dl-cdn.alpinelinux.org/alpine/edge/testing
RUN apk add apt --repository=https://dl-cdn.alpinelinux.org/alpine/edge/community

RUN ssh-keygen -A
RUN addgroup "peridio"
RUN adduser --disabled-password --ingroup "peridio" "peridio"
RUN echo "peridio:peridio" | chpasswd

ENV PERIDIO_CONFIG_FILE=/etc/peridiod/peridio.json

RUN mkdir -p /etc/peridiod/hooks
RUN mkdir -p /boot
RUN echo "#!/bin/bash" > /usr/bin/reboot
RUN echo "echo \"Reboot Requested\"" >> /usr/bin/reboot
RUN echo "exit 0" >> /usr/bin/reboot
RUN chmod +x /usr/bin/reboot

COPY --from=build /opt/app/priv/peridio-cert.pem /etc/peridiod/peridio-cert.pem
COPY --from=build /opt/app/_build/prod/rel/peridiod /opt/peridiod
COPY --from=build /opt/app/support/peridio.json /etc/peridiod/peridio.json
COPY --from=build /opt/app/support/uboot.env /etc/peridiod/uboot.env
COPY --from=build /opt/app/support/fw_env.config /etc/fw_env.config
COPY --from=build /opt/app/support/peridiod.img /etc/peridiod/peridiod.img
COPY --from=build /opt/app/support/pre-up.sh /etc/peridiod/hooks/pre-up.sh
COPY --from=build /opt/app/support/pre-down.sh /etc/peridiod/hooks/pre-down.sh
COPY --from=build /opt/fwup/src/fwup /usr/bin/fwup

WORKDIR /opt/peridiod

COPY --from=build /opt/app/support/entrypoint.sh entrypoint.sh
COPY --from=build /opt/app/support/openssl.cnf openssl.cnf
RUN chmod +x entrypoint.sh

ENTRYPOINT ["/opt/peridiod/entrypoint.sh"]

CMD ["/opt/peridiod/bin/peridiod", "start_iex"]
