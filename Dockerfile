FROM hexpm/elixir:1.16.2-erlang-26.2.5-ubuntu-noble-20240429 AS build

ARG MIX_ENV=prod
ARG UBOOT_ENV_SIZE=0x20000
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y \
    git make build-essential \
    u-boot-tools \
    libsodium-dev \
    autotools-dev \
    autoconf \
    libtool \
    pkg-config \
    libarchive-dev \
    libconfuse-dev \
    zlib1g-dev \
    xdelta3 \
    dosfstools \
    help2man \
    curl \
    mtools \
    unzip \
    zip

RUN mix archive.install github hexpm/hex branch latest --force
RUN /usr/local/bin/mix local.rebar --force

# Build fwup here to ensure that its built for the arch
WORKDIR /opt
RUN git clone https://github.com/fwup-home/fwup --depth 1 --branch v1.10.2
WORKDIR /opt/fwup
RUN ./autogen.sh && PKG_CONFIG_PATH=$PKG_CONFIG_PATH ./configure --enable-shared=no && make && make install

RUN mkdir -p /opt/app
ADD . /opt/app/

WORKDIR /opt/app

RUN echo "/etc/peridiod/uboot.env 0x0000 ${UBOOT_ENV_SIZE}" > /opt/app/support/fw_env.config
RUN mkenvimage -s ${UBOOT_ENV_SIZE} -o /opt/app/support/uboot.env /opt/app/support/uEnv.txt
RUN PERIDIO_META_PRODUCT=peridiod \
    PERIDIO_META_DESCRIPTION=peridiod-dev \
    PERIDIO_META_VERSION=1.0.0 \
    PERIDIO_META_PLATFORM=docker \
    PERIDIO_META_ARCHITECTURE=docker \
    PERIDIO_META_AUTHOR=peridio \
    fwup -c -f support/fwup.conf -o support/peridiod.fw
RUN fwup -a -t complete -i support/peridiod.fw -d support/peridiod.img
RUN mix deps.get --only $MIX_ENV
RUN mix release --overwrite

FROM ubuntu:noble as app

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get -y install locales socat libconfuse-dev libarchive-dev && apt-get clean
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && \
    locale-gen
ENV LANG en_US.UTF-8
ENV LANGUAGE en_US:en
ENV LC_ALL en_US.UTF-8

RUN useradd -ms /bin/bash peridio
RUN echo "peridio:peridio" | chpasswd

ENV PERIDIO_CONFIG_FILE=/etc/peridiod/peridio.json

RUN mkdir -p /etc/peridiod
RUN mkdir -p /boot
RUN echo "echo \"Reboot Requested\"" > /usr/bin/reboot && chmod +x /usr/bin/reboot

COPY --from=build /opt/app/priv/peridio-cert.pem /etc/peridiod/peridio-cert.pem
COPY --from=build /opt/app/_build/prod/rel/peridiod /opt/peridiod
COPY --from=build /opt/app/support/peridio.json /etc/peridiod/peridio.json
COPY --from=build /opt/app/support/uboot.env /etc/peridiod/uboot.env
COPY --from=build /opt/app/support/fw_env.config /etc/fw_env.config
COPY --from=build /opt/app/support/peridiod.img /etc/peridiod/peridiod.img
COPY --from=build /opt/fwup/src/fwup /usr/bin/fwup

WORKDIR /opt/peridiod
CMD ["/opt/peridiod/bin/peridiod", "start_iex"]
