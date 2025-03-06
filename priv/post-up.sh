#!/usr/bin/env bash
#
# Args
# 1: Wireguard Network Interface Name
# 2: Destination service port number
# 3: Interface Address
# 4: Interface Allowed IPs
# 5: Default route
# 6: The peer endpoint address
# 7: The routing table number

set -e

WG_IFNAME=$1
DPORT=$2
ADDRESS=$3
ALLOWED_IPS=$4
WAN_IFNAME=$5
ENDPOINT=$6
TABLE=$7

iptables -A INPUT -m state --state RELATED,ESTABLISHED -i $WG_IFNAME -j ACCEPT
iptables -A INPUT -p tcp --dport $DPORT -i $WG_IFNAME -j ACCEPT

if [ -n "$WAN_IFNAME" ]; then
  WAN_GATEWAY=$(ip route show dev $WAN_IFNAME | grep default | awk '{print $3}')

  ip route show table $TABLE | grep -q "default" && ip route del default table $TABLE
  ip route add default via $WAN_GATEWAY dev $WAN_IFNAME table $TABLE 2>/dev/null || true
  ip route add $ALLOWED_IPS dev $WG_IFNAME table $TABLE 2>/dev/null || true

  ip rule add from all to $ENDPOINT lookup $TABLE 2>/dev/null || true
  ip rule add from $ADDRESS lookup $TABLE 2>/dev/null || true
  ip rule add from all to ${ALLOWED_IPS%%/*} lookup $TABLE 2>/dev/null || true

  echo 1 > /proc/sys/net/ipv4/ip_forward

  iptables -A FORWARD -i $WG_IFNAME -o $WAN_IFNAME -j ACCEPT
  iptables -A FORWARD -i $WAN_IFNAME -o $WG_IFNAME -j ACCEPT
fi
