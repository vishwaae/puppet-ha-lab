#!/bin/bash
# Syncs dnsmasq static-hosts.conf and haproxy.cfg between puppetca1 and
# puppetmaster1 (the LB pair) — same pattern as ca-sync.sh for
# autosign.conf. Restarts the relevant service on the FAR side after
# each real change, so both nodes stay identical without manual copying.
LOGFILE=/var/log/lb-config-sync.log
ME=$(hostname -s)

# Safety guard — same principle as ca-sync.sh: refuse to sync if the
# local files look genuinely incomplete, so we never propagate a broken
# state to the other node.
if [ ! -s /etc/dnsmasq.d/static-hosts.conf ] || [ ! -s /etc/haproxy/haproxy.cfg ]; then
  echo "$(date): ABORTED - local config looks incomplete" >> "$LOGFILE"
  exit 1
fi

for entry in "puppetca1:10.0.1.40" "puppetmaster1:10.0.1.10"; do
  h="${entry%%:*}"
  ip="${entry##*:}"
  if [ "$h" != "$ME" ]; then
    rsync -az -e "ssh -o StrictHostKeyChecking=no" /etc/dnsmasq.d/static-hosts.conf "root@${ip}:/etc/dnsmasq.d/static-hosts.conf" >> "$LOGFILE" 2>&1
    rsync -az -e "ssh -o StrictHostKeyChecking=no" /etc/haproxy/haproxy.cfg "root@${ip}:/etc/haproxy/haproxy.cfg" >> "$LOGFILE" 2>&1
    ssh -o StrictHostKeyChecking=no "root@${ip}" "systemctl restart dnsmasq && systemctl restart haproxy" >> "$LOGFILE" 2>&1
  fi
done

echo "$(date): sync complete (from $ME)" >> "$LOGFILE"
