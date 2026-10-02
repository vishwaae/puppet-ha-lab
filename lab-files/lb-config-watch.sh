#!/bin/bash
LAST_STATE=""
while true; do
  CURRENT_STATE=$(md5sum /etc/dnsmasq.d/static-hosts.conf /etc/haproxy/haproxy.cfg 2>/dev/null | md5sum)
  if [ "$CURRENT_STATE" != "$LAST_STATE" ]; then
    /usr/local/bin/lb-config-sync.sh
    LAST_STATE="$CURRENT_STATE"
  fi
  sleep 3
done
