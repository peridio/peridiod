#!/bin/bash

INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
[ -z "$INTERFACE" ] && INTERFACE=$(ip link show | awk -F': ' '/^[0-9]+: [^lo]/{print $2; exit}')

IP=$(ip -4 addr show | awk '/inet / && !/127.0.0.1/ {sub(/\/.*/, "", $2); print $2; exit}')

GATEWAY=$(ip route show default 2>/dev/null | awk '{print $3; exit}')
[ -z "$GATEWAY" ] && GATEWAY=$(route -n 2>/dev/null | awk '/^0.0.0.0/ {print $2; exit}')
[ -z "$GATEWAY" ] && GATEWAY=$(ip route 2>/dev/null | awk '/default via/ {print $3; exit}')

DNS_ARRAY=$(awk '/^nameserver/ {print $2}' /etc/resolv.conf | awk '{printf "\"%s\",", $0}' | sed 's/,$//')

HOSTNAME=$(hostname)

cat <<EOF
{
  "custom": [
    {},
    12,
    null,
    "hehe",
    [{"foo": "bar"}]
  ],
  "networks": [
    {
      "name": "$INTERFACE",
      "ip": "$IP",
      "gateway": "$GATEWAY",
      "dns": [$DNS_ARRAY],
      "hostname": "$HOSTNAME"
    }
  ]
}
EOF
