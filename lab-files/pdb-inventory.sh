#!/bin/bash
# Fleet inventory from PuppetDB: OS, release, kernel, hostgroup, last boot (UTC)
PDB=http://localhost:8080/pdb/query/v4
curl -s -G "$PDB/facts" --data-urlencode 'query=["in","name",["array",["operatingsystem","operatingsystemrelease","kernelrelease","uptime_seconds","intended_hostgroup"]]]' > /tmp/pdb_facts.json
curl -s "$PDB/nodes" > /tmp/pdb_nodes.json
python3 - <<'PY'
import json, datetime
facts = json.load(open('/tmp/pdb_facts.json'))
nodes = {n['certname']: n for n in json.load(open('/tmp/pdb_nodes.json'))}
d = {}
for r in facts:
    d.setdefault(r['certname'], {})[r['name']] = r['value']
fmt = "%-28s %-8s %-9s %-28s %-10s %-17s %s"
print(fmt % ("NODE", "OS", "RELEASE", "KERNEL", "HOSTGROUP", "LAST BOOT (UTC)", "LAST REPORT"))
for c in sorted(d):
    v = d[c]; n = nodes.get(c, {})
    boot = "-"
    ts = n.get('facts_timestamp')
    if ts and 'uptime_seconds' in v:
        t = datetime.datetime.strptime(ts[:19], '%Y-%m-%dT%H:%M:%S')
        boot = (t - datetime.timedelta(seconds=int(v['uptime_seconds']))).strftime('%Y-%m-%d %H:%M')
    print(fmt % (c, v.get('operatingsystem', '-'), v.get('operatingsystemrelease', '-'),
                 v.get('kernelrelease', '-'), v.get('intended_hostgroup', '-'), boot,
                 n.get('latest_report_status') or '-'))
PY
