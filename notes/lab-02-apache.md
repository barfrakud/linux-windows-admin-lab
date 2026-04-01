# LAB-02: Apache Web Server with hardening

**Status:** In progress
**Machine:** rhel-web01 (Rocky Linux 9, VM — QEMU/KVM); rhel-srv01 (DNS integration)
**Reference:** [lab-plan.md — LAB-02](../lab-plan.md)

### Lab context

| Element | Value |
|---|---|
| Host | rhel-web01 (10.10.10.21) — **new VM provisioned in this lab** |
| OS | Rocky Linux 9 minimal (full VM — QEMU/KVM) |
| DNS | BIND on rhel-srv01 (post-LAB-01), authoritative for `linux.lab.local` |
| SELinux | **Enforcing** — full VM, kernel gościa ma pełną kontrolę nad MAC |
| Why VM? | SELinux enforcement nie działa w LXC (LAB-01, krok 5.1). Pełna VM wymagana dla realnej konfiguracji kontekstów i booleanów Apache. |

**End state after this lab:**
- rhel-web01 VM running Rocky Linux 9 with SELinux enforcing
- Apache running on rhel-web01 with three virtual hosts:
  - Default vhost: HTTP → HTTPS redirect
  - `www.linux.lab.local`: static site over HTTPS
  - `app.linux.lab.local`: reverse proxy over HTTPS (backend: simple HTTP service on localhost:8080)
- TLS termination with self-signed CA certificate
- SELinux: enforcing, correct contexts on document roots, `httpd_can_network_connect` for reverse proxy
- Server hardened: version suppression, security headers, HTTP method restrictions
- Firewall: ports 80/443 open
- DNS: rhel-web01 A + PTR records in BIND, CNAME records for www and app

---

## Step 1 — Provision rhel-web01 VM and integrate into the lab environment

### 1.1 — Create VM in Proxmox (Rocky Linux 9 minimal, QEMU/KVM)

Download Rocky Linux 9 minimal ISO (if not already available) and upload to Proxmox:
Proxmox Web UI > local > ISO Images > Upload (or Download from URL)

Create VM in Proxmox:
```
Proxmox UI > Create VM
General > Name: rhel-web01
        > VM ID: (next available, e.g. 107)
OS > ISO image: Rocky Linux 9 minimal ISO
   > Type: Linux
   > Version: 6.x - 2.6 Kernel
System > Machine: q35
       > BIOS: SeaBIOS (default)
Disks > Bus: VirtIO Block
      > Size: 20GB
      > Storage: local-lvm
CPU > Cores: 2
Memory > RAM: 2048 MB
Network > Bridge: vmbr10
        > Model: VirtIO (paravirtualized)
```

Install Rocky Linux 9 minimal:
- Language: English, Keyboard: Polish
- Installation destination: 20 GB VirtIO disk
- Network: enable, set hostname `rhel-web01`
- Root password: set
- Software selection: Minimal Install

---
### Notes

---
### Conclusion

---
#### What - Co zrobiłem?

---
#### Why - Dlaczego to zrobiłem?

---
#### Result - Co dzięki temu uzyskałem?

---
#### Lesson Learned - Co się nauczyłem?

---
#### Problem solved - Jakie problemy zostały rozwiązane?

---

### 1.2 — Configure static IP and networking

Set static IP after first boot:
```bash
nmcli con mod "$(nmcli -g NAME con show --active | head -1)" \
    ipv4.method manual \
    ipv4.addresses 10.10.10.21/24 \
    ipv4.gateway 10.10.10.1 \
    ipv4.dns 10.10.10.20 \
    ipv4.dns-search "linux.lab.local lab.local"
nmcli con up "$(nmcli -g NAME con show --active | head -1)"
```

Verify:
```bash
ip addr show
cat /etc/resolv.conf
ping -c 2 10.10.10.1
ping -c 2 10.10.10.20
```

### Notes

### Conclusion

#### What - Co zrobiłem?

---
#### Why - Dlaczego to zrobiłem?

---
#### Result - Co dzięki temu uzyskałem?

---
#### Lesson Learned - Co się nauczyłem?

---
#### Problem solved - Jakie problemy zostały rozwiązane?

---

### 1.3 — Verify SELinux enforcing mode

```bash
getenforce
sestatus
```

Expected: `Enforcing` (Rocky Linux 9 full VM default).

If not enforcing:
```bash
vi /etc/selinux/config
# SELINUX=enforcing
reboot
```

### Notes

### Conclusion

#### What - Co zrobiłem?

---
#### Why - Dlaczego to zrobiłem?

---
#### Result - Co dzięki temu uzyskałem?

---
#### Lesson Learned - Co się nauczyłem?

---
#### Problem solved - Jakie problemy zostały rozwiązane?

---

### 1.4 — Add DNS records in BIND (on rhel-srv01)

Connect to rhel-srv01 and add records for rhel-web01.

Add A record to `/var/named/linux.lab.local.zone`:
```dns
rhel-web01  IN  A       10.10.10.21
```

Add PTR record to `/var/named/10.10.10.rev`:
```dns
21   IN  PTR  rhel-web01.linux.lab.local.
```

Increment serial numbers in both zone files, then validate and reload:
```bash
named-checkzone linux.lab.local /var/named/linux.lab.local.zone
named-checkzone 10.10.10.in-addr.arpa /var/named/10.10.10.rev
systemctl reload named
```

Verify from rhel-web01:
```bash
dig +short rhel-web01.linux.lab.local
dig +short -x 10.10.10.21
```

### Notes

### Conclusion

#### What - Co zrobiłem?

---
#### Why - Dlaczego to zrobiłem?

---
#### Result - Co dzięki temu uzyskałem?

---
#### Lesson Learned - Co się nauczyłem?

---
#### Problem solved - Jakie problemy zostały rozwiązane?

---

### 1.5 — Install base tools and take snapshot

```bash
dnf install -y vim bind-utils
```

Verify full connectivity:
```bash
dig rhel-srv01.linux.lab.local
dig win-dc01.lab.local
ping -c 2 rhel-srv01.linux.lab.local
```

Take Proxmox snapshot of rhel-web01: `pre-lab-02-apache`

### Notes

### Conclusion

#### What - Co zrobiłem?

---
#### Why - Dlaczego to zrobiłem?

---
#### Result - Co dzięki temu uzyskałem?

---
#### Lesson Learned - Co się nauczyłem?

---
#### Problem solved - Jakie problemy zostały rozwiązane?

---

## Step 2 — Install Apache with SSL module

### 2.1 — Install packages

```bash
dnf install -y httpd mod_ssl
```

Verify:
```bash
rpm -q httpd mod_ssl
httpd -v
```

### Notes

### Conclusion

#### What - Co zrobiłem?

---
#### Why - Dlaczego to zrobiłem?

---
#### Result - Co dzięki temu uzyskałem?

---
#### Lesson Learned - Co się nauczyłem?

---
#### Problem solved - Jakie problemy zostały rozwiązane?

---

### 2.2 — Enable and start httpd service

```bash
systemctl enable --now httpd
systemctl status httpd
```

Verify default page:
```bash
curl -s http://localhost | head -20
```

### Notes

### Conclusion

#### What - Co zrobiłem?

---
#### Why - Dlaczego to zrobiłem?

---
#### Result - Co dzięki temu uzyskałem?

---
#### Lesson Learned - Co się nauczyłem?

---
#### Problem solved - Jakie problemy zostały rozwiązane?

---

## Step 3 — Issue a TLS certificate (self-signed CA)

### 3.1 — Create a self-signed Certificate Authority (CA)

Create a directory structure for the lab CA:
```bash
mkdir -p /etc/pki/lab-ca
cd /etc/pki/lab-ca
```

Generate CA private key and self-signed CA certificate:
```bash
openssl genrsa -out ca.key 4096

openssl req -new -x509 -days 3650 -key ca.key \
    -out ca.crt \
    -subj "/C=PL/ST=Lab/O=Linux Lab/CN=Linux Lab CA"
```

Verify:
```bash
openssl x509 -in ca.crt -noout -subject -issuer -dates
```

### Notes

### Conclusion

#### What - Co zrobiłem?

---
#### Why - Dlaczego to zrobiłem?

---
#### Result - Co dzięki temu uzyskałem?

---
#### Lesson Learned - Co się nauczyłem?

---
#### Problem solved - Jakie problemy zostały rozwiązane?

---

### 3.2 — Generate server certificate with SAN for virtual hosts

Generate server key and CSR with Subject Alternative Names:
```bash
openssl genrsa -out server.key 2048

cat > server-csr.cnf << 'EOF'
[req]
default_bits = 2048
prompt = no
distinguished_name = dn
req_extensions = san

[dn]
C = PL
ST = Lab
O = Linux Lab
CN = rhel-web01.linux.lab.local

[san]
subjectAltName = DNS:rhel-web01.linux.lab.local,DNS:www.linux.lab.local,DNS:app.linux.lab.local
EOF

openssl req -new -key server.key -out server.csr -config server-csr.cnf
```

Sign the CSR with the lab CA:
```bash
cat > server-ext.cnf << 'EOF'
subjectAltName = DNS:rhel-web01.linux.lab.local,DNS:www.linux.lab.local,DNS:app.linux.lab.local
EOF

openssl x509 -req -days 365 \
    -in server.csr \
    -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out server.crt \
    -extfile server-ext.cnf
```

Verify and deploy:
```bash
openssl x509 -in server.crt -noout -subject -issuer -dates
openssl x509 -in server.crt -noout -text | grep -A 1 "Subject Alternative Name"

cp server.crt /etc/pki/tls/certs/rhel-web01.crt
cp server.key /etc/pki/tls/private/rhel-web01.key
chmod 600 /etc/pki/tls/private/rhel-web01.key
```

### Notes

### Conclusion

#### What - Co zrobiłem?

---
#### Why - Dlaczego to zrobiłem?

---
#### Result - Co dzięki temu uzyskałem?

---
#### Lesson Learned - Co się nauczyłem?

---
#### Problem solved - Jakie problemy zostały rozwiązane?

---

## Step 4 — Configure virtual hosts

### 4.1 — Add DNS CNAME records for virtual host names (on rhel-srv01)

Add CNAME records to BIND zone file `/var/named/linux.lab.local.zone` on rhel-srv01:
```dns
; Virtual host aliases
www         IN  CNAME   rhel-web01.linux.lab.local.
app         IN  CNAME   rhel-web01.linux.lab.local.
```

Increment serial number in SOA record, then validate and reload:
```bash
named-checkzone linux.lab.local /var/named/linux.lab.local.zone
systemctl reload named
```

Verify from rhel-web01:
```bash
dig +short www.linux.lab.local
dig +short app.linux.lab.local
```

### Notes

### Conclusion

#### What - Co zrobiłem?

---
#### Why - Dlaczego to zrobiłem?

---
#### Result - Co dzięki temu uzyskałem?

---
#### Lesson Learned - Co się nauczyłem?

---
#### Problem solved - Jakie problemy zostały rozwiązane?

---

### 4.2 — Configure default virtual host with HTTP → HTTPS redirect

Create `/etc/httpd/conf.d/00-default-redirect.conf`:
```apache
<VirtualHost *:80>
    ServerName rhel-web01.linux.lab.local
    RewriteEngine On
    RewriteRule ^(.*)$ https://%{HTTP_HOST}$1 [R=301,L]
</VirtualHost>
```

### Notes

### Conclusion

#### What - Co zrobiłem?

---
#### Why - Dlaczego to zrobiłem?

---
#### Result - Co dzięki temu uzyskałem?

---
#### Lesson Learned - Co się nauczyłem?

---
#### Problem solved - Jakie problemy zostały rozwiązane?

---

### 4.3 — Configure static site virtual host (www.linux.lab.local)

Create document root and sample content:
```bash
mkdir -p /var/www/www-site
cat > /var/www/www-site/index.html << 'EOF'
<!DOCTYPE html>
<html><head><title>Linux Lab — Static Site</title></head>
<body><h1>www.linux.lab.local</h1><p>LAB-02 static site on Apache/RHEL</p></body>
</html>
EOF
```

Create `/etc/httpd/conf.d/www.linux.lab.local.conf`:
```apache
<VirtualHost *:443>
    ServerName www.linux.lab.local
    DocumentRoot /var/www/www-site

    SSLEngine on
    SSLCertificateFile /etc/pki/tls/certs/rhel-web01.crt
    SSLCertificateKeyFile /etc/pki/tls/private/rhel-web01.key

    <Directory /var/www/www-site>
        Require all granted
    </Directory>
</VirtualHost>
```

### Notes

### Conclusion

#### What - Co zrobiłem?

---
#### Why - Dlaczego to zrobiłem?

---
#### Result - Co dzięki temu uzyskałem?

---
#### Lesson Learned - Co się nauczyłem?

---
#### Problem solved - Jakie problemy zostały rozwiązane?

---

### 4.4 — Configure reverse proxy virtual host (app.linux.lab.local)

Set up a simple backend for reverse proxy demonstration:
```bash
mkdir -p /opt/backend-app
cat > /opt/backend-app/app.py << 'PYEOF'
from http.server import HTTPServer, SimpleHTTPRequestHandler

class Handler(SimpleHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-type", "text/html")
        self.end_headers()
        self.wfile.write(b"<h1>Backend App</h1><p>Response from backend on port 8080</p>")

HTTPServer(("127.0.0.1", 8080), Handler).serve_forever()
PYEOF

cat > /etc/systemd/system/backend-app.service << 'EOF'
[Unit]
Description=Simple backend app for reverse proxy demo
After=network.target

[Service]
ExecStart=/usr/bin/python3 /opt/backend-app/app.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl enable --now backend-app
curl http://127.0.0.1:8080
```

Create `/etc/httpd/conf.d/app.linux.lab.local.conf`:
```apache
<VirtualHost *:443>
    ServerName app.linux.lab.local

    SSLEngine on
    SSLCertificateFile /etc/pki/tls/certs/rhel-web01.crt
    SSLCertificateKeyFile /etc/pki/tls/private/rhel-web01.key

    ProxyPreserveHost On
    ProxyPass / http://127.0.0.1:8080/
    ProxyPassReverse / http://127.0.0.1:8080/
</VirtualHost>
```

Verify Apache config and reload:
```bash
httpd -t
systemctl reload httpd
```

### Notes

### Conclusion

#### What - Co zrobiłem?

---
#### Why - Dlaczego to zrobiłem?

---
#### Result - Co dzięki temu uzyskałem?

---
#### Lesson Learned - Co się nauczyłem?

---
#### Problem solved - Jakie problemy zostały rozwiązane?

---

## Step 5 — Configure SELinux contexts and booleans for each virtual host type

### 5.1 — Verify and set SELinux contexts on document roots

```bash
ls -lZ /var/www/www-site/
ls -lZ /opt/backend-app/
```

If context is not `httpd_sys_content_t` for document root:
```bash
semanage fcontext -a -t httpd_sys_content_t "/var/www/www-site(/.*)?"
restorecon -Rv /var/www/www-site/
```

Verify:
```bash
ls -lZ /var/www/www-site/
```

### Notes

### Conclusion

#### What - Co zrobiłem?

---
#### Why - Dlaczego to zrobiłem?

---
#### Result - Co dzięki temu uzyskałem?

---
#### Lesson Learned - Co się nauczyłem?

---
#### Problem solved - Jakie problemy zostały rozwiązane?

---

### 5.2 — Enable SELinux booleans for reverse proxy

```bash
getsebool httpd_can_network_connect
setsebool -P httpd_can_network_connect 1
getsebool httpd_can_network_connect
```

Test reverse proxy with SELinux enforcing:
```bash
curl -sk https://app.linux.lab.local
```

### Notes

### Conclusion

#### What - Co zrobiłem?

---
#### Why - Dlaczego to zrobiłem?

---
#### Result - Co dzięki temu uzyskałem?

---
#### Lesson Learned - Co się nauczyłem?

---
#### Problem solved - Jakie problemy zostały rozwiązane?

---

### 5.3 — Verify SELinux audit log for denials

```bash
ausearch -m avc -ts recent
sealert -a /var/log/audit/audit.log 2>/dev/null | head -50
```

### Notes

### Conclusion

#### What - Co zrobiłem?

---
#### Why - Dlaczego to zrobiłem?

---
#### Result - Co dzięki temu uzyskałem?

---
#### Lesson Learned - Co się nauczyłem?

---
#### Problem solved - Jakie problemy zostały rozwiązane?

---

## Step 6 — Open required firewall ports

### 6.1 — Install and configure firewalld

```bash
dnf install -y firewalld
systemctl enable --now firewalld
firewall-cmd --state
```

Add HTTP and HTTPS services:
```bash
firewall-cmd --list-services
firewall-cmd --permanent --add-service=http --add-service=https
firewall-cmd --reload
firewall-cmd --list-services
```

Verify from another machine:
```bash
curl -k https://10.10.10.21
curl -k https://www.linux.lab.local
```

### Notes

### Conclusion

#### What - Co zrobiłem?

---
#### Why - Dlaczego to zrobiłem?

---
#### Result - Co dzięki temu uzyskałem?

---
#### Lesson Learned - Co się nauczyłem?

---
#### Problem solved - Jakie problemy zostały rozwiązane?

---

## Step 7 — Apply server hardening

### 7.1 — Suppress version disclosure

Create `/etc/httpd/conf.d/security-hardening.conf`:
```apache
ServerTokens Prod
ServerSignature Off
```

Verify:
```bash
httpd -t
systemctl reload httpd
curl -sI http://localhost | grep Server
```

### Notes

### Conclusion

#### What - Co zrobiłem?

---
#### Why - Dlaczego to zrobiłem?

---
#### Result - Co dzięki temu uzyskałem?

---
#### Lesson Learned - Co się nauczyłem?

---
#### Problem solved - Jakie problemy zostały rozwiązane?

---

### 7.2 — Add security response headers

Add to `/etc/httpd/conf.d/security-hardening.conf`:
```apache
Header always set X-Content-Type-Options "nosniff"
Header always set X-Frame-Options "SAMEORIGIN"
Header always set X-XSS-Protection "1; mode=block"
Header always set Referrer-Policy "strict-origin-when-cross-origin"
Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains"
Header always set Content-Security-Policy "default-src 'self'"
```

Verify:
```bash
httpd -M | grep headers
httpd -t
systemctl reload httpd
curl -skI https://www.linux.lab.local | grep -E "^(X-|Strict|Content-Security|Referrer)"
```

### Notes

### Conclusion

#### What - Co zrobiłem?

---
#### Why - Dlaczego to zrobiłem?

---
#### Result - Co dzięki temu uzyskałem?

---
#### Lesson Learned - Co się nauczyłem?

---
#### Problem solved - Jakie problemy zostały rozwiązane?

---

### 7.3 — Restrict HTTP methods

Add to `/etc/httpd/conf.d/security-hardening.conf`:
```apache
<Directory />
    <LimitExcept GET POST HEAD>
        Require all denied
    </LimitExcept>
</Directory>
```

Verify:
```bash
httpd -t
systemctl reload httpd
curl -sk -X TRACE https://www.linux.lab.local
curl -sk -X DELETE https://www.linux.lab.local
curl -sk https://www.linux.lab.local
```

### Notes

### Conclusion

#### What - Co zrobiłem?

---
#### Why - Dlaczego to zrobiłem?

---
#### Result - Co dzięki temu uzyskałem?

---
#### Lesson Learned - Co się nauczyłem?

---
#### Problem solved - Jakie problemy zostały rozwiązane?

---

## Step 8 — Test all virtual hosts, verify TLS, SELinux, and hardening

### 8.1 — Test default HTTP → HTTPS redirect

```bash
curl -sI http://rhel-web01.linux.lab.local | head -5
```

### Notes

### Conclusion

#### What - Co zrobiłem?

---
#### Why - Dlaczego to zrobiłem?

---
#### Result - Co dzięki temu uzyskałem?

---
#### Lesson Learned - Co się nauczyłem?

---
#### Problem solved - Jakie problemy zostały rozwiązane?

---

### 8.2 — Test static site virtual host

```bash
curl -sk https://www.linux.lab.local
```

### Notes

### Conclusion

#### What - Co zrobiłem?

---
#### Why - Dlaczego to zrobiłem?

---
#### Result - Co dzięki temu uzyskałem?

---
#### Lesson Learned - Co się nauczyłem?

---
#### Problem solved - Jakie problemy zostały rozwiązane?

---

### 8.3 — Test reverse proxy virtual host

```bash
curl -sk https://app.linux.lab.local
```

### Notes

### Conclusion

#### What - Co zrobiłem?

---
#### Why - Dlaczego to zrobiłem?

---
#### Result - Co dzięki temu uzyskałem?

---
#### Lesson Learned - Co się nauczyłem?

---
#### Problem solved - Jakie problemy zostały rozwiązane?

---

### 8.4 — Verify TLS certificate

```bash
openssl s_client -connect www.linux.lab.local:443 -servername www.linux.lab.local < /dev/null 2>/dev/null | openssl x509 -noout -subject -issuer -dates
```

### Notes

### Conclusion

#### What - Co zrobiłem?

---
#### Why - Dlaczego to zrobiłem?

---
#### Result - Co dzięki temu uzyskałem?

---
#### Lesson Learned - Co się nauczyłem?

---
#### Problem solved - Jakie problemy zostały rozwiązane?

---

### 8.5 — Verify SELinux status and audit log

```bash
getenforce
getsebool httpd_can_network_connect
ausearch -m avc -ts recent 2>/dev/null | head -20
```

### Notes

### Conclusion

#### What - Co zrobiłem?

---
#### Why - Dlaczego to zrobiłem?

---
#### Result - Co dzięki temu uzyskałem?

---
#### Lesson Learned - Co się nauczyłem?

---
#### Problem solved - Jakie problemy zostały rozwiązane?

---

### 8.6 — Verify hardening and cross-platform access

From another machine (ubuntu-ws01 or Proxmox host):
```bash
curl -skI https://www.linux.lab.local | grep Server
curl -skI https://www.linux.lab.local | grep -E "^(X-|Strict|Content-Security|Referrer)"
curl -sk -X TRACE https://www.linux.lab.local
```

From win-mgmt01 (PowerShell):
```powershell
Resolve-DnsName www.linux.lab.local
Resolve-DnsName app.linux.lab.local
Invoke-WebRequest -Uri https://www.linux.lab.local -SkipCertificateCheck | Select-Object StatusCode
Invoke-WebRequest -Uri https://app.linux.lab.local -SkipCertificateCheck | Select-Object StatusCode
```

### Notes

### Conclusion

#### What - Co zrobiłem?

---
#### Why - Dlaczego to zrobiłem?

---
#### Result - Co dzięki temu uzyskałem?

---
#### Lesson Learned - Co się nauczyłem?

---
#### Problem solved - Jakie problemy zostały rozwiązane?

---

## LAB-02 — Conclusion

#### What - Co zrobiłem?

---
#### Why - Dlaczego to zrobiłem?

---
#### Result - Co dzięki temu uzyskałem?

---
#### Lesson Learned - Co się nauczyłem?

---
#### Problem solved - Jakie problemy zostały rozwiązane?
