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

### 1.1 ✅ — Create VM in Proxmox (Rocky Linux 9 minimal, QEMU/KVM)

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

Zainstalowałem maszynę wirtualną Rocky Linux 9 minimal w Proxmox jako pełną VM (QEMU/KVM).

---
### Conclusion

#### What - Co zrobiłem?
Utworzenie nowej maszyny wirtualnej rhel-web01 w Proxmox z Rocky Linux 9 minimal. Konfiguracja: q35, SeaBIOS, 2 CPU, 2 GB RAM, 20 GB VirtIO disk, sieć na vmbr10 (VirtIO). Instalacja minimalna z ustawionym hostname i hasłem root.

---
#### Why - Dlaczego to zrobiłem?
Lab-02 wymaga pełnej VM (nie kontenera LXC) ze względu na SELinux — enforcement nie działa poprawnie w LXC. Apache z SELinux enforcing to główny cel tego ćwiczenia.

---
#### Result - Co dzięki temu uzyskałem?
Działająca VM z Rocky Linux 9 minimal, gotowa do konfiguracji sieci i dalszych kroków. System jeszcze nie ma statycznego IP ani narzędzi.

---
#### Lesson Learned - Co się nauczyłem?
Różnica między LXC a pełną VM ma znaczenie przy SELinux — LXC współdzieli kernel z hostem i nie pozwala na pełną kontrolę MAC. Dlatego do ćwiczeń z SELinux potrzebna jest pełna VM.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
Brak problemów w tym kroku.

---

### 1.2 ✅ — Configure static IP and networking

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

Skonfigurowałem statyczny adres IP używając nmtui. Następnie dopełniłem konfigurację przez nmcli, żeby dodać dns-search domains. Sieć działa i pinguje inne hosty w sieci (gateway 10.10.10.1, DNS 10.10.10.20).

### Conclusion

#### What - Co zrobiłem?
Skonfigurowałem statyczny adres IP 10.10.10.21/24 na interfejsie ens18. Początkowo użyłem nmtui (IP, gateway, DNS), a potem uzupełniłem przez nmcli o domeny wyszukiwania DNS: `linux.lab.local` i `lab.local`.

---
#### Why - Dlaczego to zrobiłem?
VM musi mieć stały adres IP w sieci lab (10.10.10.0/24), żeby inne hosty mogły się do niej odwoływać. DNS search domains pozwalają używać krótkich nazw hostów zamiast FQDN.

---
#### Result - Co dzięki temu uzyskałem?
rhel-web01 ma statyczne IP 10.10.10.21/24, gateway 10.10.10.1, DNS 10.10.10.20. W `/etc/resolv.conf` widnieją linie `search linux.lab.local lab.local` oraz `nameserver 10.10.10.20`. Ping do gateway i DNS serwera działa.

---
#### Lesson Learned - Co się nauczyłem?
nmtui i nmcli to dwa interfejsy do tego samego NetworkManagera — modyfikują ten sam profil połączenia. nmtui ma pole "Search domains" w sekcji IPv4, które początkowo pominąłem. Domena dns-search powoduje, że system automatycznie próbuje dopisywać podane sufiksy do krótkich nazw hostów przy zapytaniach DNS.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
Brak domen wyszukiwania DNS po konfiguracji nmtui — uzupełnione przez nmcli.

---

### 1.3 ✅ — Verify SELinux enforcing mode

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

Sprawdziłem i SELinux jest włączony, wynik poniżej:
```bash
[root@rhel-web01 ~]# sestatus
SELinux status:                 enabled
SELinuxfs mount:                /sys/fs/selinux
SELinux root directory:         /etc/selinux
Loaded policy name:             targeted
Current mode:                   enforcing
Mode from config file:          enforcing
Policy MLS status:              enabled
Policy deny_unknown status:     allowed
Memory protection checking:     actual (secure)
Max kernel policy version:      33
[root@rhel-web01 ~]# getenforce
Enforcing
```

### Conclusion

#### What - Co zrobiłem?
Zweryfikowałem tryb SELinux na rhel-web01 komendami `getenforce` i `sestatus`.

---
#### Why - Dlaczego to zrobiłem?
Cały Lab-02 opiera się na konfiguracji Apache z SELinux enforcing. Trzeba upewnić się na początku, że SELinux jest włączony, zanim zacznę konfigurację vhostów i kontekstów.

---
#### Result - Co dzięki temu uzyskałem?
SELinux jest w trybie enforcing z polityką targeted. Nie trzeba niczego zmieniać — Rocky Linux 9 ma to domyślnie włączone na pełnej VM.

---
#### Lesson Learned - Co się nauczyłem?
`getenforce` zwraca krótką odpowiedź (Enforcing/Permissive/Disabled), `sestatus` daje pełny obraz: polityka (targeted), tryb bieżący vs. tryb z configa, MLS, wersja polityki kernela. Warto sprawdzać oba — jeśli Current mode != Mode from config file, to znaczy że ktoś zmienił tryb tymczasowo przez `setenforce` i po restarcie wróci do configa.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
Brak problemów — SELinux był już włączony domyślnie.

---

### 1.4 ✅ — Add DNS records in BIND (on rhel-srv01)

Install `bind-utils` first (provides `dig`, needed for DNS verification):
```bash
dnf install -y bind-utils
```

Connect to rhel-srv01 and add records for rhel-web01.

Add A record to `/var/named/linux.lab.local.zone`:
```dns
rhel-web01  IN  A       10.10.10.21
```

Add PTR record to `/var/named/10.10.10.rev`:
```dns
21   IN  PTR  rhel-web01.linux.lab.local.
```

Increment serial numbers in both zone files:

In each zone file, find the SOA record's serial number (usually in format `YYYYMMDDNN`, e.g. `2026040101`) and increment it by 1:
```bash
# Forward zone
vi /var/named/linux.lab.local.zone
# Find the line with the serial number inside the SOA record, e.g.:
#                         2026040101  ; serial
# Change it to:
#                         2026040102  ; serial

# Reverse zone
vi /var/named/10.10.10.rev
# Same — find and increment the serial number in the SOA record
```

> **Tip:** Konwencja `YYYYMMDDNN` — data + numer zmiany danego dnia (01, 02…). Jeśli dzisiaj jest pierwsza zmiana, ustaw np. `2026040101`. Kolejna zmiana tego samego dnia → `2026040102`.

Validate and reload:
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

Zainstalowałem bind-utils na rhel-web01. Na rhel-srv01 dodałem rekord A (rhel-web01 → 10.10.10.21) w strefie forward i rekord PTR (21 → rhel-web01.linux.lab.local.) w strefie reverse. Zinkrementowałem serial w obu plikach strefowych, zwalidowałem named-checkzone i przeładowałem BIND. Weryfikacja dig z rhel-web01 potwierdziła poprawność:
```
dig +short rhel-web01.linux.lab.local → 10.10.10.21
dig +short -x 10.10.10.21 → rhel-web01.linux.lab.local.
```

### Conclusion

#### What - Co zrobiłem?
Dodałem rekord A i PTR dla rhel-web01 w BIND na rhel-srv01. Zinkrementowałem numery seryjne w obu plikach strefowych (`linux.lab.local.zone` i `10.10.10.rev`), zwalidowałem strefy i przeładowałem named.

---
#### Why - Dlaczego to zrobiłem?
rhel-web01 musi być rozpoznawalny w DNS laba — zarówno po nazwie (A record), jak i po IP (PTR record). Kolejne kroki (vhosty Apache, certyfikaty TLS z SAN) będą opierać się na rozpoznawaniu nazw DNS.

---
#### Result - Co dzięki temu uzyskałem?
DNS rozwiązuje zarówno forward (rhel-web01.linux.lab.local → 10.10.10.21) jak i reverse (10.10.10.21 → rhel-web01.linux.lab.local). Weryfikacja z rhel-web01 potwierdzona.

---
#### Lesson Learned - Co się nauczyłem?
Przy każdej zmianie plików strefowych BIND trzeba zinkrementować serial w SOA — bez tego BIND (i ewentualne serwery slave) nie zauważą zmian. Konwencja YYYYMMDDNN jest wygodna do śledzenia, kiedy i która zmiana została wprowadzona. Ważne: bind-utils (pakiet z `dig`) powinien być zainstalowany zanim zacznę weryfikować DNS — w oryginalnym planie był dopiero w kroku 1.5, co było niespójne.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
Niesprójność w planie — bind-utils był potrzebny w kroku 1.4 (do `dig`), ale zaplanowany dopiero w 1.5. Przeniesiono instalację bind-utils do początku kroku 1.4.

---

### 1.5 ✅ — Install remaining base tools and take snapshot

```bash
dnf install -y vim
dnf install -y nano
```

Verify full connectivity:
```bash
dig rhel-srv01.linux.lab.local
dig win-dc01.lab.local
ping -c 2 rhel-srv01.linux.lab.local
```

Take Proxmox snapshot of rhel-web01: `pre-lab-02-apache`

### Notes

Zainstalowałem vim i nano. Zweryfikowałem pełną łączność DNS i sieciową:
```
[root@rhel-web01 ~]# dig rhel-srv01.linux.lab.local
dig win-dc01.lab.local
ping -c 2 rhel-srv01.linux.lab.local

; <<>> DiG 9.16.23-RH <<>> rhel-srv01.linux.lab.local
;; global options: +cmd
;; Got answer:
;; WARNING: .local is reserved for Multicast DNS
;; You are currently testing what happens when an mDNS query is leaked to DNS
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 53852
;; flags: qr aa rd ra; QUERY: 1, ANSWER: 1, AUTHORITY: 0, ADDITIONAL: 1

;; OPT PSEUDOSECTION:
; EDNS: version: 0, flags:; udp: 1232
; COOKIE: f869ea3c3c29b03b0100000069cd11dd38f2255b5dc9b0f0 (good)
;; QUESTION SECTION:
;rhel-srv01.linux.lab.local.    IN      A

;; ANSWER SECTION:
rhel-srv01.linux.lab.local. 86400 IN    A       10.10.10.20

;; Query time: 1 msec
;; SERVER: 10.10.10.20#53(10.10.10.20)
;; WHEN: Wed Apr 01 14:38:53 CEST 2026
;; MSG SIZE  rcvd: 99


; <<>> DiG 9.16.23-RH <<>> win-dc01.lab.local
;; global options: +cmd
;; Got answer:
;; WARNING: .local is reserved for Multicast DNS
;; You are currently testing what happens when an mDNS query is leaked to DNS
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 8305
;; flags: qr rd ra; QUERY: 1, ANSWER: 1, AUTHORITY: 0, ADDITIONAL: 1

;; OPT PSEUDOSECTION:
; EDNS: version: 0, flags:; udp: 1232
; COOKIE: 7204cc1e750183680100000069cd11dd815ab42a78f5a7cf (good)
;; QUESTION SECTION:
;win-dc01.lab.local.            IN      A

;; ANSWER SECTION:
win-dc01.lab.local.     3600    IN      A       10.10.10.10

;; Query time: 1 msec
;; SERVER: 10.10.10.20#53(10.10.10.20)
;; WHEN: Wed Apr 01 14:38:53 CEST 2026
;; MSG SIZE  rcvd: 91

PING rhel-srv01.linux.lab.local (10.10.10.20) 56(84) bytes of data.
64 bytes from rhel-srv01.linux.lab.local (10.10.10.20): icmp_seq=1 ttl=64 time=0.029 ms
64 bytes from rhel-srv01.linux.lab.local (10.10.10.20): icmp_seq=2 ttl=64 time=0.316 ms

--- rhel-srv01.linux.lab.local ping statistics ---
2 packets transmitted, 2 received, 0% packet loss, time 1037ms
rtt min/avg/max/mdev = 0.029/0.172/0.316/0.143 ms
```

Zrobiłem snapshot `pre-lab-02-apache` w Proxmox.

### Conclusion

#### What - Co zrobiłem?
Zainstalowałem vim i nano na rhel-web01. Zweryfikowałem pełną łączność: `dig` rozwiązuje rhel-srv01.linux.lab.local (10.10.10.20) i win-dc01.lab.local (10.10.10.10), ping do rhel-srv01 działa. Wykonałem snapshot VM `pre-lab-02-apache` w Proxmox.

---
#### Why - Dlaczego to zrobiłem?
Edytory tekstu (vim, nano) są potrzebne do ręcznej edycji plików konfiguracyjnych Apache, certyfikatów i vhostów w kolejnych krokach. Minimalna instalacja Rocky Linux 9 zawiera tylko vi-minimal. Snapshot to punkt przywrócenia przed główną częścią laba (Apache).

---
#### Result - Co dzięki temu uzyskałem?
rhel-web01 jest w pełni zintegrowany z środowiskiem lab: statyczne IP, DNS (forward i reverse), SELinux enforcing, narzędzia diagnostyczne i edytory zainstalowane. Snapshot zabezpiecza ten stan. Maszyna gotowa do instalacji Apache (Step 2).

---
#### Lesson Learned - Co się nauczyłem?
Warto robić snapshoty przed większymi zmianami — jeśli coś pójdzie nie tak z konfiguracją Apache/SELinux, można szybko wrócić do czystego stanu. Weryfikacja łączności cross-domain (dig na strefę `lab.local` obsługiwaną przez AD na win-dc01) potwierdza, że forwarding DNS działa poprawnie między BIND a AD.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
Brak problemów w tym kroku.

---

## Step 2 — Install Apache with SSL module

### 2.1 ✅ — Install packages

```bash
dnf install -y httpd mod_ssl
```

Verify:
```bash
rpm -q httpd mod_ssl
httpd -v
```

### Notes

Zainstalowałem httpd i mod_ssl.

```
rpm -q httpd mod_ssl
httpd-2.4.62-7.el9_7.3.x86_64
mod_ssl-2.4.62-7.el9_7.3.x86_64

httpd -v
Server version: Apache/2.4.62 (Rocky Linux)
Server built:   Dec 12 2025 00:00:00
```
### Conclusion

#### What - Co zrobiłem?
Zainstalowałem pakiety httpd (Apache 2.4.62) i mod_ssl na rhel-web01.

---
#### Why - Dlaczego to zrobiłem?
httpd to główny serwer WWW tego laba. mod_ssl dostarcza moduł SSL/TLS potrzebny do obsługi HTTPS — bez niego Apache nie potrafi terminować połączeń TLS.

---
#### Result - Co dzięki temu uzyskałem?
Pakiety zainstalowane, ale serwis jeszcze nie uruchomiony. Apache gotowy do włączenia w następnym kroku.

---
#### Lesson Learned - Co się nauczyłem?
W Rocky Linux 9 mod_ssl to osobny pakiet — nie jest domyślnie dołączony do httpd. Bez niego dyrektywy SSLEngine, SSLCertificateFile itp. nie będą rozpoznawane.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
Brak problemów w tym kroku.

---

### 2.2 ✅ — Enable and start httpd service

```bash
systemctl enable --now httpd
systemctl status httpd
```

Verify default page:
```bash
curl -s http://localhost | head -20
```

### Notes


Uruchomiłem i włączyłem httpd service (`systemctl enable --now httpd`). Domyślna strona testowa Rocky Linux wyświetla się poprawnie na localhost.

Wynik:
```
[root@rhel-web01 ~]# curl -s http://localhost | head -20
<!doctype html>
<html>
  <head>
    <meta charset='utf-8'>
    <meta name='viewport' content='width=device-width, initial-scale=1'>
    <title>HTTP Server Test Page powered by: Rocky Linux</title>
    <style type="text/css">
      /*<![CDATA[*/

      html {
        height: 100%;
        width: 100%;
      }
        body {
  background: rgb(20,72,50);
  background: -moz-linear-gradient(180deg, rgba(23,43,70,1) 30%, rgba(0,0,0,1) 90%)  ;
  background: -webkit-linear-gradient(180deg, rgba(23,43,70,1) 30%, rgba(0,0,0,1) 90%) ;
  background: linear-gradient(180deg, rgba(23,43,70,1) 30%, rgba(0,0,0,1) 90%);
  background-repeat: no-repeat;
  background-attachment: fixed;
```
### Conclusion

#### What - Co zrobiłem?
Włączyłem i uruchomiłem serwis httpd (`systemctl enable --now httpd`). Zweryfikowałem, że domyślna strona testowa Rocky Linux odpowiada na `curl http://localhost`.

---
#### Why - Dlaczego to zrobiłem?
`enable --now` jednocześnie uruchamia serwis i dodaje go do autostartu. Weryfikacja curl potwierdza, że Apache działa i obsługuje żądania HTTP.

---
#### Result - Co dzięki temu uzyskałem?
Apache działa na porcie 80, serwuje domyślną stronę testową Rocky Linux. Dostępny tylko lokalnie — firewall (firewalld) nie ma jeszcze otwartych portów HTTP/HTTPS, więc z zewnątrz (np. z Windowsa) strona nie będzie dostępna aż do Step 6.

---
#### Lesson Learned - Co się nauczyłem?
`systemctl enable --now` to skrót łączący `enable` (autostart) i `start` (natychmiastowe uruchomienie) w jednym poleceniu. Domyślna strona testowa Rocky Linux pojawia się dopóki nie skonfiguruje się własnych vhostów z DocumentRoot.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
Brak problemów w tym kroku.

---

## Step 3 — Issue a TLS certificate (self-signed CA)

### 3.1 ✅ — Create a self-signed Certificate Authority (CA)

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

Utworzyłem własne CA (Certificate Authority) dla laba.

Co robią poszczególne komendy:

`openssl genrsa -out ca.key 4096` — generuje klucz prywatny RSA o długości 4096 bitów. To jest sekret CA — kto ma ten klucz, może podpisywać certyfikaty. W produkcji powinien być chroniony hasłem (opcja `-aes256`), ale w labie pomijamy to dla wygody.

`openssl req -new -x509 -days 3650 -key ca.key -out ca.crt -subj "..."` — tworzy certyfikat CA:
- `req -new` — nowe żądanie certyfikatu
- `-x509` — zamiast generować CSR (Certificate Signing Request), od razu tworzy gotowy certyfikat self-signed. To dlatego, że CA podpisuje samo siebie — nie ma wyższego CA, który by go podpisał
- `-days 3650` — ważność 10 lat
- `-key ca.key` — użyj tego klucza prywatnego
- `-subj "/C=PL/ST=Lab/O=Linux Lab/CN=Linux Lab CA"` — dane identyfikacyjne CA w formacie Distinguished Name (kraj/stan/organizacja/nazwa)

`openssl x509 -in ca.crt -noout -subject -issuer -dates` — odczytuje certyfikat i wyświetla: subject (kogo certyfikat identyfikuje), issuer (kto go podpisał) i daty ważności. Ponieważ to self-signed CA, subject == issuer.

Wynik weryfikacji:
```
[root@rhel-web01 lab-ca]# openssl x509 -in ca.crt -noout -subject -issuer -dates
subject=C=PL, ST=Lab, O=Linux Lab, CN=Linux Lab CA
issuer=C=PL, ST=Lab, O=Linux Lab, CN=Linux Lab CA
notBefore=Apr  1 12:58:57 2026 GMT
notAfter=Mar 29 12:58:57 2036 GMT
```

### Conclusion

#### What - Co zrobiłem?
Utworzenie prywatnego Certificate Authority (CA) dla laba. Wygenerowałem klucz prywatny CA (RSA 4096-bit) i self-signed certyfikat CA ważny 10 lat. Pliki: `/etc/pki/lab-ca/ca.key` (klucz prywatny) i `/etc/pki/lab-ca/ca.crt` (certyfikat).

---
#### Why - Dlaczego to zrobiłem?
Apache potrzebuje certyfikatu TLS do obsługi HTTPS. W środowisku lab nie używamy publicznego CA (Let's Encrypt itp.) — zamiast tego tworzymy własne CA, które będzie podpisywać certyfikaty serwerowe. Dzięki temu można ćwiczyć pełny łańcuch zaufania: CA → certyfikat serwera → klient ufa CA.

---
#### Result - Co dzięki temu uzyskałem?
Gotowe CA z certyfikatem self-signed (subject == issuer, co potwierdza self-signed). Ważność: 2026–2036. CA jest gotowe do podpisywania certyfikatów serwerowych w następnym kroku (3.2).

---
#### Lesson Learned - Co się nauczyłem?
Certyfikat self-signed CA to taki, gdzie subject i issuer są identyczne — CA podpisuje samo siebie. W normalnym PKI certyfikat CA jest podpisywany przez CA wyższego poziomu (root CA → intermediate CA). Flaga `-x509` w `openssl req` pomija etap CSR i od razu tworzy gotowy certyfikat — używa się tego tylko przy tworzeniu CA, nie przy certyfikatach serwerowych. Klucz CA (4096-bit) jest dłuższy niż klucze serwerowe (zwykle 2048-bit), bo CA jest bardziej krytyczne — kompromitacja klucza CA oznacza kompromitację wszystkich certyfikatów nim podpisanych.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
Brak problemów w tym kroku.

---

### 3.2 ✅ — Generate server certificate with SAN for virtual hosts

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

Wygenerowałem certyfikat serwerowy podpisany przez lab CA z trzema nazwami SAN.

Proces składa się z trzech etapów:

1) Generowanie klucza serwera i CSR (Certificate Signing Request):

`openssl genrsa -out server.key 2048` — klucz prywatny serwera (2048-bit, mniejszy niż CA bo to certyfikat końcowy, odnawiany co rok).

Plik `server-csr.cnf` — konfiguracja CSR. Sekcja `[dn]` to dane identyfikacyjne serwera (Distinguished Name). Sekcja `[san]` definiuje Subject Alternative Names — listę nazw DNS, dla których certyfikat będzie ważny. SAN jest kluczowy, bo nowoczesne przeglądarki ignorują pole CN i sprawdzają tylko SAN.

`openssl req -new -key server.key -out server.csr -config server-csr.cnf` — tworzy CSR (prośbę o podpisanie). Uwaga: tu NIE ma flagi `-x509`, bo to nie jest self-signed — CSR zostanie podpisany przez CA w następnym kroku.

2) Podpisanie CSR przez CA:

Plik `server-ext.cnf` — rozszerzenia X.509, które CA dopisze do certyfikatu. SAN musi być tu powtórzony, bo `openssl x509 -req` nie kopiuje rozszerzeń z CSR automatycznie.

`openssl x509 -req` — podpisuje CSR:
- `-CA ca.crt -CAkey ca.key` — użyj certyfikatu i klucza CA do podpisu
- `-CAcreateserial` — automatycznie tworzy plik `ca.srl` z numerem seryjnym certyfikatu (każdy certyfikat podpisany przez CA musi mieć unikalny numer)
- `-extfile server-ext.cnf` — dołącz rozszerzenia (SAN) do certyfikatu
- `-days 365` — ważność 1 rok

3) Weryfikacja i deploy:

Kopiowanie certyfikatu i klucza do standardowych lokalizacji RHEL (`/etc/pki/tls/certs/` i `/etc/pki/tls/private/`). `chmod 600` na kluczu prywatnym — tylko root może go czytać.

Wynik weryfikacji:
```
subject=C=PL, ST=Lab, O=Linux Lab, CN=rhel-web01.linux.lab.local
issuer=C=PL, ST=Lab, O=Linux Lab, CN=Linux Lab CA
notBefore=Apr  1 13:16:38 2026 GMT
notAfter=Apr  1 13:16:38 2027 GMT
            X509v3 Subject Alternative Name:
                DNS:rhel-web01.linux.lab.local, DNS:www.linux.lab.local, DNS:app.linux.lab.local
```

Subject to serwer (rhel-web01), issuer to CA (Linux Lab CA) — nie są identyczne, więc to nie jest self-signed. SAN zawiera wszystkie 3 nazwy potrzebne dla vhostów.

### Conclusion

#### What - Co zrobiłem?
Wygenerowałem klucz prywatny serwera (RSA 2048-bit), CSR z trzema nazwami SAN (rhel-web01, www, app w domenie linux.lab.local), podpisałem CSR certyfikatem CA z kroku 3.1. Skopiowałem certyfikat i klucz do `/etc/pki/tls/certs/` i `/etc/pki/tls/private/` z odpowiednimi uprawnieniami.

---
#### Why - Dlaczego to zrobiłem?
Apache potrzebuje certyfikatu TLS z poprawnymi nazwami SAN, żeby obsługiwać HTTPS dla trzech vhostów (rhel-web01, www, app). Jeden certyfikat z wieloma SAN jest prostszy niż osobne certyfikaty per vhost.

---
#### Result - Co dzięki temu uzyskałem?
Certyfikat serwerowy gotowy do użycia w konfiguracji Apache (Step 4). Subject != issuer potwierdza, że certyfikat jest podpisany przez CA, a nie self-signed. SAN zawiera wszystkie wymagane nazwy. Ważność: 1 rok.

---
#### Lesson Learned - Co się nauczyłem?
Proces wydania certyfikatu składa się z 3 kroków: klucz → CSR → podpis CA. SAN (Subject Alternative Name) jest jedynym polem, które przeglądarki sprawdzają do weryfikacji nazwy hosta — pole CN w subject jest ignorowane od Chrome 58 (2017). Przy podpisywaniu przez CA (`openssl x509 -req`) rozszerzenia z CSR nie są automatycznie kopiowane — trzeba je podać osobno w `-extfile`. `-CAcreateserial` tworzy plik `.srl` śledzący numery seryjne certyfikatów — każdy następny certyfikat dostanie kolejny numer. Klucz prywatny serwera powinien mieć uprawnienia 600 — jeśli ktokolwiek poza root go odczyta, może podszyć się pod serwer.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
Brak problemów w tym kroku.

---

## Step 4 — Configure virtual hosts

### 4.1 ✅ — Add DNS CNAME records for virtual host names (on rhel-srv01)

Add CNAME records to BIND zone file `/var/named/linux.lab.local.zone` on rhel-srv01:
```dns
; Virtual host aliases
www         IN  CNAME   rhel-web01.linux.lab.local.
app         IN  CNAME   rhel-web01.linux.lab.local.
```

Increment serial number in SOA record:
```bash
vi /var/named/linux.lab.local.zone

# @   IN  SOA  rhel-srv01.linux.lab.local. admin.linux.lab.local. (
#               2026040103 ; Serial
#               3600       ; Refresh
#               1800       ; Retry
#               604800     ; Expire
#               86400 )    ; Minimum TTL
```

Validate and reload:
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

Dodałem rekordy CNAME www i app na rhel-srv01, zinkrementowałem serial do 2026040103, zwalidowałem strefę i przeładowałem named.

Wynik sprawdzenia z rhel-web01:
```
dig +short www.linux.lab.local
rhel-web01.linux.lab.local.
10.10.10.21

dig +short app.linux.lab.local
rhel-web01.linux.lab.local.
10.10.10.21
```

Obie nazwy rozwiązują się poprawnie: CNAME → rhel-web01 → 10.10.10.21.

### Conclusion

#### What - Co zrobiłem?
Dodałem rekordy CNAME (www i app) w strefie `linux.lab.local` na rhel-srv01, wskazujące na rhel-web01.linux.lab.local. Zinkrementowałem serial SOA do 2026040103, zwalidowałem strefę `named-checkzone` i przeładowałem BIND.

---
#### Why - Dlaczego to zrobiłem?
Apache virtual hosts będą rozróżniać żądania po nagłówku `Host:` — klient musi móc rozwiązać nazwy `www.linux.lab.local` i `app.linux.lab.local` na IP serwera. CNAME zamiast osobnych rekordów A pozwala na jedno miejsce zmiany IP (tylko rekord A rhel-web01).

---
#### Result - Co dzięki temu uzyskałem?
Obie nazwy vhostów (www.linux.lab.local i app.linux.lab.local) rozwiązują się na 10.10.10.21 przez CNAME → A. DNS gotowy pod konfigurację vhostów Apache w kolejnych krokach.

---
#### Lesson Learned - Co się nauczyłem?
CNAME to alias wskazujący na inną nazwę DNS (nie na IP). Dig z flagą `+short` zwraca dwa wyniki dla CNAME: najpierw nazwę kanoniczną (rhel-web01.linux.lab.local.), potem IP z rekordu A — co potwierdza dwuetapowe rozwiązywanie. CNAME jest wygodniejszy niż osobne rekordy A, bo przy zmianie IP wystarczy zmienić jeden rekord A.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
Brak problemów w tym kroku.

---

### 4.2 ✅ — Configure default virtual host with HTTP → HTTPS redirect

Create `/etc/httpd/conf.d/00-default-redirect.conf`:
```apache
<VirtualHost *:80>
    ServerName rhel-web01.linux.lab.local
    RewriteEngine On
    RewriteRule ^(.*)$ https://%{HTTP_HOST}$1 [R=301,L]
</VirtualHost>
```

### Notes

Utworzenie pliku `/etc/httpd/conf.d/00-default-redirect.conf` z konfiguracją vhosta na porcie 80, który przekierowuje cały ruch HTTP na HTTPS.

### Conclusion

#### What - Co zrobiłem?
Utworzenie domyślnego vhosta na porcie 80 (`00-default-redirect.conf`), który przekierowuje wszystkie żądania HTTP na HTTPS za pomocą `mod_rewrite` z kodem 301 (permanent redirect).

---
#### Why - Dlaczego to zrobiłem?
W docelowej konfiguracji cały ruch powinien iść przez HTTPS. Vhost na porcie 80 nie serwuje żadnej treści — tylko przekierowuje na port 443. Prefix `00-` w nazwie pliku zapewnia, że Apache załaduje ten vhost jako pierwszy (pliki z `conf.d/` są ładowane alfabetycznie).

---
#### Result - Co dzięki temu uzyskałem?
Każde żądanie HTTP (port 80) będzie automatycznie przekierowane na HTTPS. Jeszcze nie można tego przetestować w pełni — vhosty HTTPS zostaną skonfigurowane w kolejnych krokach.

---
#### Lesson Learned - Co się nauczyłem?
`RewriteRule ^(.*)$ https://%{HTTP_HOST}$1 [R=301,L]` — przechwytuje cały URI (`^(.*)$`), przekierowuje na ten sam host i ścieżkę, ale z protokołem HTTPS. `%{HTTP_HOST}` zachowuje oryginalną nazwę hosta z żądania klienta. Flaga `R=301` to permanent redirect (przeglądarka zapamięta), `L` oznacza ostatnią regułę (nie przetwarzaj dalszych).

---
#### Problem solved - Jakie problemy zostały rozwiązane?
Brak problemów w tym kroku.

---

### 4.3 ✅ — Configure static site virtual host (www.linux.lab.local)

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

Utworzenie katalogu `/var/www/www-site` z plikiem `index.html` oraz konfiguracji vhosta HTTPS w `/etc/httpd/conf.d/www.linux.lab.local.conf`. Vhost nasłuchuje na porcie 443, używa certyfikatu z kroku 3.2.

### Conclusion

#### What - Co zrobiłem?
Utworzenie document root `/var/www/www-site` z przykładową stroną HTML. Konfiguracja vhosta HTTPS dla `www.linux.lab.local` z włączonym SSLEngine i certyfikatem serwerowym.

---
#### Why - Dlaczego to zrobiłem?
To pierwszy z dwóch docelowych vhostów — statyczna strona serwowana przez HTTPS. Apache rozróżnia vhosty po nagłówku `Host:` w żądaniu, więc każdy vhost potrzebuje osobnej konfiguracji z `ServerName`.

---
#### Result - Co dzięki temu uzyskałem?
Vhost skonfigurowany, ale jeszcze nie przetestowany (Apache nie został przeładowany, firewall nie otwarty). Po przeładowaniu Apache `https://www.linux.lab.local` powinno serwować stronę statyczną.

---
#### Lesson Learned - Co się nauczyłem?
`SSLEngine on` włącza obsługę TLS dla danego vhosta. `SSLCertificateFile` i `SSLCertificateKeyFile` wskazują na certyfikat i klucz z kroku 3.2. Dyrektywa `<Directory>` z `Require all granted` jawnie zezwala na dostęp do document root — bez tego Apache domyślnie odmawia dostępu (deny by default). Vhost na `*:443` oznacza nasłuchiwanie na wszystkich interfejsach na porcie 443.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
Brak problemów w tym kroku.

---

### 4.4 ✅ — Configure reverse proxy virtual host (app.linux.lab.local)

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

Utworzenie backendu Python na porcie 8080, serwisu systemd `backend-app` i vhosta reverse proxy dla `app.linux.lab.local`. Backend odpowiada poprawnie, konfiguracja Apache przeszła walidację.

Weryfikacja backendu:
```
curl http://127.0.0.1:8080
<h1>Backend App</h1><p>Response from backend on port 8080</p>
```

Walidacja Apache:
```
httpd -t
Syntax OK
```

### Conclusion

#### What - Co zrobiłem?
Utworzenie prostej aplikacji backendowej w Pythonie (`/opt/backend-app/app.py`) nasłuchującej na `127.0.0.1:8080`, serwisu systemd `backend-app.service` z autorestartem, oraz vhosta HTTPS reverse proxy (`app.linux.lab.local.conf`). Zwalidowałem konfigurację Apache (`httpd -t`) i przeładowałem serwis.

---
#### Why - Dlaczego to zrobiłem?
Drugi docelowy vhost — reverse proxy demonstruje scenariusz, w którym Apache terminuje TLS i przekazuje ruch do backendu HTTP na localhost. To typowy pattern produkcyjny (np. Apache/Nginx przed aplikacją Node.js, Python, Java).

---
#### Result - Co dzięki temu uzyskałem?
Backend działa na porcie 8080, vhost reverse proxy skonfigurowany. Apache jeszcze nie może się połączyć z backendem przez proxy — SELinux blokuje połączenia sieciowe httpd (boolean `httpd_can_network_connect` domyślnie wyłączony). To zostanie naprawione w Step 5.

---
#### Lesson Learned - Co się nauczyłem?
`ProxyPass / http://127.0.0.1:8080/` — przekazuje wszystkie żądania do backendu. `ProxyPassReverse` modyfikuje nagłówki odpowiedzi (Location, Content-Location) żeby klient widział oryginalny URL, nie backendowy. `ProxyPreserveHost On` przekazuje oryginalny nagłówek `Host:` do backendu zamiast `127.0.0.1`. Backend nasłuchuje tylko na `127.0.0.1` (nie `0.0.0.0`) — nie jest dostępny bezpośrednio z zewnątrz, tylko przez Apache proxy. `httpd -t` sprawdza składnię konfiguracji bez restartowania serwisu — warto używać przed każdym reloadem.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
Brak problemów w tym kroku.

---

## Step 5 — Configure SELinux contexts and booleans for each virtual host type

### 5.1 ✅ — Verify and set SELinux contexts on document roots

Install `semanage` tool (not included in minimal install):
```bash
dnf install -y policycoreutils-python-utils
```

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

Zainstalowałem `policycoreutils-python-utils` (pakiet z `semanage`). Sprawdziłem konteksty SELinux na obu katalogach.

`/var/www/www-site/` — kontekst już poprawny (`httpd_sys_content_t`), bo `/var/www/` jest domyślnie oznaczony tą etykietą w polityce SELinux:
```
ls -lZ /var/www/www-site/
-rw-r--r--. 1 root root unconfined_u:object_r:httpd_sys_content_t:s0 166 Apr  1 15:30 index.html
```

`/opt/backend-app/` — kontekst był `usr_t` (domyślny dla `/opt/`), więc Apache nie miałby dostępu. Ręcznie ustawiłem kontekst:
```
semanage fcontext -a -t httpd_sys_content_t "/opt/backend-app(/.*)?"      
restorecon -Rv /opt/backend-app/
Relabeled /opt/backend-app from unconfined_u:object_r:usr_t:s0 to unconfined_u:object_r:httpd_sys_content_t:s0
Relabeled /opt/backend-app/app.py from unconfined_u:object_r:usr_t:s0 to unconfined_u:object_r:httpd_sys_content_t:s0
```

Po zmianie weryfikacja potwierdziła poprawny kontekst `httpd_sys_content_t` na obu katalogach.

### Conclusion

#### What - Co zrobiłem?
Zainstalowałem `policycoreutils-python-utils` (semanage). Sprawdziłem konteksty SELinux — `/var/www/www-site/` miał już poprawny kontekst `httpd_sys_content_t`, natomiast `/opt/backend-app/` miał `usr_t`. Ustawiłem kontekst `httpd_sys_content_t` na `/opt/backend-app/` przez `semanage fcontext` + `restorecon`.

---
#### Why - Dlaczego to zrobiłem?
SELinux w trybie enforcing kontroluje, do których plików proces httpd ma dostęp. Bez poprawnego kontekstu Apache dostałby błąd "Permission denied" mimo poprawnych uprawnień Unix.

---
#### Result - Co dzięki temu uzyskałem?
Oba document rooty mają kontekst `httpd_sys_content_t`. Apache może czytać pliki z obu lokalizacji bez błędów SELinux.

---
#### Lesson Learned - Co się nauczyłem?
Pliki w `/var/www/` automatycznie dostają kontekst `httpd_sys_content_t`, bo ta ścieżka jest zdefiniowana w domyślnej polityce SELinux. Pliki w `/opt/` dostają kontekst `usr_t` — nie jest to kontekst dostępny dla httpd. `semanage fcontext` dodaje regułę trwałą (przetrwa relabel), a `restorecon` stosuje ją na istniejących plikach. Bez `restorecon` reguła by istniała, ale pliki dalej miałyby stary kontekst. Na minimalnej instalacji Rocky Linux 9 `semanage` nie jest dostępny — trzeba doinstalować `policycoreutils-python-utils`.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
Brak komendy `semanage` — rozwiazane przez instalację `policycoreutils-python-utils`. Niepoprawny kontekst SELinux `usr_t` na `/opt/backend-app/` — zmieniony na `httpd_sys_content_t`.

---

### 5.2 ✅ — Enable SELinux booleans for reverse proxy

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

Włączyłem boolean `httpd_can_network_connect` i przetestowałem reverse proxy.

```
getsebool httpd_can_network_connect
httpd_can_network_connect --> off

setsebool -P httpd_can_network_connect 1

getsebool httpd_can_network_connect
httpd_can_network_connect --> on
```

Test reverse proxy z SELinux enforcing:
```
curl -sk https://app.linux.lab.local
<h1>Backend App</h1><p>Response from backend on port 8080</p>
```

Reverse proxy działa — Apache przekazuje ruch do backendu na porcie 8080.

### Conclusion

#### What - Co zrobiłem?
Włączyłem boolean SELinux `httpd_can_network_connect` (trwale, flaga `-P`). Zweryfikowałem, że reverse proxy działa — `curl -sk https://app.linux.lab.local` zwraca odpowiedź z backendu.

---
#### Why - Dlaczego to zrobiłem?
Domyślnie SELinux zabrania procesowi httpd nawiązywania połączeń sieciowych (nawet do localhost). Bez tego booleanu Apache proxy dostałby błąd przy próbie połączenia z backendem na porcie 8080.

---
#### Result - Co dzięki temu uzyskałem?
Reverse proxy działa z SELinux enforcing. Apache może łączyć się z backendem na localhost:8080. Ustawienie jest trwałe (przetrwa restart).

---
#### Lesson Learned - Co się nauczyłem?
SELinux booleany to przełączniki włączające/wyłączające konkretne uprawnienia dla domen (np. httpd). `getsebool` sprawdza stan, `setsebool -P` ustawia trwale (zapisuje do polityki). Bez flagi `-P` zmiana obowiązuje tylko do restartu. `httpd_can_network_connect` jest potrzebny zawsze gdy Apache działa jako reverse proxy lub łączy się z backendem po sieci.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
SELinux blokował połączenia sieciowe httpd — włączenie `httpd_can_network_connect` odblokowało reverse proxy.

---

### 5.3 ✅ — Verify SELinux audit log for denials

```bash
ausearch -m avc -ts recent
sealert -a /var/log/audit/audit.log 2>/dev/null | head -50
```

### Notes

Sprawdziłem audit log SELinux — brak odrzuceń (AVC denials).

```
ausearch -m avc -ts recent
<no matches>

sealert -a /var/log/audit/audit.log 2>/dev/null | head -50
(brak wyników)
```

Oznacza to, że konteksty i booleany zostały ustawione poprawnie przed uruchomieniem usług — SELinux nie zablokował żadnej operacji.

### Conclusion

#### What - Co zrobiłem?
Sprawdziłem audit log SELinux komendami `ausearch` (szuka wiadomości AVC) i `sealert` (analizuje logi i sugeruje rozwiązania). Brak odrzuceń.

---
#### Why - Dlaczego to zrobiłem?
Weryfikacja, że SELinux nie blokuje żadnych operacji Apache. Nawet jeśli strona działa, mogą być ciche deny w logu, które objawią się później w nietypowych scenariuszach.

---
#### Result - Co dzięki temu uzyskałem?
Czysty audit log — potwierdzenie, że cała konfiguracja SELinux (konteksty z 5.1 i boolean z 5.2) jest poprawna.

---
#### Lesson Learned - Co się nauczyłem?
`ausearch -m avc -ts recent` szuka odrzuceń SELinux z ostatnich 10 minut. `sealert` daje bardziej czytelne wyjaśnienia z sugestiami naprawy (np. który boolean włączyć lub jaki kontekst ustawić). Warto sprawdzać audit log nawet jeśli wszystko pozornie działa — SELinux może blokować operacje, które nie są od razu widoczne (np. zapis logów, dostęp do niestandardowych ścieżek).

---
#### Problem solved - Jakie problemy zostały rozwiązane?
Brak problemów — audit log czysty, konfiguracja SELinux poprawna.

---

## Step 6 — Open required firewall ports

### 6.1 ✅ — Install and configure firewalld

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

Zainstalowałem i włączyłem firewalld, dodałem serwisy HTTP i HTTPS. Zweryfikowałem z rhel-srv01 i z Windowsa (stacja management) — strony działają.

Weryfikacja z rhel-srv01:
```
curl -k https://10.10.10.21
<h1>Backend App</h1><p>Response from backend on port 8080</p>

curl -k https://www.linux.lab.local
<!DOCTYPE html>
<html><head><title>Linux Lab — Static Site</title></head>
<body><h1>www.linux.lab.local</h1><p>LAB-02 static site on Apache/RHEL</p></body>
</html>
```

Z Windowsa (win-mgmt01) strona również się otwiera.

### Conclusion

#### What - Co zrobiłem?
Zainstalowałem firewalld, włączyłem z autorestartem. Dodałem serwisy `http` i `https` do trwałych reguł firewalla (`--permanent`), przeładowałem reguły. Zweryfikowałem dostępność z rhel-srv01 (curl) i z Windowsa (przeglądarka).

---
#### Why - Dlaczego to zrobiłem?
Do tej pory Apache był dostępny tylko lokalnie (firewall blokował porty 80/443). Otwarcie portów HTTP i HTTPS pozwala innym maszynom w sieci lab na dostęp do vhostów.

---
#### Result - Co dzięki temu uzyskałem?
rhel-web01 jest teraz dostępny z całej sieci lab na portach 80 (redirect) i 443 (HTTPS). Oba vhosty działają: `www.linux.lab.local` serwuje stronę statyczną, `https://10.10.10.21` (default vhost) trafia na reverse proxy (backend app). Weryfikacja cross-platform (Linux + Windows) potwierdzona.

---
#### Lesson Learned - Co się nauczyłem?
`firewall-cmd --permanent` dodaje reguły trwałe (przetrwają restart), ale nie stosuje ich od razu — potrzebny jest `--reload`. Bez `--permanent` reguła działa natychmiast, ale ginie po restarcie. Firewalld operuje na serwisach (http, https) zamiast na numerach portów — jest to wygodniejsze i bardziej czytelne. `curl -k` pomija weryfikację certyfikatu TLS (self-signed CA nie jest zaufany domyślnie).

---
#### Problem solved - Jakie problemy zostały rozwiązane?
Brak dostępu do Apache z zewnątrz — rozwiazane przez otwarcie portów HTTP/HTTPS w firewalld.

---

## Step 7 — Apply server hardening

### 7.1 ✅ — Suppress version disclosure

Before (check current state):
```bash
curl -sI http://localhost | grep Server
```

Apply hardening — create `/etc/httpd/conf.d/security-hardening.conf`:
```apache
ServerTokens Prod
ServerSignature Off
```

```bash
httpd -t
systemctl reload httpd
```

After (verify change):
```bash
curl -sI http://localhost | grep Server
```

### Notes

Before:
```
curl -sI http://localhost | grep Server
Server: Apache/2.4.62 (Rocky Linux) OpenSSL/3.5.1
```

After:
```
curl -sI http://localhost | grep Server
Server: Apache
```

Zmiana: zniknęła wersja Apache (2.4.62), nazwa dystrybucji (Rocky Linux) i wersja OpenSSL (3.5.1). Atakujący nie może teraz łatwo zidentyfikować dokładnej wersji serwera.

### Conclusion

#### What - Co zrobiłem?
Utworzenie `/etc/httpd/conf.d/security-hardening.conf` z dyrektywami `ServerTokens Prod` i `ServerSignature Off`.

---
#### Why - Dlaczego to zrobiłem?
Domyślnie Apache ujawnia pełną wersję serwera, system operacyjny i moduły w nagłówku `Server:`. To ułatwia atakującemu szukanie znanych podatności (CVE) dla konkretnej wersji.

---
#### Result - Co dzięki temu uzyskałem?
Nagłówek `Server:` zmienił się z `Apache/2.4.62 (Rocky Linux) OpenSSL/3.5.1` na `Apache`. Minimalne ujawnienie informacji.

---
#### Lesson Learned - Co się nauczyłem?
`ServerTokens Prod` — nagłówek Server pokazuje tylko nazwę "Apache" (bez wersji). Inne opcje: `Full` (domyślna, pokazuje wszystko), `OS` (+ system), `Minor` (+ minor version), `Major` (+ major version), `Min` (alias Minor). `ServerSignature Off` — ukrywa informacje o serwerze na stronach błędów (np. 404, 403). To nie jest prawdziwe zabezpieczenie (security through obscurity), ale utrudnia rekonesans.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
Brak problemów w tym kroku.

---

### 7.2 ✅ — Add security response headers

Before (check current headers):
```bash
curl -skI https://www.linux.lab.local | grep -E "^(X-|Strict|Content-Security|Referrer)"
```

Apply hardening — add to `/etc/httpd/conf.d/security-hardening.conf`:
```apache
Header always set X-Content-Type-Options "nosniff"
Header always set X-Frame-Options "SAMEORIGIN"
Header always set X-XSS-Protection "1; mode=block"
Header always set Referrer-Policy "strict-origin-when-cross-origin"
Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains"
Header always set Content-Security-Policy "default-src 'self'"
```

```bash
httpd -M | grep headers
httpd -t
systemctl reload httpd
```

After (verify change):
```bash
curl -skI https://www.linux.lab.local | grep -E "^(X-|Strict|Content-Security|Referrer)"
```

### Notes

Before:
```
curl -skI https://www.linux.lab.local | grep -E "^(X-|Strict|Content-Security|Referrer)"
(brak wyników — żadne security headers nie były ustawione)
```

Moduł `headers_module` był już załadowany (pochodzi z `mod_ssl`).

After:
```
curl -skI https://www.linux.lab.local | grep -E "^(X-|Strict|Content-Security|Referrer)"
X-Content-Type-Options: nosniff
X-Frame-Options: SAMEORIGIN
X-XSS-Protection: 1; mode=block
Referrer-Policy: strict-origin-when-cross-origin
Strict-Transport-Security: max-age=31536000; includeSubDomains
Content-Security-Policy: default-src 'self'
```

Zmiana: z zera headerów bezpieczeństwa do pełnego zestawu 6 nagłówków.

### Conclusion

#### What - Co zrobiłem?
Dodałem 6 security headers do `/etc/httpd/conf.d/security-hardening.conf`. Zweryfikowałem, że moduł `headers_module` jest załadowany, walidacja składni OK, przeładowałem Apache.

---
#### Why - Dlaczego to zrobiłem?
Security headers instruują przeglądarkę klienta, jak ma się zachować — chronią przed typowymi atakami webowymi (XSS, clickjacking, MIME sniffing, downgrade HTTPS).

---
#### Result - Co dzięki temu uzyskałem?
Wszystkie 6 headerów jest zwracanych w odpowiedziach HTTPS. Przeglądarki klientów będą stosować dodatkowe zabezpieczenia.

---
#### Lesson Learned - Co się nauczyłem?
Każdy header pełni inną rolę:
- `X-Content-Type-Options: nosniff` — przeglądarka nie będzie zgadywać typu MIME (zapobiega atakom MIME sniffing)
- `X-Frame-Options: SAMEORIGIN` — strona może być osadzona w iframe tylko z tej samej domeny (ochrona przed clickjacking)
- `X-XSS-Protection: 1; mode=block` — wbudowany filtr XSS przeglądarki (starsze przeglądarki)
- `Referrer-Policy: strict-origin-when-cross-origin` — ogranicza informacje o stronie źródłowej w nagłówku Referer
- `Strict-Transport-Security` (HSTS) — przeglądarka zapamiętuje na rok, że ta strona działa tylko po HTTPS (zapobiega downgrade do HTTP)
- `Content-Security-Policy: default-src 'self'` — pozwala ładować zasoby tylko z tej samej domeny (ochrona przed XSS przez wstrzyknięcie zewnętrznych skryptów)

`Header always set` oznacza, że header jest dodawany do każdej odpowiedzi (w tym błędów). Bez `always` headery nie byłyby dodawane do odpowiedzi z kodem 4xx/5xx.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
Brak problemów w tym kroku.

---

### 7.3 ✅ — Restrict HTTP methods

Before (check current behavior):
```bash
curl -sk -X TRACE https://www.linux.lab.local
curl -sk -X DELETE https://www.linux.lab.local
curl -sk https://www.linux.lab.local
```

Apply hardening — add to `/etc/httpd/conf.d/security-hardening.conf`:
```apache
<Directory />
    <LimitExcept GET POST HEAD>
        Require all denied
    </LimitExcept>
</Directory>
TraceEnable Off
```

```bash
httpd -t
systemctl reload httpd
```

After (verify change):
```bash
curl -sk -X TRACE https://www.linux.lab.local
curl -sk -X DELETE https://www.linux.lab.local
curl -sk https://www.linux.lab.local
```

### Notes

Before:
```
curl -sk -X TRACE https://www.linux.lab.local
TRACE / HTTP/1.1
Host: www.linux.lab.local
User-Agent: curl/7.76.1
Accept: */*

curl -sk -X DELETE https://www.linux.lab.local
405 Method Not Allowed

curl -sk https://www.linux.lab.local
(strona wyświetla się poprawnie)
```

Po dodaniu `<LimitExcept>` wynik był identyczny — TRACE nadal działał. Dopiero po dodaniu `TraceEnable Off` TRACE został zablokowany.

After:
```
curl -sk -X TRACE https://www.linux.lab.local
405 Method Not Allowed (The requested method TRACE is not allowed for this URL.)

curl -sk -X DELETE https://www.linux.lab.local
405 Method Not Allowed

curl -sk https://www.linux.lab.local
(strona wyświetla się poprawnie)
```

Zmiana: TRACE zablokowany (wcześniej zwracał echo requestu). DELETE był już blokowany domyślnie. GET działa bez zmian.

### Conclusion

#### What - Co zrobiłem?
Dodałem `<LimitExcept GET POST HEAD>` do ograniczenia dozwolonych metod HTTP oraz `TraceEnable Off` do zablokowania metody TRACE.

---
#### Why - Dlaczego to zrobiłem?
Metoda TRACE może być wykorzystana do ataków Cross-Site Tracing (XST) — atakujący może odczytać nagłówki żądania (w tym cookies HttpOnly) przez TRACE echo. Ograniczenie metod do GET/POST/HEAD zmniejsza powierzchnię ataku.

---
#### Result - Co dzięki temu uzyskałem?
TRACE zwraca 405 zamiast echo requestu. Tylko metody GET, POST i HEAD są dozwolone.

---
#### Lesson Learned - Co się nauczyłem?
`<LimitExcept>` w `<Directory>` nie blokuje TRACE — TRACE jest obsługiwany na poziomie serwera, zanim Apache przetworzy dyrektywy katalogowe. Do zablokowania TRACE potrzebna jest osobna dyrektywa `TraceEnable Off` na poziomie serwera. To ważna lekcja: nie każda metoda HTTP jest obsługiwana na tym samym poziomie w Apache — trzeba znać różnicę między dyrektywami serwerowymi a katalogowymi.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
`<LimitExcept>` nie blokowało TRACE — rozwiązane przez dodanie `TraceEnable Off`.

---

## Step 8 — Test all virtual hosts, verify TLS, SELinux, and hardening

### 8.1 ✅ — Test default HTTP → HTTPS redirect

On **rhel-srv01** (test z innego hosta w sieci lab):
```bash
curl -sI http://rhel-web01.linux.lab.local | head -5
```

### Notes

```
curl -sI http://rhel-web01.linux.lab.local | head -5
HTTP/1.1 301 Moved Permanently
Date: Wed, 01 Apr 2026 15:30:38 GMT
Server: Apache
X-Content-Type-Options: nosniff
X-Frame-Options: SAMEORIGIN
```

Redirect działa (301). Przy okazji widać, że hardening z Step 7 też działa — `Server: Apache` (bez wersji) i security headers obecne.

### Conclusion

#### What - Co zrobiłem?
Przetestowałem redirect HTTP → HTTPS z rhel-srv01 (inny host w sieci lab).

---
#### Why - Dlaczego to zrobiłem?
Weryfikacja, że vhost `00-default-redirect.conf` poprawnie przekierowuje ruch HTTP na HTTPS.

---
#### Result - Co dzięki temu uzyskałem?
HTTP/1.1 301 Moved Permanently — redirect działa. Dodatkowo widoczne nagłówki hardeningu (Server, X-Content-Type-Options, X-Frame-Options).

---
#### Lesson Learned - Co się nauczyłem?
Kod 301 (Moved Permanently) oznacza trwałe przekierowanie — przeglądarki zapamiętują ten redirect. Security headers są dodawane również do odpowiedzi redirect (dzięki `Header always set`).

---
#### Problem solved - Jakie problemy zostały rozwiązane?
Brak problemów w tym kroku.

---

### 8.2 ✅ — Test static site virtual host

On **rhel-srv01**:
```bash
curl -sk https://www.linux.lab.local
```

### Notes

```
curl -sk https://www.linux.lab.local
<!DOCTYPE html>
<html><head><title>Linux Lab — Static Site</title></head>
<body><h1>www.linux.lab.local</h1><p>LAB-02 static site on Apache/RHEL</p></body>
</html>
```

Strona statyczna serwowana poprawnie przez HTTPS.

### Conclusion

#### What - Co zrobiłem?
Przetestowałem vhost `www.linux.lab.local` z rhel-srv01.

---
#### Why - Dlaczego to zrobiłem?
Weryfikacja, że vhost statycznej strony serwuje poprawnie treść z `/var/www/www-site/` przez HTTPS.

---
#### Result - Co dzięki temu uzyskałem?
Strona HTML wyświetla się poprawnie. TLS, DNS CNAME, DocumentRoot i SELinux — wszystko działa.

---
#### Lesson Learned - Co się nauczyłem?
Brak nowych lekcji — test potwierdza poprawność konfiguracji z wcześniejszych kroków.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
Brak problemów w tym kroku.

---

### 8.3 ✅ — Test reverse proxy virtual host

On **rhel-srv01**:
```bash
curl -sk https://app.linux.lab.local
```

### Notes

```
curl -sk https://app.linux.lab.local
<h1>Backend App</h1><p>Response from backend on port 8080</p>
```

Reverse proxy działa — Apache przekazuje żądanie do backendu na porcie 8080 i zwraca odpowiedź klientowi.

### Conclusion

#### What - Co zrobiłem?
Przetestowałem vhost `app.linux.lab.local` (reverse proxy) z rhel-srv01.

---
#### Why - Dlaczego to zrobiłem?
Weryfikacja, że reverse proxy poprawnie przekazuje ruch do backendu przez SELinux (`httpd_can_network_connect`) i TLS.

---
#### Result - Co dzięki temu uzyskałem?
Backend odpowiada przez reverse proxy. Cały łańcuch działa: DNS CNAME → Apache vhost → ProxyPass → backend:8080.

---
#### Lesson Learned - Co się nauczyłem?
Brak nowych lekcji — test potwierdza poprawność konfiguracji reverse proxy, SELinux boolean i TLS.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
Brak problemów w tym kroku.

---

### 8.4 ✅ — Verify TLS certificate

On **rhel-srv01**:
```bash
openssl s_client -connect www.linux.lab.local:443 -servername www.linux.lab.local < /dev/null 2>/dev/null | openssl x509 -noout -subject -issuer -dates
```

### Notes

```
openssl s_client -connect www.linux.lab.local:443 -servername www.linux.lab.local < /dev/null 2>/dev/null | openssl x509 -noout -subject -issuer -dates
subject=C=PL, ST=Lab, O=Linux Lab, CN=rhel-web01.linux.lab.local
issuer=C=PL, ST=Lab, O=Linux Lab, CN=Linux Lab CA
notBefore=Apr  1 13:16:38 2026 GMT
notAfter=Apr  1 13:16:38 2027 GMT
```

Certyfikat poprawny — wystawiony przez lab CA, ważny 1 rok.

### Conclusion

#### What - Co zrobiłem?
Zweryfikowałem certyfikat TLS serwowany przez Apache z rhel-srv01.

---
#### Why - Dlaczego to zrobiłem?
Potwierdzenie, że Apache serwuje właściwy certyfikat podpisany przez lab CA (nie domyślny self-signed z mod_ssl).

---
#### Result - Co dzięki temu uzyskałem?
Certyfikat: subject `CN=rhel-web01.linux.lab.local`, issuer `CN=Linux Lab CA`, ważność 2026–2027. Potwierdza, że używany jest certyfikat z Step 3 (nie domyślny).

---
#### Lesson Learned - Co się nauczyłem?
`openssl s_client` z flagą `-servername` wysyła SNI (Server Name Indication), dzięki czemu Apache zwraca certyfikat dla konkretnego vhosta. Bez SNI serwer mógłby zwrócić domyślny certyfikat. Issuer różny od subject potwierdza, że to nie jest self-signed — certyfikat jest podpisany przez CA.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
Brak problemów w tym kroku.

---

### 8.5 ✅ — Verify SELinux status and audit log

On **rhel-web01** (SELinux jest lokalny):
```bash
getenforce
getsebool httpd_can_network_connect
ausearch -m avc -ts recent 2>/dev/null | head -20
```

### Notes

```
getenforce
Enforcing

getsebool httpd_can_network_connect
httpd_can_network_connect --> on

ausearch -m avc -ts recent 2>/dev/null | head -20
(brak wyników — brak odrzuceń)
```

SELinux enforcing, boolean włączony, audit log czysty.

### Conclusion

#### What - Co zrobiłem?
Zweryfikowałem stan SELinux na rhel-web01: tryb enforcing, boolean `httpd_can_network_connect` włączony, brak AVC denials.

---
#### Why - Dlaczego to zrobiłem?
Końcowa weryfikacja, że SELinux działa w trybie enforcing i nie blokuje żadnych operacji Apache po wszystkich testach.

---
#### Result - Co dzięki temu uzyskałem?
Potwierdzenie, że cała konfiguracja SELinux (konteksty, booleany) jest poprawna i stabilna.

---
#### Lesson Learned - Co się nauczyłem?
Brak nowych lekcji — test potwierdza poprawność konfiguracji z Step 5.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
Brak problemów w tym kroku.

---

### 8.6 ✅ — Verify hardening and cross-platform access

On **rhel-srv01** (test z innego hosta Linux):
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

**rhel-srv01 (Linux):**
```
curl -skI https://www.linux.lab.local | grep Server
Server: Apache

curl -skI https://www.linux.lab.local | grep -E "^(X-|Strict|Content-Security|Referrer)"
X-Content-Type-Options: nosniff
X-Frame-Options: SAMEORIGIN
X-XSS-Protection: 1; mode=block
Referrer-Policy: strict-origin-when-cross-origin
Strict-Transport-Security: max-age=31536000; includeSubDomains
Content-Security-Policy: default-src 'self'

curl -sk -X TRACE https://www.linux.lab.local
405 Method Not Allowed
```

Hardening działa z innego hosta: wersja ukryta, 6 security headers, TRACE zablokowany.

**win-mgmt01 (PowerShell):**
```
Resolve-DnsName www.linux.lab.local
www.linux.lab.local  CNAME  rhel-web01.linux.lab.local
rhel-web01.linux.lab.local  A  10.10.10.21

Resolve-DnsName app.linux.lab.local
app.linux.lab.local  CNAME  rhel-web01.linux.lab.local
rhel-web01.linux.lab.local  A  10.10.10.21

Invoke-WebRequest -Uri https://www.linux.lab.local -SkipCertificateCheck | Select-Object StatusCode
StatusCode: 200

Invoke-WebRequest -Uri https://app.linux.lab.local -SkipCertificateCheck | Select-Object StatusCode
StatusCode: 200
```

DNS CNAME rozwiazuje się poprawnie z Windowsa. Oba vhosty zwracają 200 OK.

### Conclusion

#### What - Co zrobiłem?
Przetestowałem hardening z rhel-srv01 (Linux) i dostępność cross-platform z win-mgmt01 (Windows PowerShell). Sprawdziłem DNS CNAME, HTTP 200 na obu vhostach, ukrytą wersję serwera, security headers i zablokowany TRACE.

---
#### Why - Dlaczego to zrobiłem?
Końcowa weryfikacja, że cała konfiguracja (hardening, TLS, vhosty) działa poprawnie z różnych platform i hostów w sieci lab.

---
#### Result - Co dzięki temu uzyskałem?
Wszystko działa cross-platform: Linux (curl) i Windows (PowerShell/przeglądarka). Hardening widoczny z zewnątrz. DNS CNAME rozwiązuje się poprawnie z obu platform.

---
#### Lesson Learned - Co się nauczyłem?
`Invoke-WebRequest -SkipCertificateCheck` w PowerShell jest odpowiednikiem `curl -k` — pomija weryfikację certyfikatu self-signed CA. `Resolve-DnsName` to odpowiednik `dig` w Windows. Testowanie z różnych platform (Linux + Windows) jest ważne, bo konfiguracja DNS i firewall może zachowywać się inaczej w zależności od klienta.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
Brak problemów w tym kroku.

---

## LAB-02 — Conclusion

### What - Co zrobiłem?
Postawiłem maszynę rhel-web01 (Rocky Linux 9, full VM) z Apache HTTP Server i pełną konfiguracją produkcyjną: sieć statyczna, DNS (rekordy A, PTR, CNAME w BIND), self-signed CA z certyfikatem TLS (SAN dla 3 hostnames), 3 virtual hosty (default redirect HTTP→HTTPS, strona statyczna www.linux.lab.local, reverse proxy app.linux.lab.local), SELinux enforcing z poprawnymi kontekstami i booleanami, firewall (HTTP/HTTPS), hardening (ukrycie wersji, security headers, blokada TRACE). Przetestowałem cross-platform (Linux curl + Windows PowerShell).

---
### Why - Dlaczego to zrobiłem?
Ćwiczenie praktyczne z konfiguracji serwera webowego w środowisku enterprise Linux z pełnym stosem bezpieczeństwa: TLS, SELinux, firewall, hardening. Przygotowanie infrastruktury webowej w sieci lab, gotowej do wykorzystania w kolejnych ćwiczeniach.

---
### Result - Co dzięki temu uzyskałem?
Działający serwer Apache na rhel-web01 (10.10.10.21) dostępny z całej sieci lab. Trzy vhosty: redirect HTTP→HTTPS (port 80→443), strona statyczna (www.linux.lab.local), reverse proxy do backendu Python (app.linux.lab.local). SELinux enforcing, firewall aktywny, hardening zastosowany. Weryfikacja cross-platform potwierdzona.

---
#### Lesson Learned - Co się nauczyłem?

**Sieć i DNS:**
- **`nmtui` vs `nmcli`** — oba modyfikują te same profile NetworkManager. DNS search domains pozwalają używać krótkich nazw hostów.
- **CNAME** — alias wskazujący na inną nazwę kanoniczną, nie na IP. Po każdej zmianie zone file trzeba inkrementować serial SOA i przeładować `named`.

**TLS/PKI:**
- **Self-signed CA** — subject == issuer. Klucz CA (4096-bit) jest dłuższy niż klucze serwerowe (2048-bit) ze względu na wyższe ryzyko kompromitacji.
- **Flaga `-x509`** w `openssl req` pomija CSR i tworzy gotowy certyfikat — tylko dla CA.
- **SAN (Subject Alternative Name)** jest wymagany przez nowoczesne przeglądarki — sam CN nie wystarczy. Rozszerzenia SAN trzeba przekazać przez `-extfile` przy podpisywaniu.

**Apache:**
- **`systemctl enable --now`** uruchamia i włącza autostart jednocześnie.
- **`VirtualHost :443`** wymaga `SSLEngine on` + ścieżki do certyfikatu i klucza.
- **`RewriteEngine` + `RewriteRule`** obsługuje redirect HTTP→HTTPS.
- **Reverse proxy** — `ProxyPass` przekazuje żądania do backendu, `ProxyPassReverse` modyfikuje nagłówki odpowiedzi, `ProxyPreserveHost` zachowuje oryginalny Host header.
- **`httpd -t`** sprawdza składnię bez restartu — warto używać przed każdym reload.

**SELinux:**
- **Konteksty plików** — `/var/www/` automatycznie dostaje `httpd_sys_content_t`, `/opt/` dostaje `usr_t`. Zmiana przez `semanage fcontext` + `restorecon`. Bez `restorecon` reguła istnieje, ale pliki mają stary kontekst.
- **Boolean `httpd_can_network_connect`** jest wymagany dla reverse proxy. `setsebool -P` ustawia trwale (przetrwa restart).
- **Narzędzia** — na minimalnej instalacji `semanage` wymaga `policycoreutils-python-utils`. `ausearch -m avc` i `sealert` służą do diagnostyki odrzuceń.

**Firewall:**
- **`firewall-cmd --permanent`** dodaje reguły trwałe, ale nie stosuje od razu — potrzebny `--reload`. Firewalld operuje na serwisach (`http`, `https`) zamiast na numerach portów.

**Hardening:**
- **`ServerTokens Prod`** ukrywa wersję w nagłówku Server. **`ServerSignature Off`** ukrywa info na stronach błędów.
- **`Header always set`** dodaje headery do wszystkich odpowiedzi (w tym 4xx/5xx). Bez `always` headery nie trafiają do odpowiedzi z kodem 4xx/5xx.
- **`LimitExcept`** w `Directory` nie blokuje TRACE — TRACE jest obsługiwany na poziomie serwera, potrzebny `TraceEnable Off`.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
- **Niespójność w planie** (krok 1.4/1.5) — `bind-utils` potrzebny w 1.4, ale zaplanowany do instalacji w 1.5. Rozwiązanie: przeniesienie instalacji przed krok 1.4
- **Brak komendy `semanage`** (krok 5.1) — niedostępna na minimalnej instalacji Rocky Linux 9. Rozwiązanie: `dnf install policycoreutils-python-utils`
- **Niepoprawny kontekst SELinux** (krok 5.1) — `usr_t` na `/opt/backend-app/` zamiast `httpd_sys_content_t`. Rozwiązanie: `semanage fcontext` + `restorecon`
- **SELinux blokował reverse proxy** (krok 5.2) — boolean `httpd_can_network_connect` domyślnie wyłączony. Rozwiązanie: `setsebool -P httpd_can_network_connect 1`
- **Brak dostępu do Apache z zewnątrz** (krok 6.1) — firewall blokował porty 80/443. Rozwiązanie: otwarcie serwisów `http`/`https` w firewalld
- **`LimitExcept` nie blokowało TRACE** (krok 7.3) — TRACE obsługiwany na poziomie serwera, nie katalogu. Rozwiązanie: dodanie `TraceEnable Off`
