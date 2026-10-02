#!/bin/bash
LAST=""
while true; do
  CUR=$(find /etc/puppetlabs/puppet/ssl/ca/signed /etc/puppetlabs/puppet/ssl/ca/requests /etc/puppetlabs/puppet/autosign.conf -type f -printf "%p %T@\n" 2>/dev/null | sort | md5sum)
  [ "$CUR" != "$LAST" ] && { /usr/local/bin/ca-sync.sh; LAST="$CUR"; }
  sleep 3
done
