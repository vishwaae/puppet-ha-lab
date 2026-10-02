# Puppet HA Lab on AWS — Runbook

Highly available Puppet infrastructure with zero-touch node onboarding, built on Puppet 5 and
migrated to Puppet 7 without downtime.

## Prerequisites

1. Two AWS accounts (the free tier is enough).
2. AWS CLI and Terraform installed on your laptop.
3. In each AWS account, an IAM user with an access key and secret key, saved on your laptop.
4. One AWS CLI profile per account. **Run on: laptop**
```bash
aws configure --profile terraform2425
aws configure --profile terraform2426
```
5. Nine machines in total:

| Machines | Count |
|---|---|
| puppetmaster1-3 | 3 |
| puppetca1-2 | 2 |
| admin | 1 |
| worker1-3 | 3 |

6. AMI: CentOS 7, `ami-0aedf6b1cb669b4c7`.
7. Software used: Puppet 5 (upgraded to Puppet 7 in Phase 11), Foreman 3.1 as the ENC,
   PuppetDB 7, HAProxy and dnsmasq, r10k, Hiera 5, AWS SSM Parameter Store.

---

## Architecture

| Node | Private IP | Role |
|---|---|---|
| puppetca1 | 10.0.1.40 | Active CA + primary load balancer (HAProxy, dnsmasq) |
| puppetca2 | 10.1.0.50 | Standby CA (continuously synced) |
| puppetmaster1 | 10.0.1.10 | Compile master + secondary load balancer |
| puppetmaster2 | 10.0.1.20 | Compile master |
| puppetmaster3 | 10.0.1.30 | Compile master |
| admin | 10.1.0.60 | Foreman 3.1 (ENC), PuppetDB, hammer CLI |
| worker1 | 10.1.0.70 | Hostgroup `infra` → role::infra (base + vault) |
| worker2 | 10.1.0.80 | Hostgroup `webserver` → role::webserver (base + nginx) |
| worker3 | 10.1.0.90 | Hostgroup `admin` → role::admin (base only) |

| Service name | Points to |
|---|---|
| `puppetmaster.puppetlab.com:8142` | HAProxy → the three masters on 8140 |
| `puppetca.puppetlab.com:8141` | HAProxy → puppetca1 (puppetca2 = backup) |
| `https://admin.puppetlab.com` | Foreman UI |
| `https://admin.puppetlab.com:8081/pdb/dashboard/index.html` | PuppetDB dashboard |

**How a new node joins:** Terraform creates it with `Hostname`/`Hostgroup` tags → cloud-init starts
`post_script.sh` → it reads the Foreman token from SSM and registers itself in its hostgroup →
certificate is autosigned → first Puppet run → `node.rb` asks Foreman → Foreman returns the role
pinned on the hostgroup → the master compiles role + Hiera data → node is configured and reports
to PuppetDB.

---

## Repositories

| Repository | Contents |
|---|---|
| `puppet-control-repo` | Environments `dev` / `production`: Puppetfile, `site/role`, `site/profile`, Hiera `data/` |
| `puppet-modules` | `internal` bundle: nginx, ntp, vault, puppet_agent5, puppet_agent7, puppet_master7 |
| `puppet-timezone-module` | timezone module |
| `puppet-resolve_conf-module` | resolve_conf module |
| `terraform-puppet-lab` | `puppetmaster/`, `worker_setup/`, `worker_setup-agent/` |

**Puppet 5 build, then Puppet 7.** Phases 0–10 build the lab on Puppet 5. In those phases the
worker roles use the `puppet_agent5` module:

| File | Line used in Phases 0–10 |
|---|---|
| `puppet-control-repo/site/role/manifests/infra.pp` | `include puppet_agent5` |
| `puppet-control-repo/site/role/manifests/webserver.pp` | `include puppet_agent5` |
| `puppet-control-repo/site/role/manifests/admin.pp` | `include puppet_agent5` |
| `puppet-control-repo/data/common.yaml` | `puppet_agent5::*` keys |
| `puppet-modules/puppet_agent5/` | the module itself |

Phase 11 replaces `include puppet_agent5` with `include puppet_agent7` (one role at a time) and adds
`puppet_master7` to the server roles. The repositories now hold this final Puppet 7 state.

**Branch rule:** Puppet repos use `dev` → `production`; the Terraform repo uses `dev` → `main`.
Always commit to `dev` first, then merge. Never edit the target branch directly.

**Release a module change** (laptop, in `puppet-modules`):
```bash
git checkout dev && git add -A && git commit -m "<change>" && git push origin dev
git checkout production && git pull origin production && git merge dev && git push origin production
git tag vN && git push origin vN
```
Then set `:tag => 'vN'` for `internal` in the control-repo Puppetfile (dev → production).

---

## Files bundle (`puppet-lab-files.tar.gz`)

| File | Used in | Node |
|---|---|---|
| haproxy.cfg | Phase 3 | puppetca1, puppetmaster1 |
| static-hosts.conf | Phase 3 | puppetca1, puppetmaster1 |
| lb-local.puppetca1.conf / lb-local.puppetmaster1.conf | Phase 3 | puppetca1 / puppetmaster1 |
| local-dns-guard.sh, .service, .timer | Phase 3 | puppetmaster1 |
| lb-config-sync.sh, lb-config-watch.sh, lb-config-watch.service | Phase 3 | puppetca1, puppetmaster1 |
| autosign.conf | Phase 4 | puppetca1, puppetca2 |
| ca-sync.sh, ca-watch.sh, ca-watch.service | Phase 4 | puppetca1, puppetca2 |
| database.ini, jetty.ini | Phase 5 | admin |
| puppetdb.conf, routes.yaml | Phase 6 | masters |
| hammer-cli_config.yml | Phase 8 | admin |
| auth.conf | Phase 8 | masters |
| node.rb | Phase 8 | masters |
| pdb-inventory.sh | Phase 9 | admin |
| post_script.sh | Phase 9 | inside `worker_setup-agent/files/` (delivered by Terraform) |

---

## Phase 0 — Base OS

**Run on: every infrastructure node** (puppetca1/2, puppetmaster1-3, admin). Replace `<name>`.
```bash
hostnamectl set-hostname <name>.puppetlab.com
sed -i '/127.0.1.1/d' /etc/hosts
sed -i 's/mirror.centos.org/vault.centos.org/g; s/^#\s*baseurl=/baseurl=/g; s/^mirrorlist=/#mirrorlist=/g' /etc/yum.repos.d/CentOS-Base.repo
yum clean all && yum makecache
yum install -y NetworkManager bind-utils socat policycoreutils-python rsync epel-release git
systemctl enable --now NetworkManager
yum install -y https://yum.puppet.com/puppet5-release-el-7.noarch.rpm
echo 'export PATH=/opt/puppetlabs/bin:/opt/puppetlabs/puppet/bin:$PATH' >> ~/.bashrc && source ~/.bashrc
```
Why: set the FQDN, point yum at the CentOS 7 archive, install base tools and the Puppet 5 repo.

**Run on: puppetca1, puppetca2, puppetmaster1-3** — `yum install -y puppet-agent puppetserver`
**Run on: admin** — `yum install -y puppet-agent`

**Validate — each node**
```bash
hostname -f; facter fqdn     # both: <name>.puppetlab.com
which puppet                 # /opt/puppetlabs/bin/puppet
```

---

## Phase 1 — Passwordless root login

Why: root on every infrastructure node, and you from your laptop, can log in to any node without a
password. The later phases copy files and run commands across nodes this way. Workers are created
in Phase 9; you log in to them with your AWS key.

**1. Laptop key on every node.** **Run on: laptop (Git Bash)**
```bash
[ -f ~/.ssh/id_rsa ] || ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ""
cat ~/.ssh/id_rsa.pub
ssh-keygen -y -f ~/.ssh/terraform2425.pem      # AWS key of account 1 (puppetmaster1-3, puppetca1)
ssh-keygen -y -f ~/.ssh/terraform2426.pem      # AWS key of account 2 (puppetca2, admin)
```
Keep these three public keys; they go into the file in step 3.

**2. Root key on each node.** **Run on: puppetmaster1, puppetmaster2, puppetmaster3, puppetca1, puppetca2, admin** (log in with your AWS key, then `sudo -i`)
```bash
ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ""
cat ~/.ssh/id_rsa.pub
```
Keep each printed key.

**3. Build one key file on admin.** **Run on: admin**
```bash
vi /root/.ssh/authorized_keys
```
Put in all the keys, one per line: the 6 node keys (step 2), your laptop key and the 2 AWS keys (step 1).
```bash
chmod 700 /root/.ssh && chmod 600 /root/.ssh/authorized_keys
grep -c "^ssh-rsa" /root/.ssh/authorized_keys      # 9
```

**4. Send the file to the other five nodes.** **Run on: laptop (Git Bash)**
```bash
scp root@<admin-public-ip>:/root/.ssh/authorized_keys ./authorized_keys
for ip in <puppetmaster1-ip> <puppetmaster2-ip> <puppetmaster3-ip> <puppetca1-ip>; do scp -i ~/.ssh/terraform2425.pem authorized_keys centos@$ip:/tmp/ && ssh -i ~/.ssh/terraform2425.pem centos@$ip "sudo cp /tmp/authorized_keys /root/.ssh/authorized_keys && sudo chmod 600 /root/.ssh/authorized_keys"; done
scp -i ~/.ssh/terraform2426.pem authorized_keys centos@<puppetca2-ip>:/tmp/ && ssh -i ~/.ssh/terraform2426.pem centos@<puppetca2-ip> "sudo cp /tmp/authorized_keys /root/.ssh/authorized_keys && sudo chmod 600 /root/.ssh/authorized_keys"
rm -f authorized_keys
```
You can also paste the file content into `/root/.ssh/authorized_keys` on each node by hand.

**Validate — laptop**
```bash
ssh root@<puppetmaster1-public-ip> hostname      # logs in as root, no password
```
**Validate — puppetmaster1, then repeat on admin**
```bash
for ip in 10.0.1.10 10.0.1.20 10.0.1.30 10.0.1.40 10.1.0.50 10.1.0.60; do ssh -o StrictHostKeyChecking=no root@$ip hostname; done   # 6 names, no password
```

---|---|
| puppetmaster1-3, puppetca1 | terraform2425.pem |
| puppetca2, admin | terraform2426.pem |

**1. Run on: every infrastructure node**
```bash
[ -f /root/.ssh/id_rsa ] || ssh-keygen -t rsa -b 4096 -f /root/.ssh/id_rsa -N ""
cat /root/.ssh/id_rsa.pub
```

**2. Run on: laptop (Git Bash)**
```bash
[ -f ~/.ssh/id_rsa ] || ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ""
cat ~/.ssh/id_rsa.pub
ssh-keygen -y -f ~/.ssh/terraform2425.pem
ssh-keygen -y -f ~/.ssh/terraform2426.pem
```

**3. Run on: admin** — put the 9 public keys (6 nodes + laptop + 2 AWS keys) in `/root/.ssh/authorized_keys`
```bash
vi /root/.ssh/authorized_keys
chmod 700 /root/.ssh && chmod 600 /root/.ssh/authorized_keys
```
**Validate** — `grep -c "^ssh-rsa" /root/.ssh/authorized_keys` → `9`

**4. Run on: laptop (Git Bash)** — copy the file to the other five nodes
```bash
scp root@<admin-public-ip>:/root/.ssh/authorized_keys ./authorized_keys
for ip in <puppetmaster1-ip> <puppetmaster2-ip> <puppetmaster3-ip> <puppetca1-ip>; do scp -i ~/.ssh/terraform2425.pem authorized_keys centos@$ip:/tmp/ && ssh -i ~/.ssh/terraform2425.pem centos@$ip "sudo cp /tmp/authorized_keys /root/.ssh/authorized_keys && sudo chmod 600 /root/.ssh/authorized_keys"; done
scp -i ~/.ssh/terraform2426.pem authorized_keys centos@<puppetca2-ip>:/tmp/ && ssh -i ~/.ssh/terraform2426.pem centos@<puppetca2-ip> "sudo cp /tmp/authorized_keys /root/.ssh/authorized_keys && sudo chmod 600 /root/.ssh/authorized_keys"
rm -f authorized_keys
```

**Validate — puppetmaster1**
```bash
for ip in 10.0.1.10 10.0.1.20 10.0.1.30 10.0.1.40 10.1.0.50 10.1.0.60; do ssh -o StrictHostKeyChecking=no root@$ip hostname; done   # 6 names, no password
```

---

## Phase 2 — Distribute the files bundle

**Run on: laptop** — `scp puppet-lab-files.tar.gz root@<puppetmaster1-public-ip>:/root/`

**Run on: puppetmaster1**
```bash
for ip in 10.0.1.20 10.0.1.30 10.0.1.40 10.1.0.50 10.1.0.60; do scp /root/puppet-lab-files.tar.gz root@$ip:/root/; done
for ip in 10.0.1.10 10.0.1.20 10.0.1.30 10.0.1.40 10.1.0.50 10.1.0.60; do ssh root@$ip "tar -xzf /root/puppet-lab-files.tar.gz -C /root && ls /root/lab-files | wc -l"; done
```
**Validate** — the six counts printed are identical.

---

## Phase 3 — Load balancers and DNS

puppetca1 is the primary (always active). puppetmaster1 is the secondary: its DNS starts only when
puppetca1's HAProxy is unreachable.

### 3a — HAProxy and dnsmasq
**Run on: puppetca1 and puppetmaster1**
```bash
yum install -y haproxy dnsmasq
for p in 8141 8142; do semanage port -d -t http_port_t -p tcp $p 2>/dev/null; semanage port -a -t http_port_t -p tcp $p; done
setsebool -P haproxy_connect_any 1
mkdir -p /var/run/haproxy && chown haproxy:haproxy /var/run/haproxy
echo "d /var/run/haproxy 0755 haproxy haproxy -" > /etc/tmpfiles.d/haproxy.conf
cp /root/lab-files/haproxy.cfg /etc/haproxy/haproxy.cfg
rm -f /var/run/haproxy/admin.sock
systemctl enable --now haproxy
cp /root/lab-files/static-hosts.conf /etc/dnsmasq.d/static-hosts.conf
cp /root/lab-files/lb-local.$(hostname -s).conf /etc/dnsmasq.d/lb-local.conf
systemctl enable dnsmasq
```
Why: HAProxy spreads agents over the masters and fails the CA over; dnsmasq serves the lab names.
`static-hosts.conf` (shared) lists every host as `FQDN,short,IP`; `lb-local.conf` (per LB) points
the two service names at that LB itself.

**Run on: puppetca1** — `systemctl start dnsmasq`
**Run on: puppetmaster1** — `systemctl stop dnsmasq`

**Validate**
```bash
systemctl is-active haproxy dnsmasq                                 # puppetca1: active active
systemctl is-active haproxy; systemctl is-active dnsmasq            # puppetmaster1: active, inactive
dig +short puppetmaster.puppetlab.com @10.0.1.40                    # any node: 10.0.1.40
```

### 3b — DNS guard on the secondary
**Run on: puppetmaster1**
```bash
cp /root/lab-files/local-dns-guard.sh /usr/local/bin/ && chmod +x /usr/local/bin/local-dns-guard.sh
cp /root/lab-files/local-dns-guard.service /root/lab-files/local-dns-guard.timer /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now local-dns-guard.timer
```
Why: every 3 seconds, start dnsmasq here only if puppetca1's HAProxy is down.

**Validate — failover test**
```bash
systemctl stop haproxy               # puppetca1: simulate primary failure
systemctl is-active dnsmasq          # puppetmaster1 (wait 5 s): active
systemctl start haproxy              # puppetca1: restore
systemctl is-active dnsmasq          # puppetmaster1 (wait 5 s): inactive
```

### 3c — Keep both LBs' config in sync
**Run on: puppetca1 and puppetmaster1**
```bash
cp /root/lab-files/lb-config-sync.sh /root/lab-files/lb-config-watch.sh /usr/local/bin/ && chmod +x /usr/local/bin/lb-config-*.sh
cp /root/lab-files/lb-config-watch.service /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now lb-config-watch.service
```
Why: a change to `haproxy.cfg` or `static-hosts.conf` on one LB is copied to the other.
`lb-local.conf` is never synced.

**Validate**
```bash
echo "# sync-test" >> /etc/dnsmasq.d/static-hosts.conf      # puppetca1
grep sync-test /etc/dnsmasq.d/static-hosts.conf             # puppetmaster1 (after 5 s): line present
sed -i '/sync-test/d' /etc/dnsmasq.d/static-hosts.conf      # puppetca1: remove
```

### 3d — Point every node at the LB DNS pair
**Run on: every infrastructure node**
```bash
nmcli con mod "System eth0" ipv4.dns "10.0.1.40 10.0.1.10"
nmcli con mod "System eth0" ipv4.ignore-auto-dns yes
nmcli con mod "System eth0" ipv4.dns-options "timeout:1 attempts:2 single-request-reopen"
nmcli con mod "System eth0" ipv4.dns-search ""
nmcli device reapply eth0
nmcli con mod "System eth0" ipv4.dns-search "puppetlab.com"
nmcli device reapply eth0
```
Why: primary DNS first, failover second, short timeout. The two-step search change makes
NetworkManager apply it.

**Validate — each node**
```bash
grep -E "nameserver|options|search" /etc/resolv.conf     # 10.0.1.40 first, options line, search puppetlab.com
getent hosts puppetca2 admin puppetmaster3               # internal names resolve
ping -c1 google.com >/dev/null && echo "internet ok"
```

---

## Phase 4 — Certificate Authority pair

### 4a — CA on puppetca1
**Run on: puppetca1**
```bash
rm -rf /etc/puppetlabs/puppet/ssl && mkdir -p /etc/puppetlabs/puppet/ssl && chown puppet:puppet /etc/puppetlabs/puppet/ssl
cat > /etc/puppetlabs/puppet/puppet.conf <<EOF
[main]
certname = puppetca.puppetlab.com
server = puppetmaster.puppetlab.com
masterport = 8142
ca_server = puppetca.puppetlab.com
ca_port = 8141
dns_alt_names = puppetca.puppetlab.com,puppetca1,puppetca1.local,10.0.1.40
EOF
sed -i 's/# allow-subject-alt-names: false/allow-subject-alt-names: true/' /etc/puppetlabs/puppetserver/conf.d/ca.conf
cp /root/lab-files/autosign.conf /etc/puppetlabs/puppet/autosign.conf
chown root:puppet /etc/puppetlabs/puppet/autosign.conf && chmod 750 /etc/puppetlabs/puppet/autosign.conf
systemctl enable --now puppetserver
```
Why: both CA nodes share the identity `puppetca.puppetlab.com`. `autosign.conf` is a policy script
that signs `*.puppetlab.com`, `puppetmasterN` and `workerN`; `allow-subject-alt-names` lets
masters request certificates with extra names.

**Validate**
```bash
curl -sk https://localhost:8140/status/v1/simple; echo     # running
ls /etc/puppetlabs/puppet/ssl/ca/ca_crt.pem                # CA certificate exists
```

### 4b — puppetca2 as a copy
**Run on: puppetca1**
```bash
tar -czf /root/ca.tar.gz -C /etc/puppetlabs/puppet ssl && scp /root/ca.tar.gz /etc/puppetlabs/puppet/autosign.conf root@10.1.0.50:/root/
```
**Run on: puppetca2**
```bash
rm -rf /etc/puppetlabs/puppet/ssl && tar -xzf /root/ca.tar.gz -C /etc/puppetlabs/puppet && chown -R puppet:puppet /etc/puppetlabs/puppet/ssl
cat > /etc/puppetlabs/puppet/puppet.conf <<EOF
[main]
certname = puppetca.puppetlab.com
server = puppetmaster.puppetlab.com
masterport = 8142
ca_server = puppetca.puppetlab.com
ca_port = 8141
dns_alt_names = puppetca.puppetlab.com,puppetca2,puppetca2.local,10.1.0.50
EOF
sed -i 's/# allow-subject-alt-names: false/allow-subject-alt-names: true/' /etc/puppetlabs/puppetserver/conf.d/ca.conf
cp /root/autosign.conf /etc/puppetlabs/puppet/ && chown root:puppet /etc/puppetlabs/puppet/autosign.conf && chmod 750 /etc/puppetlabs/puppet/autosign.conf
systemctl enable --now puppetserver
```
**Validate** — `curl -sk https://localhost:8140/status/v1/simple` → `running`

### 4c — Continuous CA sync
**Run on: puppetca1 and puppetca2**
```bash
cp /root/lab-files/ca-sync.sh /root/lab-files/ca-watch.sh /usr/local/bin/ && chmod +x /usr/local/bin/ca-*.sh
cp /root/lab-files/ca-watch.service /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now ca-watch.service
```
Why: every newly signed or revoked certificate is copied to the other CA within seconds.

**Validate — autosign and sync**
```bash
puppet agent -t --certname autosign-test.puppetlab.com --dns_alt_names "" --waitforcert 0   # puppetca1
ls /etc/puppetlabs/puppet/ssl/ca/signed/ | grep autosign-test                               # puppetca1 and puppetca2: present
puppet cert clean autosign-test.puppetlab.com                                               # puppetca1: remove (gone on both)
```
**Validate — CA failover**
```bash
systemctl stop puppetserver                                                    # puppetca1
curl -sk https://puppetca.puppetlab.com:8141/status/v1/simple; echo            # any node: running (served by puppetca2)
systemctl start puppetserver                                                   # puppetca1
```

---

## Phase 5 — admin: fleet certificate, Foreman, PuppetDB

### 5a — Join the fleet CA
**Run on: admin**
```bash
rm -rf /etc/puppetlabs/puppet/ssl && mkdir -p /etc/puppetlabs/puppet/ssl
cat > /etc/puppetlabs/puppet/puppet.conf <<EOF
[main]
certname = admin.puppetlab.com
server = puppetmaster.puppetlab.com
masterport = 8142
ca_server = puppetca.puppetlab.com
ca_port = 8141
certificate_revocation = false
dns_alt_names = admin.puppetlab.com,admin,10.1.0.60
EOF
puppet agent -t --waitforcert 0
scp root@10.0.1.40:/etc/puppetlabs/puppet/ssl/ca/ca_crl.pem /etc/puppetlabs/puppet/ssl/crl.pem
```
Why: Foreman and PuppetDB use this certificate, so it must come from the fleet CA.

**Validate** — `openssl x509 -in /etc/puppetlabs/puppet/ssl/certs/admin.puppetlab.com.pem -noout -issuer` → `Puppet CA: puppetca.puppetlab.com`

### 5b — Foreman 3.1
Foreman 3.1 needs a Puppet 7 agent on its own host.

**Run on: admin**
```bash
yum remove -y puppet-agent && rm -f /etc/yum.repos.d/puppet5*.repo
yum install -y https://yum.puppet.com/puppet7-release-el-7.noarch.rpm
yum -y localinstall https://yum.theforeman.org/releases/3.1/el7/x86_64/foreman-release.rpm
yum -y install centos-release-scl-rh
for f in /etc/yum.repos.d/CentOS-SCLo*.repo; do sed -i 's/mirror.centos.org/vault.centos.org/g; s/^#\s*baseurl=/baseurl=/g; s/^mirrorlist=/#mirrorlist=/g' "$f"; done
yum clean all && yum -y install foreman-installer
foreman-installer --enable-foreman --enable-foreman-plugin-puppet --foreman-proxy-puppet=false --foreman-proxy-puppetca=false --puppet-server=false --puppet-server-ca=false --puppet-puppetmaster=puppetmaster.puppetlab.com --puppet-ca-server=puppetca.puppetlab.com --puppet-port=8142 --puppet-ca-port=8141 --foreman-proxy-ssl-port=8444
usermod -a -G puppet apache && chmod 640 /etc/puppetlabs/puppet/ssl/private_keys/admin.puppetlab.com.pem
```
Why: Foreman is the ENC (it decides each node's role). The proxy listens on 8444. Save the admin
password printed at the end.

**Validate**
```bash
systemctl is-active foreman httpd foreman-proxy           # active x3
curl -sk -o /dev/null -w "%{http_code}\n" https://localhost/users/login   # 200
```
Browser (laptop hosts file has `<admin-ip> admin.puppetlab.com`): `https://admin.puppetlab.com`

### 5c — PuppetDB
**Run on: admin**
```bash
sudo -u postgres psql -c "CREATE ROLE puppetdb WITH LOGIN PASSWORD 'puppetdb';"
sudo -u postgres psql -c "CREATE DATABASE puppetdb OWNER puppetdb;"
yum install -y puppetdb puppetdb-termini python3
cp /root/lab-files/database.ini /root/lab-files/jetty.ini /etc/puppetlabs/puppetdb/conf.d/
usermod -a -G puppet puppetdb
systemctl enable --now puppetdb
```
Why: PuppetDB stores every node's facts, catalogs and reports; it shares Foreman's PostgreSQL.

**Validate**
```bash
curl -sk https://localhost:8081/pdb/meta/v1/version; echo     # {"version":"7.20.1"}
```
Browser: `https://admin.puppetlab.com:8081/pdb/dashboard/index.html`

---

## Phase 6 — Compile masters

### 6a — Bootstrap each master
**Run on: puppetmaster1, then puppetmaster2, then puppetmaster3**
```bash
N=$(hostname -s); IP=$(hostname -I | awk '{print $1}')
sed -i -e 's|^puppetlabs.services.ca.certificate-authority-service/certificate-authority-service|#&|' -e 's|^#puppetlabs.services.ca.certificate-authority-disabled-service/certificate-authority-disabled-service|puppetlabs.services.ca.certificate-authority-disabled-service/certificate-authority-disabled-service|' /etc/puppetlabs/puppetserver/services.d/ca.cfg
rm -rf /etc/puppetlabs/puppet/ssl && mkdir -p /etc/puppetlabs/puppet/ssl && chown puppet:puppet /etc/puppetlabs/puppet/ssl
cat > /etc/puppetlabs/puppet/puppet.conf <<EOF
[main]
certname = $N
server = puppetmaster.puppetlab.com
masterport = 8142
ca_server = puppetca.puppetlab.com
ca_port = 8141
certificate_revocation = false
dns_alt_names = $N,$N.local,$IP,puppetmaster.puppetlab.com
EOF
puppet agent -t --waitforcert 0
scp root@10.0.1.40:/etc/puppetlabs/puppet/ssl/ca/ca_crl.pem /etc/puppetlabs/puppet/ssl/crl.pem
sed -i "/ssl-port: 8140/a\    ssl-cert: /etc/puppetlabs/puppet/ssl/certs/$N.pem\n    ssl-key: /etc/puppetlabs/puppet/ssl/private_keys/$N.pem\n    ssl-ca-cert: /etc/puppetlabs/puppet/ssl/certs/ca.pem\n    ssl-crl-path: /etc/puppetlabs/puppet/ssl/crl.pem" /etc/puppetlabs/puppetserver/conf.d/webserver.conf
systemctl enable --now puppetserver
```
Why: the local CA is switched off (puppetca1/2 are the only CA); each master gets a fleet
certificate that is also valid for `puppetmaster.puppetlab.com`.

**Validate — each master**
```bash
ls /etc/puppetlabs/puppet/ssl/ca 2>&1 | head -1                # "No such file": no local CA
curl -sk https://localhost:8140/status/v1/simple; echo          # running
```
**Validate — puppetca1** (all three masters UP behind HAProxy)
```bash
echo "show stat" | socat stdio /var/run/haproxy/admin.sock | cut -d, -f1,2,18 | grep -E "puppetmaster[123]"
```

### 6b — Send data to PuppetDB
**Run on: each master**
```bash
yum install -y puppetdb-termini
cat >> /etc/puppetlabs/puppet/puppet.conf <<EOF

[master]
storeconfigs = true
storeconfigs_backend = puppetdb
reports = puppetdb
EOF
cp /root/lab-files/puppetdb.conf /root/lab-files/routes.yaml /etc/puppetlabs/puppet/
systemctl restart puppetserver
```
Why: masters send facts, catalogs and reports to PuppetDB. Server-only settings live in `[master]`
so the node's own agent still reads facts from Facter. `puppetdb.conf` uses the hostname
`admin.puppetlab.com` (the certificate has no IP identity).

**Validate**
```bash
puppet agent -t                                                                    # each master: clean run via the LB
curl -s http://localhost:8080/pdb/query/v4/nodes | python3 -m json.tool | grep certname   # admin: masters listed
```

---

## Phase 7 — Code delivery with r10k

### 7a — r10k on every master
**Run on: each master**
```bash
for g in "cri 2.15.1" "multipart-post 2.1.1" "puppet_forge 2.2.8" "colored 1.2" "log4r 1.1.10" "semantic_puppet 1.0.4" "minitar 0.9" "r10k 3.2.3"; do set -- $g; /opt/puppetlabs/puppet/bin/gem install $1 -v $2 --no-document; done
mkdir -p /etc/puppetlabs/r10k
cat > /etc/puppetlabs/r10k/r10k.yaml <<EOF
cachedir: /opt/puppetlabs/r10k/cache
sources:
  main:
    remote: 'https://github.com/<github-user>/puppet-control-repo.git'
    basedir: '/etc/puppetlabs/code/environments'
EOF
(crontab -l 2>/dev/null | grep -v r10k; echo "* * * * * flock -n /var/run/r10k.lock /opt/puppetlabs/puppet/bin/r10k deploy environment -p -v >> /var/log/r10k-deploy.log 2>&1") | crontab -
```
Why: each master deploys every Git branch as a Puppet environment every minute; `flock` stops two
deploys overlapping.

### 7b — Repository layout
- **puppet-modules:** one folder per module (`nginx`, `ntp`, `vault`, `puppet_agent5`; `puppet_agent7` and
  `puppet_master7` are added for Phase 11), underscores only, each with a `metadata.json` that includes `source`.
- **puppet-control-repo:**
  - `environment.conf`: `modulepath = modules/internal:site:modules:$basemodulepath`
  - `Puppetfile`: stdlib 6.6.0, concat 6.4.0, apt 7.6.0, translate 2.2.0, `internal` (tag), timezone, resolve_conf
  - `site/profile`: `base` (ntp, resolve_conf, timezone), `webserver` (nginx after EPEL), `vault_server` (vault)
  - `site/role`: `infra` / `webserver` / `admin` = base + app profile + `puppet_agent5` (Phase 11 changes it to `puppet_agent7`); `puppetserver`, `puppetca` = `puppet_master7` (added in Phase 11)
  - `hiera.yaml`: `hostgroups/%{hostgroup}.yaml` → `common.yaml`
  - `data/common.yaml`: `puppet_agent5::*` settings, timezone, resolve_conf (`10.0.1.40`, `10.0.1.10`, options)
  - `data/hostgroups/infra.yaml`: vault values · `webserver.yaml`: nginx values

### 7c — Deploy now
**Run on: puppetmaster1**
```bash
for h in puppetmaster1 puppetmaster2 puppetmaster3; do ssh root@$h "flock /var/run/r10k.lock /opt/puppetlabs/puppet/bin/r10k deploy environment -p"; done
```
**Validate**
```bash
ls /etc/puppetlabs/code/environments/                                       # dev production
puppet module list --environment production 2>&1 | grep -i -c error         # 0
for h in puppetmaster1 puppetmaster2 puppetmaster3; do ssh root@$h "grep signature /etc/puppetlabs/code/environments/production/.r10k-deploy.json"; done   # same commit x3
```

---

## Phase 8 — Foreman as the ENC

### 8a — hammer CLI
**Run on: admin**
```bash
yum install -y tfm-rubygem-hammer_cli_foreman
mkdir -p /etc/hammer && cp /root/lab-files/hammer-cli_config.yml /etc/hammer/cli_config.yml   # set the admin password inside
```
**Validate** — `hammer host list` shows `admin.puppetlab.com`

### 8b — API token
Create it in Foreman: Administer → Users → admin → Personal Access Tokens. It is used as the
Basic-auth password (`curl -u admin:<token>`).

**Run on: puppetmaster1** (save it for node.rb)
```bash
vi /etc/puppetlabs/foreman_token          # paste the token, one line
for h in puppetmaster1 puppetmaster2 puppetmaster3; do scp /etc/puppetlabs/foreman_token root@$h:/etc/puppetlabs/foreman_token; ssh root@$h "chown root:puppet /etc/puppetlabs/foreman_token; chmod 640 /etc/puppetlabs/foreman_token"; done
```
Why: `root:puppet 640` lets the puppetserver process (user `puppet`) read it.

**Validate** — `curl -sk -u "admin:$(cat /etc/puppetlabs/foreman_token)" https://admin.puppetlab.com/api/status` → JSON with `"result":"ok"`

### 8c — Let Foreman read classes from the masters
**Run on: puppetmaster1**
```bash
for h in puppetmaster1 puppetmaster2 puppetmaster3; do scp /root/lab-files/auth.conf root@$h:/etc/puppetlabs/puppetserver/conf.d/auth.conf; ssh root@$h "systemctl restart puppetserver"; done
```
**Run on: admin**
```bash
foreman-installer --puppet-port=8142 --puppet-ca-port=8141 --foreman-proxy-puppet=true --foreman-proxy-puppet-url=https://puppetmaster.puppetlab.com:8142
```
Why: `auth.conf` allows the class-listing API; the proxy reads class lists from the masters via
the LB (no Puppet code is stored on admin).

**Validate — admin**
```bash
hammer proxy info --id 1 | grep -A4 Features                       # Puppet listed
grep -E "masterport|ca_port" /etc/puppetlabs/puppet/puppet.conf     # 8142, 8141
```

### 8d — Hostgroups with one role each
**Run on: admin**
```bash
hammer proxy import-classes --id 1
for hg in infra webserver admin; do hammer hostgroup create --name "$hg" --environment production --organization "Default Organization" --location "Default Location"; done
hammer hostgroup update --name infra --puppet-classes role::infra
hammer hostgroup update --name webserver --puppet-classes role::webserver
hammer hostgroup update --name admin --puppet-classes role::admin
```
Why: a node only needs its hostgroup; the role decides everything else. Re-run `import-classes`
after any code change that adds or removes a class.

**Validate**
```bash
for hg in infra webserver admin; do echo "$hg: $(hammer hostgroup info --name $hg | grep -A1 Puppetclasses | tail -1)"; done
```

### 8e — node.rb on every master
**Run on: puppetmaster1**
```bash
for h in puppetmaster1 puppetmaster2 puppetmaster3; do scp /root/lab-files/node.rb root@$h:/etc/puppetlabs/puppet/node.rb; ssh root@$h "chmod 755 /etc/puppetlabs/puppet/node.rb; grep -q '^node_terminus' /etc/puppetlabs/puppet/puppet.conf || sed -i '/^\[master\]/a node_terminus = exec\nexternal_nodes = /etc/puppetlabs/puppet/node.rb' /etc/puppetlabs/puppet/puppet.conf; systemctl restart puppetserver"; done
```
Why: `node.rb` asks Foreman (`/api/hosts/<name>/enc`) for the node's classes, parameters and
environment; an unknown host gets no classes.

**Validate**
```bash
for h in puppetmaster1 puppetmaster2 puppetmaster3; do ssh root@$h "sudo -u puppet /etc/puppetlabs/puppet/node.rb admin.puppetlab.com | head -2"; done   # YAML x3
```

---

## Phase 9 — Zero-touch workers

### 9a — Terraform layout
| Folder | Manages |
|---|---|
| `puppetmaster/` | puppetmaster1-3, puppetca1 |
| `worker_setup/` | VPC 10.1.0.0/16, subnet, security group, admin, puppetca2 |
| `worker_setup-agent/` | worker security group, worker IAM role, worker1-3 |

`worker_setup-agent/terraform.tfvars` holds the workers map
(`worker1 = infra`, `worker2 = webserver`, `worker3 = admin`) and `trusted_cidrs` (your public IP).
Each worker gets the tags `Hostname` and `Hostgroup`; `user_data` delivers `post_script.sh`.

### 9b — Store the Foreman token in SSM
AWS Console (us-east-1) → Systems Manager → Parameter Store → Create parameter:
name `/puppetlab/foreman/api_token`, type **SecureString**, KMS key `alias/aws/ssm`, value = token.

Why: the token is never in Terraform code, state or `user_data`; workers may only read this one
parameter (IAM), keep it in memory and never write it to disk.

**Validate — laptop (Git Bash)**
```bash
MSYS_NO_PATHCONV=1 aws ssm get-parameter --profile <aws-profile> --region us-east-1 --name /puppetlab/foreman/api_token --with-decryption --query Parameter.Value --output text | wc -c    # a number, not an error
```

### 9c — What `post_script.sh` does on first boot
1. Reads its `Hostname` and `Hostgroup` tags from instance metadata.
2. Sets the FQDN hostname and `/etc/hosts` (`<ip> <fqdn> <short>`, nothing on 127.x), and tells
   cloud-init to keep both.
3. Fixes yum repos, installs NetworkManager, EPEL, AWS CLI.
4. Points DNS at the LB pair with resolver options.
5. Installs puppet-agent.
6. Reads the token from SSM and registers the host in its Foreman hostgroup.
7. Requests its certificate (autosigned) and runs Puppet.

From then on `puppet_agent5` (in every worker role) owns `puppet.conf`, base packages, the custom fact and
the `puppet` service.

### 9d — Create the workers
**Run on: laptop**, in `worker_setup-agent`
```bash
terraform init
terraform plan --out=tfplan
terraform apply tfplan
terraform output worker_public_ips
```
**Validate — each worker (about 5 minutes after apply)**
```bash
tail -5 /var/log/post_script.log           # ... registered in <hostgroup> ... complete
hostname; hostname -f                      # workerN.puppetlab.com x2
grep worker /etc/hosts                     # <private-ip> workerN.puppetlab.com workerN
facter intended_hostgroup                  # infra / webserver / admin
ls /etc/puppetlabs/foreman_token 2>&1      # "No such file": token never stored
systemctl is-active puppet                 # active
```
**Validate — admin**
```bash
hammer host list --fields Name,"Host Group"     # worker1 infra, worker2 webserver, worker3 admin
```

### 9e — Laptop hosts file
Open Git Bash with **Run as administrator**:
```bash
notepad /c/Windows/System32/drivers/etc/hosts
```
Add the current public IPs and save:
```
<admin-ip>    admin.puppetlab.com
<worker1-ip>  worker1.puppetlab.com
<worker2-ip>  worker2.puppetlab.com
<worker3-ip>  worker3.puppetlab.com
```
```bash
MSYS_NO_PATHCONV=1 ipconfig /flushdns
ping -n 1 worker2.puppetlab.com         # resolves to <worker2-ip>
```

### 9f — Role checks
**worker1 (infra / vault)**
```bash
cat /opt/puppetlabs/puppet/cache/state/classes.txt                 # role::infra, profile::vault_server, vault
systemctl is-active vault; ss -tlnp | grep 8200
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8200/v1/sys/health   # 200, 501 or 503
```
Browser: `http://worker1.puppetlab.com:8200/ui`

**worker2 (webserver / nginx)**
```bash
cat /opt/puppetlabs/puppet/cache/state/classes.txt                 # role::webserver, profile::webserver, nginx
systemctl is-active nginx; nginx -t
curl -s -o /dev/null -w "%{http_code}\n" http://localhost/          # 200
```
Browser: `http://worker2.puppetlab.com/`

**worker3 (admin / base only)**
```bash
cat /opt/puppetlabs/puppet/cache/state/classes.txt                 # role::admin, profile::base, ntp, resolve_conf, timezone
systemctl is-active ntpd; head -3 /etc/resolv.conf                  # active, "Managed by Puppet"
rpm -q nginx vault                                                  # both not installed
```

**Every worker — no drift, self-healing**
```bash
puppet agent -t --noop | grep -E "Would have|Applied catalog"        # only "Applied catalog"
systemctl stop nginx; puppet agent -t | grep -i "Service\[nginx\]"   # worker2: back to running
```

### 9g — Fleet view in PuppetDB
**Run on: admin**
```bash
cp /root/lab-files/pdb-inventory.sh /usr/local/bin/ && chmod +x /usr/local/bin/pdb-inventory.sh
pdb-inventory.sh                    # node, OS, release, kernel, hostgroup, last boot, last report
curl -s -G http://localhost:8080/pdb/query/v4/resources --data-urlencode 'query=["and",["=","type","Service"],["~","title","^(nginx|vault|ntpd)$"]]' | python3 -c 'import json,sys; [print(r["certname"], r["title"]) for r in json.load(sys.stdin)]' | sort
```
Expected: nginx only on worker2, vault only on worker1, ntpd on all three.

**PQL examples — admin**
```bash
PQ() { curl -s -G http://localhost:8080/pdb/query/v4 --data-urlencode "query=$1" | python3 -m json.tool; }
PQ 'inventory[certname, facts.os.release.full, facts.kernelrelease] { }'
PQ 'inventory[certname] { facts.intended_hostgroup = "infra" }'
PQ 'reports[certname, status, end_time] { latest_report? = true and status = "failed" }'
```

---

## Phase 10 — Decommission and re-provision workers

### 10a — Decommission
```bash
terraform destroy                                                                     # laptop, in worker_setup-agent
for w in worker1 worker2 worker3; do puppetserver ca clean --certname $w.puppetlab.com; done    # puppetca1 (synced to puppetca2)
for w in worker1 worker2 worker3; do puppet node deactivate $w.puppetlab.com; done    # puppetmaster1
for w in worker1 worker2 worker3; do hammer host delete --name $w.puppetlab.com; done # admin
```
Why: a rebuilt node gets a new key; the old certificate, PuppetDB entry and Foreman host must go.
(On Puppet 5 the CA command is `puppet cert clean <name>`.)

**Validate**
```bash
ls /etc/puppetlabs/puppet/ssl/ca/signed/ | grep worker     # puppetca1 and puppetca2: nothing
hammer host list | grep worker                             # admin: nothing
```

### 10b — Re-provision
```bash
terraform plan --out=tfplan && terraform apply tfplan     # laptop, in worker_setup-agent
```
Then repeat **9d**, **9e**, **9f** and **9g**. Adding a worker = one line in the workers map.

---

## Phase 11 — Upgrade Puppet 5 → 7

**Order:** CA first, then masters one at a time, then agents. An agent may never be newer than
its server.

**Modules:**
- `puppet_master7` (roles `puppetserver`, `puppetca`): manages `puppet.conf` for the installed
  version; with `manage_packages: true` it replaces Puppet 5 with 7 in the last run stage, then
  restarts puppetserver. A node already on 7 is not touched.
- `puppet_agent7` (worker roles, replaces `puppet_agent5`): if Puppet 5 is installed it replaces it
  with 7 in the last run stage and restarts the agent; certificates stay. A node already on 7 gets
  no package action.

**Versions used:** puppet-agent `7.34.0-1.el7`, puppetserver `7.17.3-1.el7`,
puppetdb-termini `7.20.1-1.el7`, r10k `3.16.0`.

### 11a — Hostgroups for the server tier
**Run on: admin**
```bash
hammer proxy import-classes --id 1
for hg in puppetserver puppetca; do hammer hostgroup create --name "$hg" --environment production --organization "Default Organization" --location "Default Location"; done
hammer hostgroup update --name puppetserver --puppet-classes role::puppetserver
hammer hostgroup update --name puppetca --puppet-classes role::puppetca
for n in puppetmaster1 puppetmaster2 puppetmaster3; do hammer host create --name $n --hostgroup puppetserver --managed false --organization "Default Organization" --location "Default Location"; done
hammer host create --name puppetca.puppetlab.com --hostgroup puppetca --managed false --organization "Default Organization" --location "Default Location"
```
Why: the five servers are a fixed tier, registered once.

**Validate** — `hammer host list --fields Name,"Host Group"` shows the masters in `puppetserver` and `puppetca.puppetlab.com` in `puppetca`.

### 11b — Prechecks
**Run on: puppetmaster1**
```bash
for h in puppetca1 puppetca2 puppetmaster1 puppetmaster2 puppetmaster3; do echo "== $h"; ssh root@$h 'puppet --version; puppetserver --version | head -1; pgrep -f "puppet agent" >/dev/null && echo "agent daemon RUNNING" || echo "no agent daemon"; df -h /opt | tail -1; curl -s -o /dev/null -w "puppet7 repo %{http_code}\n" https://yum.puppet.com/puppet7/el/7/x86_64/repodata/repomd.xml'; done
```
Expected: 5.5.22 / 5.3.16, `no agent daemon` (you trigger each upgrade by hand), ≥ 2 GB free, repo `200`.

**Forge modules support Puppet 7 — puppetmaster1**
```bash
cd /etc/puppetlabs/code/environments/production
for m in modules/*/metadata.json; do python -c "import json; d=json.load(open('$m')); r=[x['version_requirement'] for x in d.get('requirements',[]) if x['name']=='puppet']; print('%-28s %s' % (d['name'], r[0] if r else '-'))"; done
```
Every range must include 7.

**Validate mode — the new modules change nothing yet** (`manage_packages: false`)
```bash
for h in puppetca1 puppetca2 puppetmaster1 puppetmaster2 puppetmaster3; do echo "== $h"; ssh root@$h 'puppet agent -t --noop 2>&1 | grep -E "Would have|Error|Applied catalog"'; done   # only "Applied catalog"
```

### 11c — Backups
1. AWS console: EBS snapshots of puppetca1, puppetca2, puppetmaster1-3 (wait for `completed`).
2. **Run on: puppetmaster1**
```bash
for h in puppetca1 puppetca2 puppetmaster1 puppetmaster2 puppetmaster3; do ssh root@$h 'tar -czf /root/pre-p7-etc-puppetlabs.tar.gz /etc/puppetlabs && rpm -qa | grep -E "^puppet" > /root/pre-p7-packages.txt && ls -lh /root/pre-p7-etc-puppetlabs.tar.gz'; done
```
3. **Run on: admin** — `sudo -u postgres pg_dump puppetdb | gzip > /root/puppetdb-pre-p7.sql.gz`

**Rollback (any server, use as soon as a check fails)**
1. Set `puppet_master7::manage_packages: false` in that hostgroup's Hiera file (dev → production).
2. **Run on: the failed node**
```bash
systemctl stop puppetserver
yum -y --enablerepo=puppet5 --disablerepo=puppet7 downgrade puppet-agent-5.5.22 puppetserver-5.3.16
tar -xzf /root/pre-p7-etc-puppetlabs.tar.gz -C /
systemctl start puppetserver && sleep 40 && curl -sk https://localhost:8140/status/v1/simple
```
3. Still broken → EC2 → Replace root volume → from the snapshot.

### 11d — Upgrade the CA (puppetca2 first)
**Run on: puppetca1 and puppetca2** — `systemctl stop ca-watch`
Why: pause syncing while the two CAs run different versions.

**Run on: laptop**, in `puppet-control-repo` (dev → production, then r10k deploy)
```bash
cat > data/hostgroups/puppetca.yaml <<'EOF'
puppet_master7::manage_packages: true
puppet_master7::agent_version: '7.34.0-1.el7'
puppet_master7::puppetserver_version: '7.17.3-1.el7'
EOF
```

**Run on: puppetca2** — `puppet agent -t`
**Validate — puppetca2**
```bash
puppet --version; puppetserver --version | head -1                  # 7.34.0, 7.17.3
sleep 40; curl -sk https://localhost:8140/status/v1/simple; echo   # running
puppet config print cadir --section server                          # /etc/puppetlabs/puppet/ssl/ca
puppetserver ca list --all | head -3                                # existing certificates
puppet agent -t 2>&1 | grep -E "Error|Applied catalog"              # Applied catalog
```
**Validate — puppetca2 can sign alone**
```bash
systemctl stop puppetserver                                                              # puppetca1
puppet agent -t --certname p7-catest.puppetlab.com --waitforcert 0 --noop 2>&1 | head -3 # puppetmaster1
puppetserver ca list --all | grep p7-catest && puppetserver ca clean --certname p7-catest.puppetlab.com   # puppetca2
systemctl start puppetserver                                                             # puppetca1
```

**Run on: puppetca1** — `puppet agent -t`, then the same puppetca2 validate block on puppetca1.
**Run on: puppetca1 and puppetca2** — `systemctl start ca-watch; systemctl is-active ca-watch` → active

### 11e — puppetmaster3: canary and Puppet 7 compatibility check
**Take it out of traffic — Run on: puppetca1 and puppetmaster1**
```bash
echo "disable server puppetmaster_back/puppetmaster3" | socat stdio /var/run/haproxy/admin.sock
```
**Validate** — `echo "show stat" | socat stdio /var/run/haproxy/admin.sock | grep puppetmaster3 | cut -d, -f1,2,18` → `MAINT`

**Run on: laptop**, in `puppet-control-repo` (dev → production, then r10k deploy)
```bash
cat > data/hostgroups/puppetserver.yaml <<'EOF'
puppet_master7::manage_packages: true
puppet_master7::agent_version: '7.34.0-1.el7'
puppet_master7::puppetserver_version: '7.17.3-1.el7'
puppet_master7::termini_version: '7.20.1-1.el7'
puppet_master7::r10k_version: '3.16.0'
EOF
```

**Run on: puppetmaster3** — `puppet agent -t`
**Validate — puppetmaster3**
```bash
puppet --version; puppetserver --version | head -1; rpm -q puppetdb-termini   # 7.34.0, 7.17.3, 7.20.1
sleep 40; curl -sk https://localhost:8140/status/v1/simple; echo              # running
/opt/puppetlabs/puppet/bin/r10k deploy environment -p && echo "r10k ok"
sudo -u puppet /etc/puppetlabs/puppet/node.rb worker2.puppetlab.com | grep -A1 classes   # role::webserver
puppet agent -t 2>&1 | grep -E "Error|Applied catalog"                         # Applied catalog
grep -n "^\[" /etc/puppetlabs/puppet/puppet.conf                               # [main], [server]
```

**Compatibility check — compile every node on Puppet 7 and compare with Puppet 5**
**Run on: worker1, worker2, worker3, puppetca1, puppetca2**
```bash
for m in puppetmaster1 puppetmaster3; do echo "== compiled on $m"; puppet agent -t --noop --summarize --server $m --masterport 8140 2>&1 | grep -E "Would have|Error|Total:|Applied catalog"; done
```
Pass: both blocks `Applied catalog`, no `Would have`, the same `Total:` resource count.

**Run on: puppetmaster3** — no deprecation warnings from your code:
```bash
grep -i -E "deprecat|warn" /var/log/puppetlabs/puppetserver/puppetserver.log | grep -v -E "JDK|Dropsonde|node parameter" | tail -5
```

**Java 11 for puppetserver — Run on: puppetmaster3** (still out of traffic)
```bash
yum install -y java-11-openjdk-headless
sed -i 's|^JAVA_BIN=.*|JAVA_BIN="/usr/lib/jvm/jre-11/bin/java"|' /etc/sysconfig/puppetserver
grep -q dropsonde /etc/puppetlabs/puppetserver/conf.d/puppetserver.conf || printf '\ndropsonde: {\n    enabled: false\n}\n' >> /etc/puppetlabs/puppetserver/conf.d/puppetserver.conf
systemctl restart puppetserver && sleep 45
```
Why: puppetserver 7 recommends Java 11; module usage reporting is switched off.

**Validate**
```bash
curl -sk https://localhost:8140/status/v1/simple; echo     # running
ps -o args= -C java | grep -c jre-11                        # 1
```

**Put it back into traffic — Run on: puppetca1 and puppetmaster1**
```bash
echo "enable server puppetmaster_back/puppetmaster3" | socat stdio /var/run/haproxy/admin.sock
```
**Validate** — `echo "show stat" | socat stdio /var/run/haproxy/admin.sock | grep puppetmaster3 | cut -d, -f1,2,18` → `UP`

### 11f — puppetmaster2, then puppetmaster1
For each master, in order:
1. Disable it in HAProxy (puppetca1 and puppetmaster1) → validate `MAINT`.
2. **Run on: that master** — `puppet agent -t` → run the 11e validate block.
3. Java 11 block → validate.
4. Enable it in HAProxy → validate `UP`.

Repeat the Java 11 block on puppetca1 and puppetca2 (one at a time; HAProxy serves the other).

**Validate — puppetmaster1**
```bash
for h in puppetca1 puppetca2 puppetmaster1 puppetmaster2 puppetmaster3; do echo -n "$h: "; ssh root@$h 'puppet --version'; done   # 7.34.0 x5
```

### 11g — Workers, one role at a time (worker3 → worker1 → worker2)
**Run on: laptop**, in `puppet-control-repo` — add the `puppet_agent7::*` keys to `data/common.yaml`
(same values as `puppet_agent5::*`, with `serverport: 8142` instead of `masterport`, the Puppet 7 repo
URL and `agent_version: '7.34.0-1.el7'`), then swap the agent module in the role (example: worker3):
```bash
sed -i 's/include puppet_agent5/include puppet_agent7/' site/role/manifests/admin.pp
```
Commit (dev → production), then r10k deploy. Next time: `infra.pp` (worker1), then `webserver.pp` (worker2).

**Before — Run on: the worker**
```bash
facter -p --json networking.ip networking.hostname os.family kernelrelease intended_hostgroup > /root/facts-p5.json
ls -l /etc/puppetlabs/puppet/ssl/certs/$(hostname -f).pem
```
**Upgrade — Run on: the worker** — `puppet agent -t`
(look for `Package[puppet-agent] ... '5.5.22-1.el7' to '7.34.0-1.el7'`)

**Validate — the worker** (one minute later)
```bash
puppet --version                                       # 7.34.0
puppet ssl verify && echo "ssl ok"
ls -l /etc/puppetlabs/puppet/ssl/certs/$(hostname -f).pem         # same file and date as before
facter -p --json networking.ip networking.hostname os.family kernelrelease intended_hostgroup | diff /root/facts-p5.json - && echo "same facts"
grep -E "serverport|masterport" /etc/puppetlabs/puppet/puppet.conf   # serverport = 8142
systemctl is-active puppet
puppet agent -t --noop 2>&1 | grep -E "Would have|Error|Applied catalog"   # Applied catalog
```
Then the role check for that worker (9f).

**Rollback a worker** — swap the role back to `puppet_agent5` (dev → production), then on the worker:
```bash
systemctl stop puppet
yum -y --enablerepo=puppet5 --disablerepo=puppet7 downgrade puppet-agent-5.5.22
puppet agent -t
```

### 11h — Finish
1. Set `puppet_master7::manage_packages: false` in `puppetserver.yaml` and `puppetca.yaml`.
2. **Run on: puppetmaster1** — enable the agent daemon on the servers:
```bash
for h in puppetca1 puppetca2 puppetmaster1 puppetmaster2 puppetmaster3; do ssh root@$h 'systemctl enable --now puppet'; done
```
3. Remove `puppet_agent5` from `puppet-modules` once no role includes it.

**Validate — admin**
```bash
curl -s -G http://localhost:8080/pdb/query/v4/facts --data-urlencode 'query=["=","name","puppetversion"]' | python3 -c 'import json,sys; [print("%-28s %s" % (r["certname"], r["value"])) for r in sorted(json.load(sys.stdin), key=lambda r: r["certname"])]'   # 7.34.0 everywhere
pdb-inventory.sh                                                                                   # no failed reports
```

---

## Command reference (Puppet 7)

| Task | Command | Node |
|---|---|---|
| List certificates | `puppetserver ca list --all` | puppetca1 |
| Revoke + remove a certificate | `puppetserver ca clean --certname <name>` | puppetca1 |
| Host → hostgroup | `hammer host list --fields Name,"Host Group"` | admin |
| Role pinned on a hostgroup | `hammer hostgroup puppet-classes --hostgroup <hg>` | admin |
| What Foreman sends for a host | `hammer host enc-dump --name <host>` | admin |
| What a role contains | `cat .../production/site/role/manifests/<role>.pp` | puppetmaster1 |
| Classes a node received | `cat /opt/puppetlabs/puppet/cache/state/classes.txt` | the node |
| Fleet inventory | `pdb-inventory.sh` | admin |
| LB backend state | `echo "show stat" \| socat stdio /var/run/haproxy/admin.sock \| cut -d, -f1,2,18` | puppetca1 |
| Take a master out / in | `echo "disable\|enable server puppetmaster_back/<name>" \| socat stdio /var/run/haproxy/admin.sock` | puppetca1 + puppetmaster1 |
| PuppetDB size | `sudo -u postgres psql -d puppetdb -c "SELECT pg_size_pretty(pg_database_size('puppetdb'));"` | admin |
