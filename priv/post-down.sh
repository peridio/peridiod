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

WG_IFNAME=$1
DPORT=$2
ADDRESS=$3
ALLOWED_IPS=$4
WAN_IFNAME=$5
ENDPOINT=$6
TABLE=$7

iptables -D INPUT -m state --state RELATED,ESTABLISHED -i $WG_IFNAME -j ACCEPT 2>/dev/null || true
iptables -D INPUT -p tcp --dport $DPORT -i $WG_IFNAME -j ACCEPT 2>/dev/null || true

if [ -n "$WAN_IFNAME" ]; then
  ip route del $ALLOWED_IPS dev $WG_IFNAME table $TABLE 2>/dev/null || true

  ip rule del from $ADDRESS table $TABLE 2>/dev/null 2>/dev/null || true
  ip rule del from all to ${ALLOWED_IPS%%/*} lookup $TABLE 2>/dev/null || true

  iptables -D FORWARD -i $WG_IFNAME -o $WAN_IFNAME -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -i $WAN_IFNAME -o $WG_IFNAME -j ACCEPT 2>/dev/null || true
fi
