#!/usr/bin/env bash
#
# Args
# 1: Wireguard Network Interface Name
# 2: Destination service port number

set -e

IFNAME=$1
DPORT=$2

iptables -A INPUT -m state --state RELATED,ESTABLISHED -i $IFNAME -j ACCEPT
iptables -A INPUT -p tcp --dport $DPORT -i $IFNAME -j ACCEPT

