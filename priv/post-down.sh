#!/usr/bin/env bash
#
# Args
# 1: Wireguard Network Interface Name
# 2: Destination service port number

set -e

IFNAME=$1
DPORT=$2

iptables -D INPUT -m state --state RELATED,ESTABLISHED -i $IFNAME -j ACCEPT
iptables -D INPUT -p tcp --dport $DPORT -i $IFNAME -j ACCEPT
