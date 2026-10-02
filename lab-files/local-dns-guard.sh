#!/bin/bash
# Secondary LB only (puppetmaster1): start dnsmasq only if puppetca1's HAProxy is unreachable
timeout 2 bash -c "echo > /dev/tcp/10.0.1.40/8142" 2>/dev/null
if [ $? -ne 0 ]; then
  systemctl is-active --quiet dnsmasq || systemctl start dnsmasq
else
  systemctl is-active --quiet dnsmasq && systemctl stop dnsmasq
fi
