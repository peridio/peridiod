FROM elixir:1.16.2-alpine AS build

ARG MIX_ENV=prod

RUN apk add --no-cache --update-cache \
      git \
      make

RUN mix archive.install github hexpm/hex branch latest --force
RUN /usr/local/bin/mix local.rebar --force

RUN mkdir -p /opt/app
ADD . /opt/app/

WORKDIR /opt/app

RUN mix deps.get --only $MIX_ENV
RUN mix release --overwrite

FROM alpine:3.19 as app

RUN apk --no-cache add wireguard-tools iptables ip6tables inotify-tools libstdc++ libgcc u-boot-tools socat iproute2-ss agetty cgroup-tools
RUN apk --no-cache add 'fwup~=1.10' \
  --repository http://nl.alpinelinux.org/alpine/edge/community/

ENV PERIDIO_CONFIG_FILE=/etc/peridiod/peridio.json
ARG UBOOT_ENV_SIZE=0x20000

RUN mkdir -p /etc/peridiod
RUN mkdir -p /boot

COPY --from=build /opt/app/priv/peridio-cert.pem /etc/peridiod/peridio-cert.pem
COPY --from=build /opt/app/_build/prod/rel/peridiod /opt/peridiod
COPY --from=build /opt/app/support/peridio.json /etc/peridiod/peridio.json
COPY --from=build /opt/app/support/uEnv.txt /etc/peridiod/uEnv.txt

RUN echo "/etc/peridiod/uboot.env 0x0000 ${UBOOT_ENV_SIZE}" > /etc/fw_env.config
RUN mkenvimage -s ${UBOOT_ENV_SIZE} -o /etc/peridiod/uboot.env /etc/peridiod/uEnv.txt

WORKDIR /opt/peridiod
CMD ["/opt/peridiod/bin/peridiod", "start_iex"]
