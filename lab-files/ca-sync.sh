#!/bin/bash
LOGFILE=/var/log/ca-sync.log
SRC=/etc/puppetlabs/puppet/ssl/ca/
ME=$(hostname -s)
[ -f "${SRC}ca_crt.pem" ] && [ -d "${SRC}signed" ] || { echo "$(date): ABORTED - CA state incomplete" >> "$LOGFILE"; exit 1; }
for entry in "puppetca1:10.0.1.40" "puppetca2:10.1.0.50"; do
  h="${entry%%:*}"; ip="${entry##*:}"
  if [ "$h" != "$ME" ]; then
    rsync -az --delete -e "ssh -o StrictHostKeyChecking=no" "$SRC" "root@${ip}:${SRC}" >> "$LOGFILE" 2>&1
    rsync -az -e "ssh -o StrictHostKeyChecking=no" /etc/puppetlabs/puppet/autosign.conf "root@${ip}:/etc/puppetlabs/puppet/autosign.conf" >> "$LOGFILE" 2>&1
    ssh -o StrictHostKeyChecking=no "root@${ip}" "chown root:puppet /etc/puppetlabs/puppet/autosign.conf; chmod 750 /etc/puppetlabs/puppet/autosign.conf; systemctl restart puppetserver" >> "$LOGFILE" 2>&1
  fi
done
echo "$(date): sync complete (from $ME)" >> "$LOGFILE"
