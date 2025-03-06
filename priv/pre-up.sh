#!/usr/bin/env bash
#
# Args
# 1: Wireguard Network Interface Name
# 2: Destination service port number
# 3: Interface Address
# 4: Interface Allowed IPs
# 5: Default route=

set -e

WG_IFNAME=$1
DPORT=$2
ADDRESS=$3
ALLOWED_IPS=$4
WAN_IFNAME=$5
