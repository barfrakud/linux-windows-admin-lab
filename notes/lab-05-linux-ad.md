# LAB-05: Linux-AD integration with SSSD/realmd

**Status:** In progress
**Machine:** rhel-web01, ubuntu-ws02 (clients); win-dc01 (AD DC/DNS); win-mgmt01 (management); rhel-srv01 (Linux DNS, infra from LAB-01)
**Reference:** [lab-plan.md — LAB-05](../lab-plan.md)

### Lab context

```text
AD domain:        lab.local
Linux DNS zone:   linux.lab.local
AD DC / DNS:      win-dc01    (10.10.10.10)
Management host:  win-mgmt01  (10.10.10.11)
Linux DNS (BIND): rhel-srv01  (10.10.10.20) 
RHEL client:      rhel-web01  (10.10.10.21)
Ubuntu client:    ubuntu-ws02 (10.10.10.31)
Prerequisite:     rhel-srv01 powered on with BIND serving linux.lab.local and forwarding lab.local to 10.10.10.10
                  rhel-web01 prepared as a full VM and restored to a pre-LAB-05 state
                  ubuntu-ws02 prepared as a full VM for its first LAB-05 run
                  Proxmox snapshots taken before starting
DNS path:         Linux clients -> rhel-srv01 BIND (10.10.10.20) -> conditional forward to AD DNS for lab.local
```

**End state after this lab:**
- rhel-web01 joined to `lab.local` via `realmd` + SSSD
- ubuntu-ws02 joined to `lab.local` via `realmd` + SSSD
- login access restricted to dedicated AD groups
- automatic home directory creation enabled on both hosts
- dedicated OU and GPO prepared for Linux systems
- `centrify-vs-sssd.md` written as final comparison document

---

## Step 1 — Verify DNS and time synchronisation prerequisites on rhel-web01; install AD integration packages (`realmd`, `sssd`, `adcli`, `samba-common`, `oddjob-mkhomedir`, `authselect`)

### 1.1 — Confirm resolver path and `lab.local` discovery on rhel-web01

Run the following commands and verify that `lab.local` resolves through the DNS path prepared in LAB-01.

```bash
cat /etc/resolv.conf
nmcli dev show | grep -E 'IP4.DNS|IP4.DOMAIN|GENERAL.CONNECTION'
getent hosts win-dc01.lab.local
getent hosts win-mgmt01.lab.local
getent hosts rhel-web01.linux.lab.local
getent hosts rhel-srv01.linux.lab.local
```

If DNS looks suspicious, first confirm that the resolver points to `10.10.10.20` (`rhel-srv01`) instead of directly to the AD DNS server. The LAB-05 clients should use the DNS path prepared in LAB-01 through the existing BIND server on `rhel-srv01`.

On a freshly provisioned Rocky/RHEL 9 VM the active NetworkManager connection is typically named after the interface (e.g. `ens18`), not `System eth0`. Identify it first and use that name in every `nmcli con mod`/`nmcli con up` command below.

```bash
nmcli -t -f NAME,DEVICE,STATE con show --active
```

If the resolver points to `10.10.10.10`, if `/etc/resolv.conf` does not use `10.10.10.20`, or if `linux.lab.local` is missing from the search list, fix NetworkManager and retest (substitute your connection name):

```bash
nmcli con mod "ens18" ipv4.dns "10.10.10.20" ipv4.dns-search "linux.lab.local lab.local" ipv4.ignore-auto-dns yes
nmcli con up "ens18"
cat /etc/resolv.conf
getent hosts rhel-web01.linux.lab.local
getent hosts rhel-srv01.linux.lab.local
getent hosts win-dc01.lab.local
getent hosts win-mgmt01.lab.local
```

If `rhel-srv01` is unreachable (ping `Destination Host Unreachable`), it is simply powered off in Proxmox — start the VM and wait for `named` to come up before repeating the tests. LAB-05 cannot proceed without it because it is the only DNS server the Linux clients use.

If `rhel-srv01` responds but `getent hosts rhel-web01.linux.lab.local` or `getent hosts ubuntu-ws02.linux.lab.local` returns nothing, the BIND zone on `rhel-srv01` is missing A records for the LAB-05 clients. Verify directly against BIND:

```bash
dig @10.10.10.20 rhel-web01.linux.lab.local +short
dig @10.10.10.20 ubuntu-ws02.linux.lab.local +short
```

If either returns `NXDOMAIN`, add the records on `rhel-srv01`. Locate the zone file, edit it, bump the SOA serial, and reload:

```bash
# on rhel-srv01
grep -RnE 'zone\s+"linux\.lab\.local"' /etc/named.conf /etc/named/ 2>/dev/null
# typical path: /var/named/linux.lab.local.zone — adjust if yours differs
cat /var/named/linux.lab.local.zone
vi  /var/named/linux.lab.local.zone
#   bump the SOA Serial (e.g. 2024010101 -> 2024010102)
#   add under "; A records":
#     rhel-web01    IN  A  10.10.10.21
#     ubuntu-ws02   IN  A  10.10.10.31
named-checkzone linux.lab.local /var/named/linux.lab.local.zone
systemctl reload named
```

Do not continue to the next sub-step until `rhel-web01.linux.lab.local`, `ubuntu-ws02.linux.lab.local`, `rhel-srv01.linux.lab.local`, `win-dc01.lab.local`, and `win-mgmt01.lab.local` all resolve correctly.

### 1.2 — Verify hostname, FQDN, and time synchronisation on rhel-web01

Confirm that the host identifies itself as `rhel-web01.linux.lab.local` and that time synchronisation is healthy before any Kerberos operation. Use `timedatectl` as the primary pre-join check.

```bash
hostname
hostname -f
hostnamectl
timedatectl
cat /etc/resolv.conf
```

On a freshly provisioned Rocky/RHEL 9 VM the static hostname is often only `rhel-web01`, while `hostname -f` already returns the FQDN via DNS. Both must be `rhel-web01.linux.lab.local` before the AD join. Fix the static hostname and restore the DNS search list if needed (substitute your connection name from Step 1.1, typically `ens18`):

```bash
hostnamectl set-hostname rhel-web01.linux.lab.local
nmcli con mod "ens18" ipv4.dns-search "linux.lab.local lab.local"
nmcli con up "ens18"
hostname
hostname -f
hostnamectl | grep -i 'static hostname'
cat /etc/resolv.conf
```

If `timedatectl` reports `System clock synchronized: no` and `NTP service: n/a`, the `chrony` package is not installed on the freshly provisioned VM. Install it, enable the service, and verify synchronisation:

```bash
rpm -q chrony || dnf install -y chrony
systemctl enable --now chronyd
systemctl status chronyd --no-pager
timedatectl
chronyc sources -v
chronyc tracking
```

Expected after a few seconds: `timedatectl` reports `System clock synchronized: yes` and `NTP service: active`, and `chronyc sources` shows at least one source marked `^*` (current best). If the default public NTP pool is unreachable from the lab network, edit `/etc/chrony.conf` to use the AD DC as the time source (`server 10.10.10.10 iburst`) and restart `chronyd`.

Do not continue if the clock is unsynchronised or if `hostname -f` does not return `rhel-web01.linux.lab.local`.

### 1.3 — Install required packages on rhel-web01

Install the AD integration toolset.

```bash
dnf install -y realmd sssd adcli samba-common-tools oddjob oddjob-mkhomedir authselect krb5-workstation
```

Verify package installation.

```bash
rpm -q realmd sssd adcli samba-common-tools oddjob oddjob-mkhomedir authselect krb5-workstation
```

Result:
```
[root@rhel-web01 ~]# rpm -q realmd sssd adcli samba-common-tools oddjob oddjob-mkhomedir authselect krb5-workstation
realmd-0.17.1-2.el9.x86_64
sssd-2.9.7-4.el9_7.1.x86_64
adcli-0.9.2-1.el9.x86_64
samba-common-tools-4.22.4-18.el9_7.x86_64
oddjob-0.34.7-7.el9.x86_64
oddjob-mkhomedir-0.34.7-7.el9.x86_64
authselect-1.2.6-3.el9.x86_64
krb5-workstation-1.21.1-8.el9_6.x86_64
```

### 1.4 — Verify required commands and supporting services

Verify that the required commands are available and start the helper service used for automatic home directory creation. Use `command -v` to confirm that the binaries are present before moving on.

```bash
command -v realm
command -v sssd
command -v adcli
command -v authselect
command -v kinit
command -v klist
systemctl enable --now oddjobd
systemctl status oddjobd --no-pager
systemctl status dbus --no-pager
```

Run a final readiness test. If `realm discover` fails, return to DNS or time troubleshooting and do not attempt `realm join` yet.

```bash
realm discover lab.local
```

---
### Notes

- Aktywne połączenie NetworkManager na świeżej VM RHEL/Rocky nazywało się `ens18`, nie `System eth0` — wszystkie `nmcli con mod/up` wykonywane z tą nazwą.
- `rhel-srv01` był wyłączony w Proxmox; trzeba go włączyć ręcznie, scenariusz zakłada, że ten host działa przez cały LAB-05 jako jedyny DNS klientów.
- Strefa `linux.lab.local` na `rhel-srv01` z LAB-01 nie zawierała rekordów A dla `rhel-web01` ani `ubuntu-ws02` — dopisałem oba i podbiłem SOA serial przed `rndc reload`.
- Na świeżej VM Rocky 9.7 nie było pakietu `chrony`; `timedatectl` startował z `NTP service: n/a`. Po `dnf install -y chrony` synchronizacja wstała z publicznego poola.
- `hostname -f` zwracał FQDN z DNS, ale `Static hostname` w `hostnamectl` to było samo `rhel-web01` — trzeba było jawnie `hostnamectl set-hostname rhel-web01.linux.lab.local`.

---
### Conclusion

#### What - Co zrobiłem?

- Zweryfikowałem ścieżkę resolvera na `rhel-web01`: `/etc/resolv.conf` i `nmcli` potwierdzają `10.10.10.20` (rhel-srv01) jako jedyny DNS oraz `linux.lab.local lab.local` w search list.
- Uruchomiłem `rhel-srv01` i naprawiłem strefę `linux.lab.local` w BIND: dodałem rekordy A dla `rhel-web01` (10.10.10.21) i `ubuntu-ws02` (10.10.10.31), podbiłem SOA serial, przeładowałem `named`.
- Potwierdziłem rozwiązywanie `rhel-web01.linux.lab.local`, `ubuntu-ws02.linux.lab.local`, `rhel-srv01.linux.lab.local`, `win-dc01.lab.local`, `win-mgmt01.lab.local` przez `getent`/`dig @10.10.10.20`.
- Ustawiłem pełny FQDN jako static hostname (`hostnamectl set-hostname rhel-web01.linux.lab.local`).
- Zainstalowałem i uruchomiłem `chrony`; `timedatectl` pokazuje `System clock synchronized: yes`, `NTP service: active`, `chronyc sources` ma aktywne źródło `^* time.taken.pl`.
- Zainstalowałem pełny zestaw pakietów do integracji z AD: `realmd`, `sssd`, `adcli`, `samba-common-tools`, `oddjob`, `oddjob-mkhomedir`, `authselect`, `krb5-workstation` — wszystkie zwraca `rpm -q`.
- Włączyłem `oddjobd`, potwierdziłem `dbus` (jako `dbus-broker`) jako aktywny, wszystkie binaria (`realm`, `sssd`, `adcli`, `authselect`, `kinit`, `klist`) obecne.
- `realm discover lab.local` zwraca `server-software: active-directory`, `client-software: sssd`, `configured: no` — host gotowy do `realm join`.

---
#### Why - Dlaczego to zrobiłem?

Krok 1 to pre-check przed `realm join`. Bez poprawnej ścieżki DNS (przez własny BIND na `rhel-srv01`, z forwardem `lab.local` do AD) `realmd` nie wykryje DC. Bez synchronizacji czasu Kerberos odrzuci bilety (typowa tolerancja 5 minut). Bez pełnego FQDN jako hostname obiekt komputera w AD zostałby utworzony z nieprawidłową nazwą i SPN-ami.

---
#### Result - Co dzięki temu uzyskałem?

- Stabilna ścieżka DNS zgodna z architekturą lab: klient Linux → `rhel-srv01` BIND (autorytatywny dla `linux.lab.local`, forward dla `lab.local` → `10.10.10.10`) → AD DNS.
- Zsynchronizowany zegar i poprawny FQDN — spełnione wszystkie wymagania Kerberosa po stronie klienta.
- Wszystkie pakiety i usługi potrzebne do `realm join` zainstalowane; `realm discover lab.local` potwierdza gotowość.

---
#### Lesson Learned - Co się nauczyłem?

- Na świeżo sklonowanej VM w Rocky/RHEL 9 nie ma gwarancji, że `chrony` jest zainstalowany — `timedatectl` pokaże wtedy `NTP service: n/a`, co jest cichym blokerem dla każdej operacji Kerberos. Trzeba to sprawdzać osobno, nie zakładać, że „NTP jest zawsze domyślnie”.
- `hostname -f` potrafi zwrócić poprawny FQDN wyłącznie z DNS, nawet gdy `hostnamectl` pokazuje krótki static hostname. Do AD join liczy się **static hostname**, nie tylko to, co oddaje resolver.
- Strefy BIND z LAB-01 trzeba rozszerzać przy każdym nowym kliencie; zawsze podbijać SOA serial przed `rndc reload`, bo inaczej slave'y/cache nie zauważą zmiany (BIND ostrzega: `zone serial ... unchanged`).
- Na nowej VM w Proxmox aktywne połączenie NM zwykle nazywa się po interfejsie (`ens18`), a nie `System eth0` — szablonowe polecenia z dokumentacji RHEL trzeba zawsze podstawiać pod realną nazwę z `nmcli con show --active`.

---
#### Problem solved - Jakie problemy zostały rozwiązane?

- `rhel-srv01` niedostępny (Destination Host Unreachable) → włączenie VM w Proxmox.
- `rhel-web01.linux.lab.local` i `ubuntu-ws02.linux.lab.local` zwracały `NXDOMAIN` z BIND → dopisanie rekordów A do strefy `linux.lab.local` na `rhel-srv01`, podbicie serial, reload.
- `System clock synchronized: no`, `NTP service: n/a` → instalacja `chrony` i `systemctl enable --now chronyd`.
- `Static hostname: rhel-web01` zamiast FQDN → `hostnamectl set-hostname rhel-web01.linux.lab.local`.

---
## Step 2 — Discover and join the domain on rhel-web01; verify Kerberos, `realm list`, generated SSSD configuration, and computer object creation

### 2.1 — Run `realm discover` for `lab.local`

This check already succeeded in Step 1. Repeat it here only if DNS, hostname, or time settings changed before the join.

```bash
realm discover lab.local
```

Do not continue if the output no longer shows `server-software: active-directory` and `client-software: sssd`.

### 2.2 — Join `rhel-web01` to the domain

Join the host to the AD domain using an account that has permission to add computers to the domain. In this lab you can use `Administrator` unless you deliberately prepared a delegated join account.

```bash
realm join --verbose lab.local -U Administrator
# The command will prompt for the password interactively. Do not continue if the join fails — go back to DNS, FQDN, or time validation first.
```
Result:
```
[root@rhel-web01 ~]# realm discover lab.local
lab.local
  type: kerberos
  realm-name: LAB.LOCAL
  domain-name: lab.local
  configured: no
  server-software: active-directory
  client-software: sssd
  required-package: oddjob
  required-package: oddjob-mkhomedir
  required-package: sssd
  required-package: adcli
  required-package: samba-common-tools
[root@rhel-web01 ~]# realm join --verbose lab.local -U Administrator
 * Resolving: _ldap._tcp.lab.local
 * Performing LDAP DSE lookup on: 10.10.10.10
 * Successfully discovered: lab.local
Password for Administrator@LAB.LOCAL: 
 * Required files: /usr/sbin/oddjobd, /usr/libexec/oddjob/mkhomedir, /usr/sbin/sssd, /usr/sbin/adcli
 * LANG=C /usr/sbin/adcli join --verbose --domain lab.local --domain-realm LAB.LOCAL --domain-controller 10.10.10.10 --login-type user --login-ccache=/var/cache/realmd/realm-ad-kerberos-12U9N3
 * Using domain name: lab.local
 * Calculated computer account name from fqdn: RHEL-WEB01
 * Using domain realm: lab.local
 * Sending NetLogon ping to domain controller: 10.10.10.10
 * Received NetLogon info from: win-dc01.lab.local
 * Wrote out krb5.conf snippet to /var/cache/realmd/adcli-krb5-hsr2Pp/krb5.d/adcli-krb5-conf-kCGYA2
 * Using GSS-SPNEGO for SASL bind
 * Looked up short domain name: LAB
 * Looked up domain SID: S-1-5-21-1657246285-1208839130-1596478242
 * Received NetLogon info from: win-dc01.lab.local
 * Using fully qualified name: rhel-web01.linux.lab.local
 * Using domain name: lab.local
 * Using computer account name: RHEL-WEB01
 * Using domain realm: lab.local
 * Calculated computer account name from fqdn: RHEL-WEB01
 * Generated 120 character computer password
 * Using keytab: FILE:/etc/krb5.keytab
 * A computer account for RHEL-WEB01$ does not exist
 * Found well known computer container at: CN=Computers,DC=lab,DC=local
 * Calculated computer account: CN=RHEL-WEB01,CN=Computers,DC=lab,DC=local
 * Encryption type [16] not permitted.
 * Encryption type [23] not permitted.
 * Encryption type [3] not permitted.
 * Encryption type [1] not permitted.
 * Created computer account: CN=RHEL-WEB01,CN=Computers,DC=lab,DC=local
 * Trying to set computer password with Kerberos
 * Set computer password
 * Retrieved kvno '2' for computer account in directory: CN=RHEL-WEB01,CN=Computers,DC=lab,DC=local
 * Checking RestrictedKrbHost/rhel-web01.linux.lab.local
 *    Added RestrictedKrbHost/rhel-web01.linux.lab.local
 * Checking RestrictedKrbHost/RHEL-WEB01
 *    Added RestrictedKrbHost/RHEL-WEB01
 * Checking host/rhel-web01.linux.lab.local
 *    Added host/rhel-web01.linux.lab.local
 * Checking host/RHEL-WEB01
 *    Added host/RHEL-WEB01
 * Discovered which keytab salt to use
 * Added the entries to the keytab: RHEL-WEB01$@LAB.LOCAL: FILE:/etc/krb5.keytab
 * Added the entries to the keytab: host/RHEL-WEB01@LAB.LOCAL: FILE:/etc/krb5.keytab
 * Added the entries to the keytab: host/rhel-web01.linux.lab.local@LAB.LOCAL: FILE:/etc/krb5.keytab
 * Added the entries to the keytab: RestrictedKrbHost/RHEL-WEB01@LAB.LOCAL: FILE:/etc/krb5.keytab
 * Added the entries to the keytab: RestrictedKrbHost/rhel-web01.linux.lab.local@LAB.LOCAL: FILE:/etc/krb5.keytab
 * /usr/bin/systemctl enable sssd.service
 * /usr/bin/systemctl restart sssd.service
 * /usr/bin/sh -c /usr/bin/authselect select sssd with-mkhomedir --force && /usr/bin/systemctl enable oddjobd.service && /usr/bin/systemctl start oddjobd.service
Backup stored at /var/lib/authselect/backups/2026-04-22-07-42-30.IWav3C
Profile "sssd" was selected.
The following nsswitch maps are overwritten by the profile:
- passwd
- group
- netgroup
- automount
- services

Make sure that SSSD service is configured and enabled. See SSSD documentation for more information.

- with-mkhomedir is selected, make sure pam_oddjob_mkhomedir module
  is present and oddjobd service is enabled and active
  - systemctl enable --now oddjobd.service

 * Successfully enrolled machine in realm
```
### 2.3 — Verify Kerberos and `realm list` output on rhel-web01

After a successful join, verify that the machine keytab exists and that `realmd` reports the domain as configured.

```bash
realm list
klist -k /etc/krb5.keytab
adcli testjoin -D lab.local
```
Result:
```
[root@rhel-web01 ~]# realm list
klist -k /etc/krb5.keytab
adcli testjoin -D lab.local
lab.local
  type: kerberos
  realm-name: LAB.LOCAL
  domain-name: lab.local
  configured: kerberos-member
  server-software: active-directory
  client-software: sssd
  required-package: oddjob
  required-package: oddjob-mkhomedir
  required-package: sssd
  required-package: adcli
  required-package: samba-common-tools
  login-formats: %U@lab.local
  login-policy: allow-realm-logins
Keytab name: FILE:/etc/krb5.keytab
KVNO Principal
---- --------------------------------------------------------------------------
   2 RHEL-WEB01$@LAB.LOCAL
   2 RHEL-WEB01$@LAB.LOCAL
   2 host/RHEL-WEB01@LAB.LOCAL
   2 host/RHEL-WEB01@LAB.LOCAL
   2 host/rhel-web01.linux.lab.local@LAB.LOCAL
   2 host/rhel-web01.linux.lab.local@LAB.LOCAL
   2 RestrictedKrbHost/RHEL-WEB01@LAB.LOCAL
   2 RestrictedKrbHost/RHEL-WEB01@LAB.LOCAL
   2 RestrictedKrbHost/rhel-web01.linux.lab.local@LAB.LOCAL
   2 RestrictedKrbHost/rhel-web01.linux.lab.local@LAB.LOCAL
Sucessfully validated join to domain lab.local
```
Confirm that `realm list` reports the domain as configured and that `adcli testjoin` succeeds.

### 2.4 — Inspect generated SSSD configuration and domain state

Inspect the generated SSSD configuration and the current runtime state of the domain.

```bash
ls -l /etc/sssd/sssd.conf
cat /etc/sssd/sssd.conf
systemctl status sssd --no-pager
```

If `sssctl` is missing, install `sssd-tools` and repeat the verification.

```bash
dnf install -y sssd-tools
command -v sssctl
sssctl config-check
sssctl domain-status lab.local
```


Result:
```
[root@rhel-web01 ~]# sssctl config-check
Issues identified by validators: 0

Messages generated during configuration merging: 0

Used configuration snippet files: 0
[root@rhel-web01 ~]# sssctl domain-status lab.local
Online status: Online

Active servers:
AD Global Catalog: not connected
AD Domain Controller: win-dc01.lab.local

Discovered AD Global Catalog servers:
None so far.
Discovered AD Domain Controller servers:
- win-dc01.lab.local
```

Verify that the domain section uses AD integration and that `sssd` is active.

### 2.5 — Confirm computer object creation in Active Directory

Confirm from the Windows side that the computer object was created in AD. At this stage it will normally appear in the default `Computers` container; you will move it to the dedicated OU in Step 3.

Run the following command in PowerShell on `win-mgmt01` or `win-dc01`:

```powershell
Get-ADComputer -Filter 'Name -eq "rhel-web01"' -Properties DNSHostName, DistinguishedName, Enabled
```

Result:
```
PS C:\Users\Administrator> Get-ADComputer -Filter 'Name -eq "rhel-web01"' -Properties DNSHostName, DistinguishedName, Enabled
DistinguishedName : CN=RHEL-WEB01,CN=Computers,DC=lab,DC=local
DNSHostName       : rhel-web01.linux.lab.local
Enabled           : True
Name              : RHEL-WEB01
ObjectClass       : computer
ObjectGUID        : cdeb9fc4-2363-4f78-afa1-24696b5f07c7
SamAccountName    : RHEL-WEB01$
SID               : S-1-5-21-1657246285-1208839130-1596478242-1601
UserPrincipalName : 
```

If you prefer the GUI, verify the same object in Active Directory Users and Computers.

---
### Notes

- `realm join` wypisało ostrzeżenia `Encryption type [16/23/3/1] not permitted` — to poprawne zachowanie nowoczesnej polityki AD, która odrzuca 3DES, RC4 i DES. Do keytab trafiły wyłącznie AES256/AES128 (po 2 wpisy na principal w `klist -k`).
- `authselect select sssd with-mkhomedir --force` został wykonany automatycznie przez `realm join` — Krok 4.1 będzie już tylko weryfikacją, nie re-aplikacją profilu.
- `sssctl domain-status` zaraz po join pokazuje `AD Global Catalog: not connected` — to normalne, GC łączy się leniwie przy pierwszym zapytaniu cross-domain.
- Na świeżej Rocky 9.7 pakiet `sssd-tools` nie był zainstalowany razem z `sssd` — `sssctl` pojawia się dopiero po osobnym `dnf install sssd-tools`.
- Domyślna `login-policy` po join to `allow-realm-logins` — każdy użytkownik AD może się zalogować. Ograniczenie do grup dzieje się dopiero w Kroku 4.2.

---
### Conclusion

#### What - Co zrobiłem?

- Uruchomiłem `realm join --verbose lab.local -U Administrator`; `realmd` wywołał pod spodem `adcli join`, który:
  - znalazł DC przez `_ldap._tcp.lab.local` i NetLogon ping do `win-dc01.lab.local`,
  - wygenerował 120-znakowe hasło komputera,
  - utworzył obiekt `CN=RHEL-WEB01,CN=Computers,DC=lab,DC=local`,
  - ustawił hasło komputera przez Kerberos (kvno=2),
  - zarejestrował SPN-y `host/` i `RestrictedKrbHost/` (krótkie oraz FQDN),
  - zapisał keytab `/etc/krb5.keytab` z wpisami AES256/AES128.
- Zweryfikowałem join: `realm list` zwraca `configured: kerberos-member`, `klist -k /etc/krb5.keytab` wypisuje komplet principalów, `adcli testjoin -D lab.local` → `Successfully validated join to domain lab.local`.
- Obejrzałem `/etc/sssd/sssd.conf` wygenerowany przez `realmd` (uprawnienia `0600`, `id_provider = ad`, `access_provider = ad`, `ldap_id_mapping = True`, `use_fully_qualified_names = True`, `fallback_homedir = /home/%u@%d`, `krb5_realm = LAB.LOCAL`).
- Zainstalowałem `sssd-tools` i potwierdziłem stan runtime: `sssctl config-check` → `Issues identified by validators: 0`; `sssctl domain-status lab.local` → `Online`, Active DC: `win-dc01.lab.local`.
- Potwierdziłem w AD (PowerShell na `win-mgmt01`) obecność obiektu `RHEL-WEB01`: DN w `CN=Computers`, `Enabled: True`, `DNSHostName: rhel-web01.linux.lab.local`, SID `...-1601`.

---
#### Why - Dlaczego to zrobiłem?

Cel Kroku 2 to faktyczne włączenie `rhel-web01` do domeny AD w sposób idiomatyczny dla nowoczesnego Linuksa (RHEL/Rocky 9): `realmd` + `adcli` + SSSD, z Kerberosem jako mechanizmem uwierzytelniania hosta i użytkowników. Zrobienie tego „ręcznie” (samba `net ads join` albo edycja `krb5.conf` i `sssd.conf` palcami) było historycznym modelem i nie daje gwarancji, że SPN-y, keytab, `authselect` i PAM będą spójne. Weryfikacje (`realm list`, `klist -k`, `adcli testjoin`, `sssctl`) potwierdzają, że każda warstwa stosu (obiekt w AD, bilety Kerberos, konfig SSSD, połączenie do DC) jest zdrowa — bez tego dalsze kroki (OU, polityki dostępu, GPO) nie miałyby na czym się wesprzeć.

---
#### Result - Co dzięki temu uzyskałem?

- `rhel-web01` jest pełnoprawnym członkiem domeny `lab.local` — obiekt komputera istnieje w AD, keytab zawiera klucze AES dla wszystkich wymaganych principalów.
- SSSD wygenerowany przez `realmd` jest kompletny i aktywny; `sssctl` potwierdza zdrową konfigurację i połączenie do DC.
- `authselect sssd with-mkhomedir` wstał automatycznie — NSS (`passwd`, `group`, `netgroup`, `automount`, `services`) i PAM gotowe do uwierzytelnienia użytkowników AD.
- Host jest gotowy do operacji AD-side w Kroku 3 (przeniesienie do OU) i do ograniczenia polityki logowania w Kroku 4.

---
#### Lesson Learned - Co się nauczyłem?

- `realm join` wykonuje znacznie więcej niż samo dodanie obiektu do AD: włącza i startuje `sssd`, uruchamia `authselect select sssd with-mkhomedir --force`, włącza `oddjobd`. Dlatego po udanym join następne kroki sprowadzają się głównie do weryfikacji i ograniczenia polityki, a nie do budowania konfigu od zera.
- Komunikaty `Encryption type [X] not permitted` w logu to feature, nie bug — AD świadomie odrzuca legacy enctypes (RC4/3DES/DES). Jeśli `klist -k` pokazuje tylko AES256/AES128, to jest pożądany stan.
- `sssd-tools` nie jest zależnością `sssd` na RHEL/Rocky 9 — trzeba go instalować osobno, inaczej brakuje `sssctl`, które jest domyślnym narzędziem do diagnostyki.
- Domyślna `login-policy: allow-realm-logins` po `realm join` oznacza, że **każdy** użytkownik domeny może się od razu zalogować, jeśli ma SSH i shell. Jeżeli host ma mieć dostęp ograniczony do grup, musi to być zrobione jawnie przez `realm permit` (Krok 4.2) — sam join nie egzekwuje żadnej restrykcji.
- `login-formats: %U@lab.local` (z UPN-style username) to domyślna konwencja `realmd` przy `use_fully_qualified_names = True`; login typu `testuser01` (bez sufiksu) nie zadziała i to jest świadoma decyzja — zapobiega kolizjom między tożsamościami AD a lokalnymi.

---
#### Problem solved - Jakie problemy zostały rozwiązane?

- Brak obiektu komputera `rhel-web01` w AD → `realm join` utworzył `CN=RHEL-WEB01,CN=Computers,DC=lab,DC=local` z keytab i SPN-ami.
- Brak konfiguracji SSSD (`configured: no` w `realm discover`) → po join `realm list` pokazuje `configured: kerberos-member`, SSSD online wobec `win-dc01.lab.local`.
- Brak `sssctl` na świeżej instalacji → `dnf install -y sssd-tools`.

---
## Step 3 — From win-mgmt01: create OU for Linux systems, create Linux admin/user groups, assign test users, and move `rhel-web01` into the OU

### 3.1 — Create a dedicated OU for Linux systems

Run from PowerShell on `win-mgmt01`. First confirm that the lab root OU exists, then create a dedicated OU for Linux systems under `OU=Lab,DC=lab,DC=local`.

```powershell
Import-Module ActiveDirectory

Get-ADOrganizationalUnit -LDAPFilter '(ou=Lab)' -SearchBase 'DC=lab,DC=local'
Get-ADOrganizationalUnit -LDAPFilter '(ou=Linux Systems)' -SearchBase 'OU=Lab,DC=lab,DC=local'

New-ADOrganizationalUnit -Name 'Linux Systems' -Path 'OU=Lab,DC=lab,DC=local' -ProtectedFromAccidentalDeletion $true
```

If `Get-ADOrganizationalUnit` already returns `Linux Systems`, do not create it again.

GUI alternative:
Open `Active Directory Users and Computers` on `win-mgmt01`, expand `lab.local`, go to `OU=Lab`, right-click it, choose `New` -> `Organizational Unit`, enter `Linux Systems`, leave protection from accidental deletion enabled, and confirm. If the OU already exists, only verify it and do not create a duplicate.

### 3.2 — Create AD groups for Linux administrators and standard users

Create two security groups inside the new OU. Use `linuxadmins` for privileged Linux access and `linuxusers` for standard Linux access.

```powershell
Get-ADGroup -Filter 'Name -eq "linuxadmins" -or Name -eq "linuxusers"' -SearchBase 'OU=Linux Systems,OU=Lab,DC=lab,DC=local'

New-ADGroup -Name 'linuxadmins' -SamAccountName 'linuxadmins' -GroupScope Global -GroupCategory Security -Path 'OU=Linux Systems,OU=Lab,DC=lab,DC=local' -Description 'Linux administrators'
New-ADGroup -Name 'linuxusers' -SamAccountName 'linuxusers' -GroupScope Global -GroupCategory Security -Path 'OU=Linux Systems,OU=Lab,DC=lab,DC=local' -Description 'Linux standard users'
```

If the groups already exist, skip the `New-ADGroup` commands and only verify their location and type.

GUI alternative:
In `Active Directory Users and Computers`, open `Linux Systems` under `Lab`, right-click the OU, choose `New` -> `Group`, create `linuxadmins` as a `Global` `Security` group, then repeat the same for `linuxusers`. If the groups already exist, open their properties and verify name, scope, and category.

### 3.3 — Assign test users to the Linux groups

Use the existing AD test users from `OU=Users,OU=Lab,DC=lab,DC=local`. Assign `testuser01` to `linuxadmins` and `testuser02` to `linuxusers`. Leave `service02` outside these groups for a later deny test.

```powershell
Get-ADUser -Filter 'SamAccountName -eq "testuser01" -or SamAccountName -eq "testuser02" -or SamAccountName -eq "service02"' -SearchBase 'OU=Users,OU=Lab,DC=lab,DC=local'

Add-ADGroupMember -Identity 'linuxadmins' -Members 'testuser01'
Add-ADGroupMember -Identity 'linuxusers' -Members 'testuser02'
```

Do not add `service02` to either Linux access group.

GUI alternative:
In `Active Directory Users and Computers`, open the `linuxadmins` group, go to `Properties` -> `Members` -> `Add`, add `testuser01`, then repeat for `linuxusers` with `testuser02`. Verify that `service02` does not appear on the `Members` tab of either group.

### 3.4 — Move `rhel-web01` computer object into the Linux OU

Move `rhel-web01` now, because its computer object already exists after the domain join from Step 2. Do not handle `ubuntu-ws02` here — its object will exist only after the domain join in Step 5 and should be moved as part of that later step.

```powershell
$RhelComputer = Get-ADComputer -Filter 'Name -eq "rhel-web01"' -Properties DistinguishedName,DNSHostName

$RhelComputer | Format-List Name,DNSHostName,DistinguishedName

Move-ADObject -Identity $RhelComputer.DistinguishedName -TargetPath 'OU=Linux Systems,OU=Lab,DC=lab,DC=local'
```

GUI alternative:
In `Active Directory Users and Computers`, locate `rhel-web01` in its current container, right-click it, choose `Move`, and select `Linux Systems` under `Lab`. Do not look for `ubuntu-ws02` yet — move it only after the domain join in Step 5.

### 3.5 — Verify OU placement and group membership from RSAT / PowerShell

Verify that the OU exists, the groups are present, the expected users are members of the correct groups, and `rhel-web01` is already in the Linux OU.

```powershell
Get-ADOrganizationalUnit -LDAPFilter '(ou=Linux Systems)' -SearchBase 'OU=Lab,DC=lab,DC=local'

Get-ADGroup -Filter 'Name -eq "linuxadmins" -or Name -eq "linuxusers"' -SearchBase 'OU=Linux Systems,OU=Lab,DC=lab,DC=local' | Select Name,GroupCategory,GroupScope,DistinguishedName

Get-ADGroupMember -Identity 'linuxadmins' | Select Name,SamAccountName,ObjectClass
Get-ADGroupMember -Identity 'linuxusers' | Select Name,SamAccountName,ObjectClass

Get-ADComputer -Filter 'Name -eq "rhel-web01"' -Properties DNSHostName,DistinguishedName | Select Name,DNSHostName,DistinguishedName
```

GUI alternative:
In `Active Directory Users and Computers`, open `Lab` -> `Linux Systems` and confirm that the OU contains the expected groups and the `rhel-web01` computer object. Then open the properties of `linuxadmins` and `linuxusers` and verify the `Members` tab shows `testuser01` and `testuser02` in the correct groups.

---
### Notes

- Obiekt `rhel-web01` przeniesiony do `OU=Linux Systems,OU=Lab,DC=lab,DC=local` **już po** domain join (konto musi istnieć w AD zanim będzie co przenosić) — stąd kolejność Step 2 → Step 3.4, nigdy odwrotnie.
- `ubuntu-ws02` celowo nie jest tu ruszany — pojawi się w AD dopiero po Kroku 5 (domain join z Ubuntu) i zostanie przeniesiony do OU w 5.6.
- `service02` pozostaje poza `linuxadmins`/`linuxusers` — będzie użyty jako deny-test w Kroku 4.3 i w Kroku 7.4.

---
### Conclusion

#### What - Co zrobiłem?

- Na `win-mgmt01` (PowerShell z modułem `ActiveDirectory`) utworzyłem OU `OU=Linux Systems,OU=Lab,DC=lab,DC=local` z `ProtectedFromAccidentalDeletion $true`.
- Utworzyłem w tej OU dwie globalne grupy zabezpieczeń: `linuxadmins` (uprzywilejowany dostęp do Linuksów) i `linuxusers` (standardowy dostęp).
- Dodałem `testuser01` do `linuxadmins`, `testuser02` do `linuxusers`; `service02` świadomie pozostawiony poza obiema grupami.
- Przeniosłem obiekt komputera `RHEL-WEB01` z `CN=Computers` do `OU=Linux Systems,OU=Lab,DC=lab,DC=local` przez `Move-ADObject`.
- Zweryfikowałem wszystko przez `Get-ADOrganizationalUnit`, `Get-ADGroupMember linuxadmins/linuxusers` i `Get-ADComputer rhel-web01` — OU istnieje, członkowie grup zgodni z planem, `DistinguishedName` komputera wskazuje nowe OU.

---
#### Why - Dlaczego to zrobiłem?

OU `Linux Systems` to jawny kontener administracyjny dla linuksowej gałęzi domeny: trzyma konta komputerów i grupy dostępowe w jednym miejscu, daje jasny target dla GPO w Kroku 6 oraz granicę delegacji uprawnień po stronie AD. Grupy `linuxadmins`/`linuxusers` oddzielają politykę dostępu (AD-side) od konfiguracji hosta (SSSD na Linuksie), więc w Kroku 4 można będzie ograniczyć logowanie przez `realm permit -g` bez dotykania lokalnych list użytkowników ani PAM-a. Przeniesienie `rhel-web01` po join (a nie zamiast join) jest zgodne z realnym cyklem życia obiektu w AD — `realmd`/`adcli` tworzy obiekt w `CN=Computers`, administrator AD porządkuje jego lokalizację.

---
#### Result - Co dzięki temu uzyskałem?

- Uporządkowaną strukturę AD dla części linuksowej: jedno OU trzyma wszystkie linuksowe komputery i grupy dostępowe.
- Dwie grupy zabezpieczeń gotowe do użycia przez `realm permit` w Kroku 4 (allow) i do walidacji deny (`service02`).
- `rhel-web01` w docelowej OU, gotowy na ewentualne GPO z Kroku 6.

---
#### Lesson Learned - Co się nauczyłem?

- `realmd`/`adcli` zawsze wrzuca nowe konta komputerów do `CN=Computers`, nawet jeśli plan zakłada inny kontener. Zmiana lokalizacji to zawsze osobny krok AD-side i nie może być zrobiona przed join (nie ma czego przenosić).
- Global Security group to właściwy typ grupy dla polityki dostępu do pojedynczej domeny — SSSD z AD provider mapuje je 1:1 na tożsamość POSIX przez `ldap_id_mapping`.
- Warto od razu tworzyć dwie grupy (`linuxadmins` i `linuxusers`) zamiast jednej — nawet jeśli obie są na start pełnoprawnymi allow-listami, rozdzielenie daje kanwę pod późniejsze różnicowanie (np. `sudo` tylko dla `linuxadmins` w LAB-07 albo odrębne polityki GPO).
- `ProtectedFromAccidentalDeletion` warto zostawić na OU trzymających tożsamości i polityki — w labie kosztuje to jedno dodatkowe kliknięcie przy sprzątaniu, w produkcji ratuje przed „ups, usunąłem OU z 2000 komputerami”.

---
#### Problem solved - Jakie problemy zostały rozwiązane?

- Brak dedykowanej OU i grup dla Linuksa → utworzone `OU=Linux Systems`, grupy `linuxadmins`/`linuxusers`.
- `rhel-web01` w domyślnym `CN=Computers` (efekt `realm join`) → przeniesione do `OU=Linux Systems`.
- Brak rozróżnienia „kto ma się logować na Linuksy” → członkostwo `testuser01`/`testuser02` w odpowiednich grupach daje materiał na wymuszenie polityki w Kroku 4.

---
## Step 4 — Restrict login on rhel-web01 to designated AD groups; configure automatic home directory creation and validate group-based access

### 4.1 — Enable automatic home directory creation on rhel-web01

Verify whether automatic home directory creation is already enabled from the `realm join` phase. On RHEL 9 with `realmd`, Step 2 usually already selected `authselect sssd with-mkhomedir`, so here you should confirm the state and re-apply it only if it is missing.

```bash
rpm -q oddjob oddjob-mkhomedir
authselect current
systemctl enable --now oddjobd
systemctl status oddjobd --no-pager
grep -E 'pam_oddjob_mkhomedir' /etc/pam.d/system-auth /etc/pam.d/password-auth
```

If `authselect current` does not show the `with-mkhomedir` feature, re-apply the profile and verify it again.

```bash
authselect select sssd with-mkhomedir --force
systemctl enable --now oddjobd
authselect current
```

Result:
```
[root@rhel-web01 ~]# rpm -q oddjob oddjob-mkhomedir
oddjob-0.34.7-7.el9.x86_64
oddjob-mkhomedir-0.34.7-7.el9.x86_64
[root@rhel-web01 ~]# authselect current
Profile ID: sssd
Enabled features:
- with-mkhomedir
[root@rhel-web01 ~]# systemctl enable --now oddjobd
[root@rhel-web01 ~]# systemctl status oddjobd --no-pager
● oddjobd.service - privileged operations for unprivileged applications
     Loaded: loaded (/usr/lib/systemd/system/oddjobd.service; enabled; preset: disabled)
     Active: active (running) since Wed 2026-04-22 09:40:03 CEST; 25min ago
   Main PID: 13766 (oddjobd)
      Tasks: 1 (limit: 10626)
     Memory: 588.0K (peak: 852.0K)
        CPU: 1ms
     CGroup: /system.slice/oddjobd.service
             └─13766 /usr/sbin/oddjobd -n -p /run/oddjobd.pid -t 300

Apr 22 09:40:03 rhel-web01.linux.lab.local systemd[1]: Started privileged operations for unprivileged applications.
[root@rhel-web01 ~]# grep -E 'pam_oddjob_mkhomedir' /etc/pam.d/system-auth /etc/pam.d/password-auth
/etc/pam.d/system-auth:session     optional                                     pam_oddjob_mkhomedir.so
/etc/pam.d/password-auth:session     optional                                     pam_oddjob_mkhomedir.so 
```

### 4.2 — Restrict allowed login to the designated AD groups

Keep your current root session open while applying the policy so you can immediately adjust it if the first access test behaves differently than expected.

Switch from the default `allow-realm-logins` policy to a restricted policy that permits only the dedicated AD groups created in Step 3. Use `realm permit` instead of editing PAM or SSH allow-lists directly, because this keeps the restriction aligned with the `realmd` + SSSD integration.

```bash
realm list
realm deny --all
realm permit -g linuxadmins linuxusers
realm list
sssctl config-check
systemctl restart sssd
systemctl status sssd --no-pager
```

After the change, `realm list` should no longer report `login-policy: allow-realm-logins`; it should show that logins are restricted to explicitly permitted groups.

### 4.3 — Validate group-based allow and deny behaviour on rhel-web01

First verify that SSSD resolves all three AD identities. This lookup should work for `testuser01`, `testuser02`, and `service02`, because access restriction affects login authorization, not basic identity resolution.

```bash
getent passwd 'testuser01@lab.local'
getent passwd 'testuser02@lab.local'
getent passwd 'service02@lab.local'
id 'testuser01@lab.local'
id 'testuser02@lab.local'
id 'service02@lab.local'
```

Then test SSH access against the local SSH service. If you prefer, you can run the same SSH tests from a second terminal or from another machine instead of using `localhost`.

```bash
ssh -l 'testuser01@lab.local' localhost
ssh -l 'testuser02@lab.local' localhost
ssh -l 'service02@lab.local' localhost
```

After a successful login as `testuser01@lab.local` and `testuser02@lab.local`, run the following checks inside the session:

```bash
whoami
id
groups
pwd
echo $HOME
ls -ld "$HOME"
exit
```

`service02@lab.local` should be denied by SSH after password entry, because that account is not a member of `linuxadmins` or `linuxusers`.

Result
```
[root@rhel-web01 ~]# getent passwd 'testuser01@lab.local'
testuser01@lab.local:*:264601103:264600513:Testuser01:/home/testuser01@lab.local:/bin/bash
[root@rhel-web01 ~]# getent passwd 'testuser02@lab.local'
testuser02@lab.local:*:264601104:264600513:Testuser02:/home/testuser02@lab.local:/bin/bash
[root@rhel-web01 ~]# getent passwd 'service02@lab.local'
service02@lab.local:*:264601105:264600513:Service02:/home/service02@lab.local:/bin/bash
[root@rhel-web01 ~]# id 'testuser01@lab.local'
uid=264601103(testuser01@lab.local) gid=264600513(domain users@lab.local) groups=264600513(domain users@lab.local),264601602(linuxadmins@lab.local)
[root@rhel-web01 ~]# id 'testuser02@lab.local'
uid=264601104(testuser02@lab.local) gid=264600513(domain users@lab.local) groups=264600513(domain users@lab.local),264601603(linuxusers@lab.local)
[root@rhel-web01 ~]# id 'service02@lab.local'
uid=264601105(service02@lab.local) gid=264600513(domain users@lab.local) groups=264600513(domain users@lab.local)
[root@rhel-web01 ~]# ssh -l 'testuser01@lab.local' localhost
The authenticity of host 'localhost (::1)' can't be established.
ED25519 key fingerprint is SHA256:wFjgmfnJiQtJ53HT2mRI0LJEzNqGKyi3Wv4JkoGLFFk.
This key is not known by any other names
Are you sure you want to continue connecting (yes/no/[fingerprint])? yes
Warning: Permanently added 'localhost' (ED25519) to the list of known hosts.
testuser01@lab.local@localhost's password:
Permission denied, please try again.
testuser01@lab.local@localhost's password:
Last failed login: Wed Apr 22 10:10:38 CEST 2026 from ::1 on ssh:notty
There was 1 failed login attempt since the last successful login.
[testuser01@lab.local@rhel-web01 ~]$ exit
logout
Connection to localhost closed.
[root@rhel-web01 ~]# ssh -l 'testuser02@lab.local' localhost
testuser02@lab.local@localhost's password:
[testuser02@lab.local@rhel-web01 ~]$ exit
logout
Connection to localhost closed.
[root@rhel-web01 ~]# ssh -l 'service02@lab.local' localhost
service02@lab.local@localhost's password:
Permission denied, please try again.
service02@lab.local@localhost's password:
Connection closed by ::1 port 22
[root@rhel-web01 ~]# ssh -l 'testuser01@lab.local' localhost
testuser01@lab.local@localhost's password:
Last login: Wed Apr 22 10:10:45 2026 from ::1
[testuser01@lab.local@rhel-web01 ~]$ whoami
id
groups
pwd
echo $HOME
ls -ld "$HOME"
exit
testuser01@lab.local
uid=264601103(testuser01@lab.local) gid=264600513(domain users@lab.local) groups=264600513(domain users@lab.local),264601602(linuxadmins@lab.local) context=unconfined_u:unconfined_r:unconfined_t:s0-s0:c0.c1023
domain users@lab.local linuxadmins@lab.local
/home/testuser01@lab.local
/home/testuser01@lab.local
drwx------. 2 testuser01@lab.local domain users@lab.local 83 Apr 22 10:10 /home/testuser01@lab.local
logout
Connection to localhost closed.
[root@rhel-web01 ~]# ssh -l 'testuser02@lab.local' localhost
testuser02@lab.local@localhost's password:
Last login: Wed Apr 22 10:11:20 2026 from ::1
[testuser02@lab.local@rhel-web01 ~]$ whoami
id
groups
pwd
echo $HOME
ls -ld "$HOME"
exit
testuser02@lab.local
uid=264601104(testuser02@lab.local) gid=264600513(domain users@lab.local) groups=264600513(domain users@lab.local),264601603(linuxusers@lab.local) context=unconfined_u:unconfined_r:unconfined_t:s0-s0:c0.c1023
domain users@lab.local linuxusers@lab.local
/home/testuser02@lab.local
/home/testuser02@lab.local
drwx------. 2 testuser02@lab.local domain users@lab.local 83 Apr 22 10:11 /home/testuser02@lab.local
logout
Connection to localhost closed.
```


---
### Notes

- `authselect current` już po `realm join` raportowało profil `sssd` z feature `with-mkhomedir` — nie musiałem re-aplikować profilu w 4.1, wystarczyła weryfikacja.
- `getent passwd` i `id` działają również dla `service02` — potwierdza to, że `realm permit`/`deny` ogranicza **autoryzację logowania**, nie resolve tożsamości przez NSS.
- UID-y i GID-y generowane z SID-a (`ldap_id_mapping = True`): GID główny `264600513` to `domain users@lab.local`, `linuxadmins` → 264601602, `linuxusers` → 264601603.
- Konwencja katalogu domowego: `/home/<user>@<domain>` (z `fallback_homedir = /home/%u@%d`). Uprawnienia `drwx------` tworzone przez `pam_oddjob_mkhomedir.so` przy pierwszym logowaniu.
- Prompt po SSH: `testuser01@lab.local@rhel-web01` — SSH dopisuje `@hostname` do nazwy użytkownika, która już zawiera `@lab.local`. Efekt `use_fully_qualified_names = True`; wygląda dziwnie, ale nie jest błędem.

---
### Conclusion

#### What - Co zrobiłem?

- Zweryfikowałem, że `authselect sssd with-mkhomedir` i `pam_oddjob_mkhomedir.so` w `system-auth`/`password-auth` są aktywne po `realm join` (Krok 2 je włączył automatycznie).
- Zmieniłem politykę logowania z domyślnej `allow-realm-logins` na `allow-permitted-logins`: `realm deny --all` + `realm permit -g linuxadmins linuxusers`. Restart `sssd`, `sssctl config-check` → 0 błędów.
- Zwalidowałem resolve tożsamości (NSS): `getent passwd` i `id` zwracają wpisy dla `testuser01`, `testuser02`, `service02` z poprawnymi UID/GID-ami i członkostwem w grupach AD.
- Przetestowałem SSH allow/deny przez `localhost`:
  - `testuser01@lab.local` (linuxadmins) → login OK, utworzony `/home/testuser01@lab.local` z trybem `0700`, `id` pokazuje `linuxadmins@lab.local`.
  - `testuser02@lab.local` (linuxusers) → login OK, utworzony katalog domowy, `id` pokazuje `linuxusers@lab.local`.
  - `service02@lab.local` (poza grupami) → `Permission denied` po haśle, `Connection closed` — deny wymuszony przez SSSD.

---
#### Why - Dlaczego to zrobiłem?

Domyślna polityka `allow-realm-logins` po `realm join` pozwala zalogować się **każdemu** użytkownikowi AD, co w realnym środowisku oznacza, że każdy pracownik firmy może wejść na każdy domain-joined Linux. Krok 4 zamyka tę lukę przez jawną listę grup dostępowych zarządzaną po stronie AD (`realm permit -g`), bez dotykania lokalnych list użytkowników ani `sshd_config`. Taki model jest skalowalny (dodanie kolejnego hosta to join + `realm permit`) i zgodny z zasadą, że polityka dostępu żyje w katalogu, a nie na kliencie. Osobno — automatyczne `mkhomedir` zwalnia administratora z ręcznego tworzenia katalogów domowych dla każdego nowego użytkownika AD.

---
#### Result - Co dzięki temu uzyskałem?

- Polityka dostępu na `rhel-web01` ograniczona do `linuxadmins` i `linuxusers` — potwierdzona empirycznie przez 2 × allow + 1 × deny.
- Automatyczne tworzenie katalogów domowych działa (`/home/<user>@lab.local`, tryb `0700`, właściciel user + grupa `domain users@lab.local`).
- NSS i autoryzacja są rozdzielone — `service02` istnieje jako tożsamość (gdyby był potrzebny do ownership plików), ale nie może się zalogować.

---
#### Lesson Learned - Co się nauczyłem?

- `realm permit -g` konfiguruje SSSD (`simple_allow_groups` / `ad_access_filter` pod maską), więc zmiana członkostwa grupy AD jest odczytywana na żywo przy następnym zapytaniu — nie trzeba restartować `sshd` ani ponownie łączyć z domeną.
- Access provider `ad` w SSSD wymusza polityki po stronie hosta (grupy + status konta w AD — disabled/expired automatycznie blokuje login). `simple` byłby tylko lokalnym filtrem grupowym bez sprawdzania stanu konta.
- `getent`/`id` nie respektują `realm permit` — to NSS, nie PAM. To celowe: narzędzia systemowe często potrzebują resolve UID/GID dla plików należących do użytkowników, którzy nie mają mieć interaktywnego dostępu.
- Domyślnie główny GID użytkownika AD to `domain users` (513); to zwykle nie jest użyteczne do polityki dostępu. Realne grupowanie robi się dopiero przez dedykowane grupy typu `linuxadmins`/`linuxusers` — stąd potrzeba Kroku 3 przed Krokiem 4.

---
#### Problem solved - Jakie problemy zostały rozwiązane?

- Otwarte logowanie do `rhel-web01` dla każdego użytkownika domeny (efekt `allow-realm-logins`) → polityka ograniczona do dwóch jawnie wskazanych grup AD.
- Potrzeba ręcznego tworzenia katalogów domowych dla użytkowników AD → `pam_oddjob_mkhomedir` + `oddjobd` robi to automatycznie przy pierwszym logowaniu.
- Niepewność, czy deny naprawdę działa → `service02` zweryfikowany jako odrzucony przez SSH, mimo że `id service02@lab.local` działa.

---
## Step 5 — Verify DNS and time synchronisation on ubuntu-ws02; install packages, join the domain, configure SSSD/PAM for AD login, and then move `ubuntu-ws02` into the Linux OU from win-mgmt01

**Starting point:** `ubuntu-ws02` is a freshly installed Ubuntu Server 24.04 VM in Proxmox (10.10.10.31/24). Assumed already present after install: `openssh-server` reachable, root or a sudoer account, static IP set via netplan. Everything else (AD toolchain, `chrony`, diagnostic utilities like `dig`/`nslookup`, `realmd`, `sssd`, PAM modules) must be installed in this step. None of the `realm`/`sssctl`/`adcli` commands will exist until Step 5.2 completes — Step 5.1 therefore uses only base utilities (`resolvectl`, `getent`, `hostnamectl`, `timedatectl`).

Run every command in this step as root (`sudo -i` once at the top of the session, or prefix each command with `sudo`).

### 5.1 — Verify resolver path, hostname, and time synchronisation on ubuntu-ws02

Update apt metadata and install minimal diagnostic tools that are often missing on a fresh Ubuntu Server (`dig`, `nslookup` come from `dnsutils`; `ping` from `iputils-ping` is usually already present):

```bash
apt update
apt install -y dnsutils iputils-ping
```

Confirm that the host uses `rhel-srv01` (10.10.10.20) as its only DNS and that it identifies itself with the full FQDN `ubuntu-ws02.linux.lab.local`.

```bash
resolvectl status | grep -E 'Current DNS|DNS Domain|Link'
cat /etc/resolv.conf
hostname
hostname -f
hostnamectl
timedatectl
getent hosts win-dc01.lab.local
getent hosts rhel-srv01.linux.lab.local
getent hosts ubuntu-ws02.linux.lab.local
```

Ubuntu Server uses `systemd-resolved` (stub `127.0.0.53`) and netplan (not NetworkManager). On a freshly installed VM the interface name is typically `enp6s18` on Proxmox/Q35 (check with `ip -br link`) and the netplan config is generated by cloud-init at `/etc/netplan/50-cloud-init.yaml`. Common defects on a fresh install:

- DNS points at `10.10.10.10` (AD DNS directly) instead of `10.10.10.20` (`rhel-srv01`) — which breaks the LAB-01 DNS path required by LAB-05.
- `search:` is set to a bogus value (e.g. the IP of the DNS server) instead of `linux.lab.local lab.local`.
- Static hostname is only `ubuntu-ws02` instead of the FQDN.

Fix the netplan file (substitute your interface name if different) and disable cloud-init's network regeneration so the change survives a reboot:

```bash
cat > /etc/netplan/50-cloud-init.yaml <<'EOF'
network:
    ethernets:
        enp6s18:
            addresses:
            - 10.10.10.31/24
            nameservers:
                addresses:
                - 10.10.10.20
                search:
                - linux.lab.local
                - lab.local
            routes:
            -   to: default
                via: 10.10.10.1
    version: 2
EOF
chmod 600 /etc/netplan/50-cloud-init.yaml

echo 'network: {config: disabled}' > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg

netplan apply
```

Set the static hostname to the FQDN and verify the full resolver path:

```bash
hostnamectl set-hostname ubuntu-ws02.linux.lab.local
resolvectl status | grep -E 'Current DNS|DNS Domain'
getent hosts win-dc01.lab.local
getent hosts rhel-srv01.linux.lab.local
getent hosts ubuntu-ws02.linux.lab.local
hostname -f
```

Expected after the fix: `Current DNS Server: 10.10.10.20`, `DNS Domain: lab.local linux.lab.local`, all three `getent` lookups return the correct IPs, and `hostname -f` returns `ubuntu-ws02.linux.lab.local`. A harmless `WARNING:root:Cannot call Open vSwitch: ovsdb-server.service is not running.` from `netplan apply` can be ignored — OVS is not used here.

If `timedatectl` does not report `System clock synchronized: yes`, enable `systemd-timesyncd` (default on Ubuntu Server) or install `chrony`:

```bash
timedatectl set-ntp true
timedatectl
systemctl status systemd-timesyncd --no-pager
```

Do not continue until all four `getent` lookups succeed, `hostname -f` returns the FQDN, and time is synchronised.

### 5.2 — Install required AD integration packages on ubuntu-ws02

On a fresh Ubuntu Server, none of the AD integration packages are present. Install the Ubuntu equivalent of the RHEL toolset. Note that Ubuntu's packages are split differently (`sssd-ad` pulls the AD backend, `libnss-sss`/`libpam-sss` wire SSSD into NSS/PAM). Apt must be able to reach the Ubuntu archive via `10.10.10.1` (the lab gateway) — if `apt update` fails with DNS errors, revisit 5.1.

```bash
apt update
apt upgrade -y   # optional but recommended on a freshly installed VM
DEBIAN_FRONTEND=noninteractive apt install -y \
    realmd sssd sssd-tools sssd-ad adcli \
    samba-common-bin oddjob oddjob-mkhomedir packagekit \
    krb5-user libnss-sss libpam-sss
```

`krb5-user` normally opens a TUI prompt for the default realm during install; `DEBIAN_FRONTEND=noninteractive` skips it and lets `realm join` write `/etc/krb5.conf` in Step 5.3. If you installed without that variable and got the prompt, enter `LAB.LOCAL`.

Verify:

```bash
dpkg -l | grep -E '^ii\s+(realmd|sssd|sssd-ad|sssd-tools|adcli|samba-common-bin|oddjob|oddjob-mkhomedir|krb5-user|libnss-sss|libpam-sss|packagekit)\b'
command -v realm
command -v adcli
command -v kinit
command -v klist
command -v sssctl
```

Result:
```
root@ubuntu-ws02:~# dpkg -l | grep -E '^ii\s+(realmd|sssd|...|packagekit)\b'
ii  adcli             0.9.1-1ubuntu2        ...
ii  krb5-user         1.19.2-2ubuntu0.7     ...
ii  libnss-sss:amd64  2.6.3-1ubuntu3.6      ...
ii  libpam-sss:amd64  2.6.3-1ubuntu3.6      ...
ii  oddjob            0.34.6-1              ...
ii  oddjob-mkhomedir  0.34.6-1              ...
ii  packagekit        1.2.5-2ubuntu3        ...
ii  realmd            0.17.0-1ubuntu2       ...
ii  samba-common-bin  2:4.15.13+dfsg-0ubuntu1.10  ...
ii  sssd              2.6.3-1ubuntu3.6      ...
ii  sssd-ad           2.6.3-1ubuntu3.6      ...
ii  sssd-tools        2.6.3-1ubuntu3.6      ...
...  # + sssd-ad-common, sssd-common, sssd-dbus, sssd-ipa, sssd-krb5, sssd-krb5-common, sssd-ldap, sssd-proxy (deps)

root@ubuntu-ws02:~# command -v realm adcli kinit klist sssctl
/usr/sbin/realm
/usr/sbin/adcli
/usr/bin/kinit
/usr/bin/klist
/usr/sbin/sssctl
```

### 5.3 — Discover and join the domain on ubuntu-ws02

Run readiness discovery and then the actual join. The computer account will be created in the default `CN=Computers` container — it will be moved to `OU=Linux Systems` in Step 5.6.

```bash
realm discover lab.local
realm join --verbose lab.local -U Administrator
```



Expected in `realm discover`: `server-software: active-directory`, `client-software: sssd`, `configured: no`. Expected at the end of `realm join`: `Successfully enrolled machine in realm`.

If the join fails, do not retry blindly — first recheck DNS (`win-dc01.lab.local`, reverse lookup), FQDN, and clock drift.

Result:
```
root@ubuntu-ws02:~# realm join --verbose lab.local -U Administrator
 * Successfully discovered: lab.local
Password for Administrator:
 * Authenticated as user: Administrator@LAB.LOCAL
 * Looked up domain SID: S-1-5-21-1657246285-1208839130-1596478242
 * Using fully qualified name: ubuntu-ws02.linux.lab.local
 * A computer account for UBUNTU-WS02$ does not exist
 * Calculated computer account: CN=UBUNTU-WS02,CN=Computers,DC=lab,DC=local
 * Encryption type [3] not permitted.
 * Encryption type [1] not permitted.
 * Created computer account: CN=UBUNTU-WS02,CN=Computers,DC=lab,DC=local
 * Set computer password
 * Retrieved kvno '2' for computer account in directory: CN=UBUNTU-WS02,CN=Computers,DC=lab,DC=local
 *    Added RestrictedKrbHost/ubuntu-ws02.linux.lab.local
 *    Added RestrictedKrbHost/UBUNTU-WS02
 *    Added host/ubuntu-ws02.linux.lab.local
 *    Added host/UBUNTU-WS02
 * Added the entries to the keytab: UBUNTU-WS02$@LAB.LOCAL: FILE:/etc/krb5.keytab
 ...  # + host/..., RestrictedKrbHost/... (krótkie i FQDN)
 ! Failed to update Kerberos configuration, not fatal, please check manually: Setting attribute standard::type not supported
 * /usr/sbin/service sssd restart
 * Successfully enrolled machine in realm
 ```

### 5.4 — Configure PAM / NSS and automatic home directory creation on ubuntu-ws02

Ubuntu does not use `authselect`; `realm join` edits `/etc/nsswitch.conf` and adds `pam_sss.so` entries to `/etc/pam.d/common-auth`/`common-account`/`common-password`/`common-session` via `pam-auth-update`. Automatic home directory creation has to be enabled explicitly.

```bash
grep -E 'sss' /etc/nsswitch.conf
grep -E 'pam_sss' /etc/pam.d/common-auth /etc/pam.d/common-session
pam-auth-update --enable mkhomedir
grep -E 'pam_mkhomedir' /etc/pam.d/common-session
systemctl enable --now oddjobd
systemctl status oddjobd --no-pager
```

Force fully qualified usernames and a sane home path in `/etc/sssd/sssd.conf` (the `realm join` default on Ubuntu is `use_fully_qualified_names = False` and the home path template may be missing). 

Edit the `[domain/lab.local]` section to include:

```ini
use_fully_qualified_names = True
fallback_homedir = /home/%u@%d
default_shell = /bin/bash
```

Then restart SSSD (the file must be `chmod 600 root:root`):

```bash
chmod 600 /etc/sssd/sssd.conf
chown root:root /etc/sssd/sssd.conf
sssctl config-check
systemctl restart sssd
systemctl status sssd --no-pager
```

### 5.5 — Verify `realm list`, SSSD state, and AD identity resolution on ubuntu-ws02

```bash
realm list
klist -k /etc/krb5.keytab
adcli testjoin -D lab.local
sssctl domain-status lab.local
getent passwd 'testuser01@lab.local'
getent passwd 'testuser02@lab.local'
getent passwd 'service02@lab.local'
id 'testuser01@lab.local'
id 'testuser02@lab.local'
id 'service02@lab.local'
```

Result:
```
root@ubuntu-ws02:~# realm list
lab.local
  ...
  configured: kerberos-member
  server-software: active-directory
  client-software: sssd
  ...
  login-formats: %U@lab.local
  login-policy: allow-realm-logins

root@ubuntu-ws02:~# klist -k /etc/krb5.keytab
Keytab name: FILE:/etc/krb5.keytab
KVNO Principal
---- --------------------------------------------------------------------------
   2 UBUNTU-WS02$@LAB.LOCAL
   2 host/UBUNTU-WS02@LAB.LOCAL
   2 host/ubuntu-ws02.linux.lab.local@LAB.LOCAL
   2 RestrictedKrbHost/UBUNTU-WS02@LAB.LOCAL
   2 RestrictedKrbHost/ubuntu-ws02.linux.lab.local@LAB.LOCAL
   ... (po 3 wpisy na principal — różne enctype)

root@ubuntu-ws02:~# adcli testjoin -D lab.local
Sucessfully validated join to domain lab.local

root@ubuntu-ws02:~# sssctl domain-status lab.local
Online status: Online
...
AD Domain Controller: win-dc01.lab.local

root@ubuntu-ws02:~# getent passwd 'testuser01@lab.local'
testuser01@lab.local:*:264601103:264600513:Testuser01:/home/testuser01@lab.local:/bin/bash
...  # testuser02 -> UID 264601104, service02 -> UID 264601105 (identyczne jak na rhel-web01)

root@ubuntu-ws02:~# id 'testuser01@lab.local'
uid=264601103(testuser01@lab.local) gid=264600513(domain users@lab.local) groups=...,264601602(linuxadmins@lab.local)
root@ubuntu-ws02:~# id 'testuser02@lab.local'
uid=264601104(...) groups=...,264601603(linuxusers@lab.local)
root@ubuntu-ws02:~# id 'service02@lab.local'
uid=264601105(...) groups=264600513(domain users@lab.local)   # brak linuxadmins/linuxusers — deny-kandydat
```


Expected: `realm list` shows `configured: kerberos-member`, `adcli testjoin` prints `Successfully validated join to domain lab.local`, `sssctl domain-status` is `Online` with `win-dc01.lab.local` as active DC, all three identities resolve with the same UID-range mapping as on `rhel-web01` (SID-based, so UIDs must match across both hosts).

Do not apply `realm permit` yet — the allow/deny policy will be validated end-to-end in Step 7.

### 5.6 — From win-mgmt01, move `ubuntu-ws02` computer object into the Linux Systems OU and verify placement

Run from PowerShell on `win-mgmt01`. First check the current location, then move and verify.

```powershell
Import-Module ActiveDirectory

$UbuntuComputer = Get-ADComputer -Filter 'Name -eq "ubuntu-ws02"' -Properties DistinguishedName,DNSHostName
$UbuntuComputer | Format-List Name,DNSHostName,DistinguishedName

Move-ADObject -Identity $UbuntuComputer.DistinguishedName -TargetPath 'OU=Linux Systems,OU=Lab,DC=lab,DC=local'

Get-ADComputer -Filter 'Name -eq "ubuntu-ws02"' -Properties DNSHostName,DistinguishedName |
    Select Name,DNSHostName,DistinguishedName
```

Result:
```
PS C:\Users\Administrator> Get-ADComputer -Filter 'Name -eq "ubuntu-ws02"' -Properties DNSHostName,DistinguishedName | Select Name,DNSHostName,DistinguishedName

Name        DNSHostName                 DistinguishedName
----        -----------                 -----------------
UBUNTU-WS02 ubuntu-ws02.linux.lab.local CN=UBUNTU-WS02,OU=Linux Systems,OU=Lab,DC=lab,DC=local
```


Expected: after `Move-ADObject`, `DistinguishedName` ends with `,OU=Linux Systems,OU=Lab,DC=lab,DC=local` and `DNSHostName` is `ubuntu-ws02.linux.lab.local`. GUI alternative: `Active Directory Users and Computers` → find `ubuntu-ws02` → right-click → `Move` → `Linux Systems`.

---
### Notes

- VM `ubuntu-ws02` to Ubuntu 22.04.5 LTS (nie 24.04), interfejs sieciowy `enp6s18`. Netplan wygenerowany przez cloud-init (`/etc/netplan/50-cloud-init.yaml`) miał dwa defekty: DNS wskazywał `10.10.10.10` (AD DNS bezpośrednio) zamiast `10.10.10.20` (`rhel-srv01`), a `search:` był ustawiony na sam IP DNS-a. Żeby zmiana przeżyła reboot, trzeba było dodatkowo wyłączyć regenerację sieci przez cloud-init (`/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg`).
- `realm join` na Ubuntu 22.04 wypisuje ostrzeżenie `Failed to update Kerberos configuration, not fatal ... Setting attribute standard::type not supported` — znany, nieszkodliwy glitch `realmd`/GIO, join mimo to kończy się `Successfully enrolled`.
- Keytab na Ubuntu ma po **3 wpisy** na principal (Ubuntu preferuje szerszy zestaw enctypes niż RHEL — AES256 + AES128 + dodatkowy), na RHEL-u było po 2. Obie warianty są akceptowane przez AD, który i tak odrzuca słabsze (`Encryption type [3] not permitted`, `[1] not permitted`).
- `realm join` na Ubuntu wygenerował `sssd.conf` z `use_fully_qualified_names = False` i bez `fallback_homedir`/`default_shell` — inaczej niż na RHEL-u, gdzie `realmd` ustawia te pola domyślnie. Musiałem je dopisać ręcznie, żeby zachować spójność tożsamości z `rhel-web01` (format `user@lab.local`, home `/home/%u@%d`).
- SID-based UID mapping w SSSD z `ldap_id_mapping = True` jest deterministyczne: `testuser01` ma UID `264601103` zarówno na `rhel-web01`, jak i na `ubuntu-ws02`. To fundament dla spójnego ownership plików na współdzielonych zasobach (SMB w LAB-07/08, NFS).
- `ubuntu-ws02` **nie** ma jeszcze `realm permit` — zostawione świadomie, polityka allow/deny dla obu hostów będzie walidowana razem w Kroku 7.

---
### Conclusion

#### What - Co zrobiłem?

- Naprawiłem ścieżkę resolvera na świeżej VM `ubuntu-ws02`: przepisałem `/etc/netplan/50-cloud-init.yaml` (DNS `10.10.10.20`, search `linux.lab.local lab.local`), wyłączyłem regenerację sieci przez cloud-init (`/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg`), ustawiłem static hostname `ubuntu-ws02.linux.lab.local`.
- Doinstalowałem pełny zestaw pakietów AD/SSSD dla Ubuntu: `realmd`, `sssd`, `sssd-tools`, `sssd-ad`, `adcli`, `samba-common-bin`, `oddjob`, `oddjob-mkhomedir`, `packagekit`, `krb5-user`, `libnss-sss`, `libpam-sss` (plus `dnsutils` do diagnostyki).
- Wykonałem `realm join --verbose lab.local -U Administrator`: konto komputera `CN=UBUNTU-WS02,CN=Computers,DC=lab,DC=local` utworzone, keytab `/etc/krb5.keytab` zapełniony SPN-ami `host/` i `RestrictedKrbHost/` (krótkie i FQDN) plus `UBUNTU-WS02$`, kvno=2.
- Zweryfikowałem integrację PAM/NSS: `pam_sss.so` obecny w `common-auth`/`common-session`, `pam_mkhomedir.so` dodany przez `pam-auth-update --enable mkhomedir`, `oddjobd` aktywny.
- Dopisałem do `[domain/lab.local]` w `/etc/sssd/sssd.conf`: `use_fully_qualified_names = True`, `fallback_homedir = /home/%u@%d`, `default_shell = /bin/bash`; ustawiłem `chmod 600`/`root:root`; `sssctl config-check` → 0 błędów; SSSD zrestartowany, aktywny.
- Zwalidowałem: `realm list` → `configured: kerberos-member`; `adcli testjoin` → `Successfully validated join`; `sssctl domain-status` → Online, DC `win-dc01.lab.local`; `getent passwd`/`id` dla `testuser01`/`testuser02`/`service02` zwracają identyczne UID-y jak na `rhel-web01` i właściwe członkostwo grup.
- Na `win-mgmt01` przeniosłem `UBUNTU-WS02` z `CN=Computers` do `OU=Linux Systems,OU=Lab,DC=lab,DC=local` przez `Move-ADObject`.

---
#### Why - Dlaczego to zrobiłem?

Drugi host w labie musi być domain-joined tym samym mechanizmem (`realmd` + `adcli` + SSSD) co `rhel-web01`, ale z uwzględnieniem różnic dystrybucyjnych: Ubuntu używa netplan + systemd-resolved, nie ma `authselect` (zamiast niego `pam-auth-update`), a pakiety są porozdzielane (`sssd-ad`, `libnss-sss`/`libpam-sss` osobno). Explicit ustawienie `use_fully_qualified_names = True` i `fallback_homedir = /home/%u@%d` jest konieczne, bo Ubuntu nie ustawia ich domyślnie — bez tego użytkownik AD miałby różny format loginu i różny katalog domowy na obu hostach, co łamałoby spójność tożsamości przy pracy z plikami i w następnych labach (SMB/NFS). Przeniesienie do OU po join jest potrzebne z tego samego powodu co dla `rhel-web01` — obiekt musi najpierw powstać w `CN=Computers`, dopiero potem trafia do docelowego kontenera administracyjnego.

---
#### Result - Co dzięki temu uzyskałem?

- `ubuntu-ws02` to pełnoprawny członek domeny `lab.local`: obiekt komputera w `OU=Linux Systems`, keytab z kluczami AES, SSSD Online wobec `win-dc01.lab.local`.
- Spójny model tożsamości między oboma hostami Linux: ten sam format loginu (`user@lab.local`), ten sam template home (`/home/%u@%d`), te same UID-y (SID-based mapping). Ownership plików i uprawnień będzie przenośne między hostami.
- PAM/NSS na Ubuntu zintegrowane poprawnie — `libnss-sss`/`libpam-sss` wpięte, `pam_mkhomedir` aktywny, `oddjobd` pracuje.
- W AD wszystkie linuksowe komputery są już w `OU=Linux Systems` — kontener jest gotowy na GPO z Kroku 6.

---
#### Lesson Learned - Co się nauczyłem?

- Netplan wygenerowany przez cloud-init na świeżej VM potrafi mieć bezsensowne wartości (`search:` = IP DNS-a, DNS wskazujący bezpośrednio na AD zamiast na lab-owy BIND). Poprawianie samego pliku bez wyłączenia cloud-init spowoduje, że po reboocie wróci pierwotny stan — `99-disable-network-config.cfg` to obowiązkowy element naprawy.
- Ubuntu `realmd` nie ustawia takich samych defaultów w `sssd.conf` jak RHEL — `use_fully_qualified_names` i `fallback_homedir` trzeba dopisać ręcznie. Bez tego logowanie nadal działa, ale tożsamość użytkownika AD jest inna niż na RHEL-u (krótki login, inny home), co potem psuje SMB/NFS i skrypty zakładające spójne UID/home.
- Ostrzeżenie `Failed to update Kerberos configuration, not fatal ... Setting attribute standard::type not supported` jest charakterystyczne dla `realmd` na Ubuntu 22.04 i nie blokuje join — keytab jest kompletny, `adcli testjoin` przechodzi.
- `pam-auth-update --enable mkhomedir` to ubuntowy odpowiednik `authselect select sssd with-mkhomedir` — dopisuje `pam_mkhomedir.so` do `common-session`, tylko w innym modelu zarządzania PAM-em.
- `ldap_id_mapping = True` gwarantuje identyczne UID-y na wszystkich hostach Linux w tej samej domenie AD — to nie jest automatycznie oczywiste i wymaga tej flagi w `sssd.conf` na każdym hoście.

---
#### Problem solved - Jakie problemy zostały rozwiązane?

- Błędny resolver na świeżej VM (DNS `10.10.10.10`, search = IP DNS-a) → przepisany netplan + wyłączona regeneracja cloud-init; wszystkie lookupy działają.
- Krótki static hostname `ubuntu-ws02` → `hostnamectl set-hostname ubuntu-ws02.linux.lab.local`.
- Brak pełnego toolchainu AD na świeżej Ubuntu → zainstalowane przez `apt install`.
- Domyślny `use_fully_qualified_names = False` na Ubuntu psułby spójność tożsamości z `rhel-web01` → dopisane 3 linie w `[domain/lab.local]`.
- Obiekt komputera w domyślnym `CN=Computers` → `Move-ADObject` do `OU=Linux Systems`.

---
## Step 6 — Configure a GPO for the Linux Systems OU via GPMC; validate SSSD GPO-based access control on both Linux hosts

**Model:** SSSD with `id_provider = ad` can consume a subset of Windows Group Policy — specifically the User Rights Assignment entries that correspond to logon types. With `ad_gpo_access_control = enforcing`, SSSD uses the linked GPO on the computer's OU as the authoritative source for `allow/deny log on` decisions. In this step we build that policy on the Windows side, enable enforcement on both Linux hosts, and validate that the result matches (and overrides) the `realm permit` rule from Step 4.

**Mapping — Windows User Right → SSSD logon type:**

| Windows User Right (GPO) | SSSD `access_control` category | Maps to Linux use case |
|---|---|---|
| `Allow log on locally` (`SeInteractiveLogonRight`) | `interactive` | Console / TTY login |
| `Allow log on through Remote Desktop Services` (`SeRemoteInteractiveLogonRight`) | `remote_interactive` | **SSH login** |
| `Deny log on locally` (`SeDenyInteractiveLogonRight`) | deny interactive | Console deny |
| `Deny log on through Remote Desktop Services` (`SeDenyRemoteInteractiveLogonRight`) | deny remote | **SSH deny** |
| `Allow log on as a batch job` | `network` / `batch` | cron, at |
| `Allow log on as a service` | `service` | systemd user services |

### 6.1 — Create and link a GPO on the Linux Systems OU

Run from PowerShell on `win-mgmt01` (requires the `GroupPolicy` module, included with RSAT).

```powershell
Import-Module GroupPolicy

$gpo = New-GPO -Name 'Linux Access Policy' -Comment 'Logon rights for domain-joined Linux hosts (enforced by SSSD ad_gpo_access_control).'
$gpo | Format-List DisplayName, Id, GpoStatus

New-GPLink -Name 'Linux Access Policy' -Target 'OU=Linux Systems,OU=Lab,DC=lab,DC=local' -LinkEnabled Yes -Enforced No

Get-GPInheritance -Target 'OU=Linux Systems,OU=Lab,DC=lab,DC=local' |
    Select -ExpandProperty GpoLinks |
    Format-Table DisplayName, Enabled, Enforced, Order
```

Expected: new GPO with a GUID, `GpoStatus: AllSettingsEnabled`, and after `New-GPLink`, `Get-GPInheritance` lists `Linux Access Policy` with `Enabled: True`.

GUI alternative: open `gpmc.msc` → navigate to `lab.local → Lab → Linux Systems` → right-click OU → `Create a GPO in this domain, and Link it here...` → name it `Linux Access Policy`.

### 6.2 — Configure allow/deny logon rights in the GPO

Edit the new GPO via the GPMC GUI (User Rights Assignment is not trivially scripted through `Set-GPRegistryValue` — it lives in SECEDIT INF, so the GUI is the pragmatic path):

1. In `gpmc.msc`, right-click **Linux Access Policy** → **Edit** → this opens Group Policy Management Editor.
2. Navigate: `Computer Configuration` → `Policies` → `Windows Settings` → `Security Settings` → `Local Policies` → `User Rights Assignment`.
3. Configure **four** rights:

   - **Allow log on locally** → `Define these policy settings` → add `LAB\linuxadmins`, `LAB\linuxusers`, `LAB\Domain Admins`, `Administrators`.
   - **Allow log on through Remote Desktop Services** → same list (this is what SSSD maps to SSH).
   - **Deny log on locally** → add `LAB\service02`.
   - **Deny log on through Remote Desktop Services** → add `LAB\service02`.

   `Administrators` (wbudowana grupa — wpisz po prostu `Administrators`, picker rozwinie na `BUILTIN\Administrators`) jest **wymagany** przez edytor GPO dla `Allow log on locally` — bez niej przycisk **Apply** jest nieaktywny i pojawia się komunikat *"Administrators must be granted the logon local right"*. Na Linuksie SSSD i tak tego SID-a nie mapuje, ale policy musi pozostać spójne z Windowsem. `LAB\Domain Admins` to dodatkowy bezpiecznik przed lock-outem.

   Jeśli picker nie znajduje grupy przy wpisaniu `linuxadmins`: kliknij **Locations...** i przełącz na `lab.local` (domyślnie bywa ustawiony na komputer lokalny lub BUILTIN), następnie **Check Names**.
4. Close the editor.

Verify:

```powershell
Get-GPOReport -Name 'Linux Access Policy' -ReportType Html -Path C:\Temp\LinuxAccessPolicy.html
# Or inline:
Get-GPOReport -Name 'Linux Access Policy' -ReportType Xml |
    Select-String -Pattern 'SeInteractiveLogonRight|SeRemoteInteractiveLogonRight|SeDenyInteractiveLogonRight|SeDenyRemoteInteractiveLogonRight' -Context 0,1
```

Expected: the report (or the filtered XML) contains all four User Right IDs with the expected members.

### 6.3 — Enable `ad_gpo_access_control = enforcing` on both Linux hosts

On **rhel-web01** and on **ubuntu-ws02**, edit the `[domain/lab.local]` section of `/etc/sssd/sssd.conf` and add one line:

```ini
ad_gpo_access_control = enforcing
```

Because `realm permit` from Step 4 configured `simple_allow_groups` only on `rhel-web01`, and because `ad_gpo_access_control = enforcing` **overrides** `simple_*` rules (the access provider becomes GPO-driven), the GPO is now the single source of truth on both hosts.

Keep a root shell open on each host while enabling enforcing mode — if the GPO is misconfigured you may otherwise lock yourself out of SSH.

On each host:

```bash
# rhel-web01 and ubuntu-ws02
grep -E '^\[|ad_gpo_access_control' /etc/sssd/sssd.conf
sssctl config-check
sss_cache -E          # expire the cache so the next lookup hits AD/GPO
systemctl restart sssd
systemctl status sssd --no-pager
```

Expected: `sssctl config-check` → 0 errors; `sssd` restarts cleanly.

Result:
```
root@ubuntu-ws02:~# grep -E '^\[|ad_gpo_access_control' /etc/sssd/sssd.conf
[sssd]
[domain/lab.local]
ad_gpo_access_control = enforcing

root@ubuntu-ws02:~# sssctl config-check
Issues identified by validators: 0
...

root@ubuntu-ws02:~# systemctl status sssd --no-pager
● sssd.service - System Security Services Daemon
     Active: active (running) since Wed 2026-04-22 10:50:31 UTC; 4ms ago
     ...  # sssd_be, sssd_nss, sssd_pam


[root@rhel-web01 ~]# grep -E '^\[|ad_gpo_access_control' /etc/sssd/sssd.conf
[sssd]
[domain/lab.local]
ad_gpo_access_control = enforcing

[root@rhel-web01 ~]# sssctl config-check
Issues identified by validators: 0
...

[root@rhel-web01 ~]# systemctl status sssd --no-pager
● sssd.service - System Security Services Daemon
     Active: active (running) since Wed 2026-04-22 12:50:24 CEST; 6ms ago
     ...  # sssd_be, sssd_nss, sssd_pam, sssd_pac
```



### 6.4 — Validate GPO application: gpresult on Windows, SSSD cache and SSH tests on Linux

On `win-mgmt01`, confirm the policy targets the computer accounts:

```powershell
gpresult /SCOPE COMPUTER /R | Select-String -Pattern 'Linux Access Policy' -Context 0,3
# Or with the full HTML report scoped to a specific computer (requires RSAT):
Invoke-GPUpdate -Computer 'rhel-web01.linux.lab.local' -Force -RandomDelayInMinutes 0
Invoke-GPUpdate -Computer 'ubuntu-ws02.linux.lab.local' -Force -RandomDelayInMinutes 0
```

`Invoke-GPUpdate` against a Linux client will fail (no WMI), which is expected — Linux does not run the Windows GP engine; SSSD re-reads GPO on its own refresh cycle or on `sssd` restart.

On **both Linux hosts**, inspect the GPO cache maintained by SSSD and run the SSH allow/deny matrix:

```bash
# rhel-web01 and ubuntu-ws02
ls -la /var/lib/sss/gpo_cache/
find /var/lib/sss/gpo_cache/ -type f -name '*.pol' -o -name 'gpt.ini' | head -20

ssh -l 'testuser01@lab.local' localhost 'whoami && id; exit'
ssh -l 'testuser02@lab.local' localhost 'whoami && id; exit'
ssh -l 'service02@lab.local'  localhost 'whoami && id; exit'
```

Expected matrix on **both** hosts:

- `testuser01@lab.local` (linuxadmins) → login OK.
- `testuser02@lab.local` (linuxusers) → login OK.
- `service02@lab.local` → `Permission denied`, `Connection closed` — now denied via GPO (previously allowed on `ubuntu-ws02` because that host had no `realm permit`; GPO enforcement closes that gap).

If any allow case fails or any deny case succeeds, inspect the SSSD domain log for the access decision trail:

```bash
tail -n 200 /var/log/sssd/sssd_lab.local.log | grep -iE 'gpo|access_|SeRemote|SeInteractive'
```

Common causes of mismatch:
- GPO not replicated yet to the DC the host is talking to — wait for replication or force it with `repadmin /syncall` on a DC.
- `ad_gpo_access_control` still `disabled` (default) — check `/etc/sssd/sssd.conf` and the `sssctl config-check` output.
- `linuxadmins`/`linuxusers` added with the wrong domain prefix in GPO (e.g. user-typed `linuxadmins` as a local group instead of `LAB\linuxadmins`) — re-open the User Right, remove, and re-add from the `Locations: Entire Directory` picker.

Result:
```
PS C:\Users\Administrator> gpresult /SCOPE COMPUTER /R | Select-String -Pattern 'Linux Access Policy' -Context 0,3
   # brak dopasowań — win-mgmt01 nie jest w OU Linux Systems, polityka się na nim nie aplikuje

PS C:\Users\Administrator> Invoke-GPUpdate -Computer 'rhel-web01.linux.lab.local' ...
Invoke-GPUpdate:  Computer "rhel-web01.linux.lab.local" is not responding. ...
PS C:\Users\Administrator> Invoke-GPUpdate -Computer 'ubuntu-ws02.linux.lab.local' ...
Invoke-GPUpdate:  Computer "ubuntu-ws02.linux.lab.local" is not responding. ...
   # oczekiwane — Linux nie odpowiada przez WMI/RPC


[root@rhel-web01 ~]# ls -la /var/lib/sss/gpo_cache/
total 0
drwxr-xr-x.  2 sssd sssd   6 Nov 12 01:44 .
...   # pusty — ta wersja SSSD nie persystuje .pol; decyzje podejmowane on-the-fly

[root@rhel-web01 ~]# ssh -l 'testuser01@lab.local' localhost 'whoami && id; exit'
testuser01@lab.local
uid=264601103(testuser01@lab.local) ... groups=...,264601602(linuxadmins@lab.local) ...
[root@rhel-web01 ~]# ssh -l 'testuser02@lab.local' localhost 'whoami && id; exit'
testuser02@lab.local
uid=264601104(testuser02@lab.local) ... groups=...,264601603(linuxusers@lab.local) ...
[root@rhel-web01 ~]# ssh -l 'service02@lab.local'  localhost 'whoami && id; exit'
Connection closed by ::1 port 22


root@ubuntu-ws02:~# ls -la /var/lib/sss/gpo_cache/
total 8
drwxr-xr-x  2 root root 4096 Aug 12  2025 .
...   # też pusty — ten sam efekt

root@ubuntu-ws02:~# ssh -l 'testuser01@lab.local' localhost 'whoami && id; exit'
testuser01@lab.local
uid=264601103(...) groups=...,264601602(linuxadmins@lab.local)
root@ubuntu-ws02:~# ssh -l 'testuser02@lab.local' localhost 'whoami && id; exit'
testuser02@lab.local
uid=264601104(...) groups=...,264601603(linuxusers@lab.local)
root@ubuntu-ws02:~# ssh -l 'service02@lab.local'  localhost 'whoami && id; exit'
Connection closed by 127.0.0.1 port 22   # deny z GPO — na tym hoście nie ma realm permit, więc to jedyne możliwe źródło decyzji
```

---
### Notes

- Tworzenie GPO z `New-GPO` + `New-GPLink` w PowerShellu idzie bez problemów, ale edycja User Rights Assignment nie ma sensownego odpowiednika w cmdletach — to SECEDIT INF, więc GUI `gpmc.msc` → `Edit` jest jedyną praktyczną drogą.
- Edytor GPO wymusza obecność `Administrators` (BUILTIN) w `Allow log on locally` — bez niej `Apply` jest zablokowany z komunikatem *"Administrators must be granted the logon local right"*. To zabezpieczenie po stronie Windowsa, nie mające znaczenia dla Linuksa (SSSD i tak nie mapuje `S-1-5-32-544` na lokalne konto).
- `Invoke-GPUpdate -Computer <linux>` zawsze kończy się błędem `not responding` — Linux nie wystawia WMI/RPC, więc Windows nie ma jak wywołać `gpupdate`. Po stronie Linuksa odświeżenie następuje przy restarcie `sssd` lub co `ad_gpo_cache_timeout` (domyślnie ~6 h).
- `gpresult /SCOPE COMPUTER /R` na `win-mgmt01` nie wyświetlił `Linux Access Policy`, ponieważ `win-mgmt01` nie leży w `OU=Linux Systems` — policy nie stosuje się do samej stacji zarządzania. To spodziewany efekt filtrowania przez link na OU.
- `/var/lib/sss/gpo_cache/` na obu hostach jest **pusty** mimo działającego enforcing — na tych wersjach SSSD (RHEL 9 `sssd 2.9.x`, Ubuntu 22.04 `sssd 2.6.3`) polityka jest pobierana i interpretowana on-the-fly bez zapisu `.pol`/`gpt.ini` do tego katalogu. Autorytatywny dowód działania to matryca SSH, nie zawartość cache.
- Na `ubuntu-ws02` `service02` był do tej pory dopuszczany (brak `realm permit` po tej stronie). Po włączeniu `ad_gpo_access_control = enforcing` jego SSH kończy się `Connection closed` — **jedynym** możliwym źródłem tej decyzji jest GPO, co potwierdza, że egzekwowanie działa end-to-end.
- Na `rhel-web01` deny dla `service02` mógł być wcześniej efektem `realm permit` z Kroku 4. Teraz autorytetem jest GPO — `simple_allow_groups` jest ignorowane przy `ad_gpo_access_control = enforcing`. Warto o tym pamiętać przy ewentualnym rollbacku.

---
### Conclusion

#### What - Co zrobiłem?

- Utworzyłem GPO `Linux Access Policy` (`New-GPO`) i podlinkowałem je do `OU=Linux Systems,OU=Lab,DC=lab,DC=local` (`New-GPLink -LinkEnabled Yes`).
- W `gpmc.msc` → User Rights Assignment skonfigurowałem cztery prawa:
  - `Allow log on locally` i `Allow log on through Remote Desktop Services` → `LAB\linuxadmins`, `LAB\linuxusers`, `LAB\Domain Admins`, `BUILTIN\Administrators`.
  - `Deny log on locally` i `Deny log on through Remote Desktop Services` → `LAB\service02`.
- Zweryfikowałem GPO przez `Get-GPOReport -ReportType Xml`: wszystkie cztery SID-y (`SeInteractiveLogonRight`, `SeRemoteInteractiveLogonRight`, `SeDenyInteractiveLogonRight`, `SeDenyRemoteInteractiveLogonRight`) mają właściwe członkostwo, `<LinksTo>` wskazuje `lab.local/Lab/Linux Systems`, `Enabled: true`.
- Na **rhel-web01** i na **ubuntu-ws02** dopisałem w `[domain/lab.local]` w `/etc/sssd/sssd.conf` linię `ad_gpo_access_control = enforcing`, `sssctl config-check` → 0 issues, SSSD zrestartowany, aktywny.
- Przeprowadziłem matrycę SSH na obu hostach: `testuser01` (linuxadmins) → OK, `testuser02` (linuxusers) → OK, `service02` → `Connection closed`.

---
#### Why - Dlaczego to zrobiłem?

Cel: przenieść kontrolę dostępu logon do Linux-hostów z rozproszonej konfiguracji per-host (`realm permit` w `sssd.conf`) na centralną politykę w AD, wspólną dla całego OU. Takie podejście jest standardem w środowiskach enterprise: audyt, zmiana i delegacja polityki dzieją się w jednym miejscu (GPMC), a nowe hosty dodane do `OU=Linux Systems` dziedziczą politykę automatycznie bez dotykania ich lokalnej konfiguracji. SSSD z `ad_gpo_access_control = enforcing` jest natywnym interpreterem tych samych User Rights Assignment, których Windows używa od zawsze — polityka jest spójna konceptualnie między Windows a Linux.

---
#### Result - Co dzięki temu uzyskałem?

- Pojedyncze miejsce w AD sterujące dostępem SSH do wszystkich linuksowych hostów w `OU=Linux Systems`.
- Zweryfikowane egzekwowanie na obu hostach: członkowie `linuxadmins`/`linuxusers` mają SSH, `service02` (poza grupami) jest odrzucony. Identyczny rezultat na RHEL i Ubuntu przy różnych wersjach SSSD (2.9 vs 2.6).
- Dowód, że GPO jest autorytatywne: `service02` jest denied także na `ubuntu-ws02`, gdzie **nigdy** nie było `realm permit` — znaczy że decyzja pochodzi wyłącznie z polityki AD.

---
#### Lesson Learned - Co się nauczyłem?

- SSSD mapuje `SeInteractiveLogonRight` na logowanie konsolowe, a **`SeRemoteInteractiveLogonRight` na SSH**. Zawsze trzeba ustawić **oba** prawa razem (i odpowiedniki deny), inaczej albo console, albo SSH nie będzie działać.
- Włączenie `ad_gpo_access_control = enforcing` całkowicie wyłącza mechanizm `simple_allow_groups`/`realm permit`. To nie jest nadmiarowa warstwa, tylko **zamiana** źródła decyzji. Po rollbacku `realm permit` z Kroku 4 znów staje się czynny.
- Edytor GPO wymusza `BUILTIN\Administrators` w `Allow log on locally` — nie ma jak tego obejść, na Linuksie bez znaczenia.
- `Invoke-GPUpdate` nie działa wobec Linuksa — refresh polityki po stronie SSSD następuje przy restarcie demona albo cyklicznie (`ad_gpo_cache_timeout`). Najpewniejszy sposób natychmiastowego odświeżenia po zmianie GPO: `sss_cache -E && systemctl restart sssd`.
- `/var/lib/sss/gpo_cache/` może być pusty mimo poprawnie działającej polityki. Dowodem działania są testy logowania, nie obecność plików w cache.
- `gpresult` na maszynie spoza OU nie pokaże polityki OU — to nie błąd, tylko prawidłowe filtrowanie SOM (Scope of Management).

---
#### Problem solved - Jakie problemy zostały rozwiązane?

- Asymetria polityki między hostami (`rhel-web01` miał `realm permit`, `ubuntu-ws02` nie miał — więc `service02` mógł się logować na Ubuntu) → ujednolicona polityka w GPO, `service02` odrzucany na obu.
- Per-host konfiguracja dostępu rozsiana po `sssd.conf` → centralnie w AD, edytowalna z jednej konsoli.
- Brak mechanizmu automatycznego obejmowania polityką nowo dołączonych hostów → każdy nowy komputer wrzucony do `OU=Linux Systems` dziedziczy politykę od razu po dołączeniu do SSSD z `ad_gpo_access_control = enforcing`.
- `BUILTIN\Administrators` blokujące zapis polityki → dodane zgodnie z wymaganiem Windowsa, bez wpływu na Linuksa.

---
## Step 7 — End-to-end verification: home directory auto-creation, full identity dump, deny evidence

**Uwaga:** podstawowa matryca allow/deny przez SSH została już wykonana w Kroku 6.4 (`testuser01`, `testuser02` → allowed; `service02` → `Connection closed` — na obu hostach). Ten krok dokłada weryfikację, która nie była jeszcze explicit: tworzenie katalogów domowych przez `pam_mkhomedir`/`oddjob-mkhomedir` przy pierwszym logowaniu oraz pełny dump tożsamości z poziomu realnej sesji (a nie wyłącznie `getent`/`id` z roota).

### 7.1 — Verify home directory auto-creation and full session identity on rhel-web01

Zalogować się w pełnej sesji (nie przez `ssh ... 'polecenie'`, tylko interactive), żeby PAM session stack wykonał `pam_oddjob_mkhomedir`.

```bash
# z hosta (lub z localhosta — root)
ssh testuser01@lab.local@rhel-web01.linux.lab.local
# wewnątrz sesji:
whoami
id
groups
pwd
ls -la ~
mount | grep "$(id -un)" || true
echo "hello from $(id -un) at $(date -Is)" > ~/hello.txt
cat ~/hello.txt
exit
```

Expected: `pwd` = `/home/testuser01@lab.local`, katalog utworzony automatycznie z `umask 0027`, `ls -la ~` pokazuje skopiowane pliki z `/etc/skel` (`.bashrc`, `.bash_logout`, `.profile` lub odpowiedniki), zapis do `~/hello.txt` działa z ownership = `testuser01@lab.local:domain users@lab.local`.

Powtórzyć dla `testuser02@lab.local` — powinien dostać `/home/testuser02@lab.local` z identyczną mechaniką.

### 7.2 — Verify home directory auto-creation and full session identity on ubuntu-ws02

To samo na Ubuntu — home path powinien być identyczny dzięki `fallback_homedir = /home/%u@%d` z Kroku 5.4.

```bash
ssh testuser01@lab.local@ubuntu-ws02.linux.lab.local
whoami
id
groups
pwd
ls -la ~
echo "hello from $(id -un) at $(date -Is)" > ~/hello.txt
cat ~/hello.txt
exit
```

Expected: `pwd` = `/home/testuser01@lab.local`, katalog utworzony przez `pam_mkhomedir.so` (Ubuntu używa go zamiast `pam_oddjob_mkhomedir`), zawartość z `/etc/skel`.

### 7.3 — Confirm identical UID/GID and home path across both hosts

Z dowolnego hosta — zweryfikować, że te same UID/GID-y i home path zwracają oba systemy dla tego samego użytkownika AD:

```bash
# na rhel-web01
id testuser01@lab.local
getent passwd testuser01@lab.local

# na ubuntu-ws02
id testuser01@lab.local
getent passwd testuser01@lab.local
```

Expected: identyczne `uid=264601103`, `gid=264600513`, `groups=...,264601602(linuxadmins@lab.local)` i home `/home/testuser01@lab.local` na obu hostach. To fundament pod LAB-07/08 (SMB/NFS) — plik utworzony na jednym hoście zachowa te same numeryczne uprawnienia na drugim.

### 7.4 — Deny evidence — SSH attempt log on both hosts

Sprawdzić, że deny jest rejestrowane w dziennikach audytu (to nie tylko "Connection closed" po stronie klienta — musi być ślad po stronie serwera, który pokaże **przyczynę** decyzji: GPO / access denied).

```bash
# rhel-web01
journalctl -u sshd --since "10 min ago" | grep -i "service02\|access\|denied"
# ubuntu-ws02
journalctl -u ssh --since "10 min ago" | grep -i "service02\|access\|denied"
```

Expected: widoczne `User service02@lab.local not allowed because account access denied` lub podobne z modułu `pam_sss`; ewentualnie `GPO access check failed`.

Result:
```
root@ubuntu-ws02:~# ssh -o StrictHostKeyChecking=no -l 'service02@lab.local' localhost 'whoami'
service02@lab.local@localhost's password:
Connection closed by 127.0.0.1 port 22

root@ubuntu-ws02:~# journalctl --since "2 min ago" | grep -iE 'service02|pam_sss|access.?denied'
Apr 22 11:11:49 ubuntu-ws02 sshd[28464]: pam_sss(sshd:auth): authentication success; ... user=service02@lab.local
Apr 22 11:11:49 ubuntu-ws02 sshd[28464]: pam_sss(sshd:account): Access denied for user service02@lab.local: 6 (Permission denied)
Apr 22 11:11:49 ubuntu-ws02 sshd[28464]: fatal: Access denied for user service02@lab.local by PAM account configuration [preauth]
...


[root@rhel-web01 ~]# ssh -o StrictHostKeyChecking=no -l 'service02@lab.local' localhost 'whoami'
service02@lab.local@localhost's password:
Connection closed by ::1 port 22

[root@rhel-web01 ~]# journalctl --since "2 min ago" | grep -iE 'service02|pam_sss|access.?denied'
Apr 22 13:11:33 rhel-web01 sshd[14823]: pam_sss(sshd:auth): authentication success; ... user=service02@lab.local
Apr 22 13:11:33 rhel-web01 sshd[14823]: pam_sss(sshd:account): Access denied for user service02@lab.local: 6 (Permission denied)
Apr 22 13:11:33 rhel-web01 sshd[14823]: fatal: Access denied for user service02@lab.local by PAM account configuration [preauth]
...
```

Key takeaway: `pam_sss(sshd:auth): authentication success` — hasło AD poprawne. Odrzucenie przychodzi dopiero na **etapie `account`** PAM-a, gdzie SSSD konsultuje GPO. To dokładnie dowód, że blokada to decyzja polityki dostępu (GPO), a nie błąd uwierzytelnienia.

---
### Notes

- **Auth vs account** — `pam_sss(sshd:auth): authentication success` + `pam_sss(sshd:account): Access denied` to kanoniczny ślad poprawnej pracy SSSD z `ad_gpo_access_control`. Hasło AD jest zweryfikowane przez Kerberos, ale polityka dostępu (GPO) blokuje w fazie `account`. Komunikat `fatal: ... by PAM account configuration` jest jednoznaczny.
- Home directory ma **różny domyślny mode** między hostami: RHEL → `drwx------` (0700), Ubuntu → `drwxr-x---` (0750). Wynika to z `UMASK` w `/etc/login.defs`/`pam_umask`, nie z konfiguracji SSSD. Jeśli zależy nam na ujednoliceniu (np. pod SMB/NFS), trzeba to wyrównać per-host.
- Różne zestawy skel: RHEL `/etc/skel` ma `.bash_profile` + `.bashrc` + `.bash_logout`; Ubuntu ma `.profile` + `.bashrc` + `.bash_logout` + `.cache/`. Na Ubuntu pierwszy login tworzy też `.cache/` od razu (systemd user slice + xdg).
- Na RHEL home tworzony przez `pam_oddjob_mkhomedir` (D-Bus do `oddjobd`), na Ubuntu przez bezpośredni `pam_mkhomedir.so` w `common-session`. Efekt końcowy identyczny — katalog istnieje po pierwszym logowaniu.
- `journalctl -u sshd`/`-u ssh` **nie pokazuje** komunikatów `pam_sss` — PAM loguje do głównego dziennika systemowego, nie do jednostki sshd. Trzeba użyć `journalctl --since ...` bez filtra jednostki, i dopiero potem `grep`.
- Kluczowa weryfikacja cross-host: ten sam user AD ma identyczne `uid/gid/groups/home/shell` na obu maszynach, co zapewnia deterministyczne ACL-e dla plików współdzielonych (fundament pod LAB-07/08).

---
### Conclusion

#### What - Co zrobiłem?

- W pełnej interaktywnej sesji SSH zalogowałem `testuser01@lab.local` i `testuser02@lab.local` na `rhel-web01`, potwierdzając automatyczne utworzenie katalogu domowego (`/home/<user>@lab.local`) przez `pam_oddjob_mkhomedir`, obecność plików z `/etc/skel` i poprawny ownership (`<user>@lab.local:domain users@lab.local`). Zapis do `~/hello.txt` zadziałał.
- Powtórzyłem to dla `testuser01@lab.local` na `ubuntu-ws02`: ta sama ścieżka home, ten sam UID/GID, ten sam ownership; home stworzony przez `pam_mkhomedir.so`, skel ubuntowy.
- Porównałem `id`/`getent passwd` dla `testuser01@lab.local` równolegle z obu hostów — wszystkie pola identyczne (UID `264601103`, GID `264600513`, grupa `linuxadmins@lab.local`, home `/home/testuser01@lab.local`, shell `/bin/bash`).
- Wywołałem świeżą próbę SSH dla `service02@lab.local` na obu hostach i z `journalctl` wyciągnąłem ślad PAM: `pam_sss(sshd:auth): authentication success` → `pam_sss(sshd:account): Access denied ... 6 (Permission denied)` → `fatal: Access denied by PAM account configuration`.

---
#### Why - Dlaczego to zrobiłem?

Poprzednie testy (Krok 6.4) potwierdziły, że allow/deny przez SSH działa w praktyce, ale nie weryfikowały dwóch rzeczy istotnych dla dalszych labów: (1) że automatyczne tworzenie katalogów domowych rzeczywiście działa przy pierwszym logowaniu na obu systemach (inne moduły PAM na RHEL i Ubuntu — `pam_oddjob_mkhomedir` vs `pam_mkhomedir.so`), (2) że tożsamość użytkownika AD jest bit-dokładnie identyczna na obu hostach (UID/GID/home/shell), co jest fundamentem dla spójnych ACL-i w SMB/NFS. Dodatkowo chciałem mieć jasny ślad w dzienniku pokazujący **etap PAM**, na którym następuje odrzucenie — `account`, nie `auth` — bo to w razie debugu rozróżnia "zły password" od "polityka nie pozwala".

---
#### Result - Co dzięki temu uzyskałem?

- Pełna, działająca integracja AD → Linux end-to-end: interaktywna sesja SSH z AD passwordem, auto-provisioning home, deterministyczna tożsamość między RHEL a Ubuntu.
- Twardy dowód, że blokada `service02` to decyzja polityki (GPO), a nie błąd auth — ślad `pam_sss(sshd:account): Access denied ... 6 (Permission denied)` identyczny na obu hostach.
- Identyczne `uid=264601103`, `gid=264600513`, home `/home/testuser01@lab.local` na obu hostach — przygotowane pod LAB-07 (Samba) i LAB-08 (SMB cross-host).

---
#### Lesson Learned - Co się nauczyłem?

- W PAM decyzja o dostępie składa się z kilku etapów. SSSD z `ad_gpo_access_control = enforcing` egzekwuje politykę na etapie **`account`**, nie `auth`. Diagnostyka powinna zawsze patrzeć na oba etapy osobno, żeby odróżnić "zły password" od "polityka odrzuca".
- `journalctl -u sshd` / `-u ssh` nie łapie komunikatów `pam_sss` — PAM loguje do głównego dziennika, nie do jednostki sshd. Właściwy filtr to `journalctl --since ...` bez `-u` plus grep na `pam_sss`/`account`/`denied`.
- Różny domyślny `UMASK` między dystrybucjami daje różny mode home-dir (RHEL `0700` vs Ubuntu `0750`). Mało kto o tym pamięta, a potrafi zaskoczyć przy współdzieleniu plików między hostami.
- Mechanizm auto-tworzenia home różni się implementacyjnie między RHEL (`pam_oddjob_mkhomedir` przez D-Bus) a Ubuntu (`pam_mkhomedir.so` bezpośrednio), ale od strony użytkownika końcowego jest nie do odróżnienia — oba działają deterministycznie przy pierwszym logowaniu.
- SID-based UID mapping (`ldap_id_mapping = True`) jest w praktyce niezawodny: ten sam user AD dostaje ten sam UID na każdym hoście, bez potrzeby ręcznego synchronizowania `/etc/passwd` ani centralnego NIS.

---
#### Problem solved - Jakie problemy zostały rozwiązane?

- Niepewność, czy `pam_mkhomedir` na Ubuntu zadziała z SSSD → potwierdzone, że tworzy home automatycznie przy pierwszym logowaniu.
- Podejrzenie, że "Connection closed" dla `service02` mogłoby być czymś innym niż świadomą decyzją polityki → log PAM pokazuje explicit `Access denied ... by PAM account configuration` z `pam_sss`.
- Niepotwierdzone założenie o identycznych UID-ach między RHEL a Ubuntu → zweryfikowane bit po bicie dla `testuser01@lab.local`.

---

## Step 8 — Write `centrify-vs-sssd.md` comparing Centrify DirectControl ↔ SSSD/realmd feature by feature

Deliverable: [`notes/centrify-vs-sssd.md`](./centrify-vs-sssd.md) — osobny dokument pokrywający porównanie feature-by-feature. Poniżej tylko mapa sekcji i interviewerskie talking points.

### 8.1 — Summarise the implemented Linux-AD workflow from this lab

Podsumowanie tego, co zostało faktycznie wdrożone w Krokach 1–7, zapisane jako punkt wyjścia porównania — patrz sekcja 1 (TL;DR) w `centrify-vs-sssd.md`. Baseline: `realmd` + `adcli` + SSSD na RHEL 9 i Ubuntu 22.04, computer accounts w `OU=Linux Systems`, GPO `Linux Access Policy` z `ad_gpo_access_control = enforcing`, SID-based UID mapping, `pam_oddjob_mkhomedir`/`pam_mkhomedir`.

### 8.2 — Compare join workflow, access control, and policy model: Centrify vs SSSD/realmd

Patrz sekcje 2–5 w `centrify-vs-sssd.md`:
- **Join workflow** (sekcja 2): `adjoin` vs `realm join`, pakiety, keytab, zone model.
- **Identity mapping** (sekcja 3): Centrify Zones (per-host UID assigned w AD) vs SSSD SID-based (`ldap_id_mapping = True`).
- **Access control** (sekcja 4): Centrify zone-role-command RBAC vs GPO User Rights Assignment + SSSD `ad_gpo_access_control`.
- **GPO/policy enforcement** (sekcja 5): Centrify GPO extensions (setki ustawień Unix-specific) vs SSSD (tylko `UserRightsAssignment` + ewentualnie Ansible/Puppet dla reszty).

Kluczowy wniosek: SSSD pokrywa ~80% funkcjonalności DirectControl dla standardowych scenariuszy login/SSH/Kerberos; braki to głównie **GPO dla Unix-specific ustawień** (sudo, hosts.allow, firewall) i **session recording/audit**, które w SSSD uzupełnia się zewnętrznymi narzędziami.

### 8.3 — Compare licensing, support model, and operational trade-offs

Patrz sekcje 7–9 w `centrify-vs-sssd.md`:
- **Deployment footprint** (sekcja 7): jeden daemon `adclient` vs `sssd` z workerami; repo vendora vs dystrybucja.
- **Licencing** (sekcja 8): roczny per-host subscription (~$20–50k rocznie dla 100 hostów) vs $0 licencji.
- **Audit** (sekcja 9): wbudowane Centrify DirectAudit (session recording + gotowe raporty PCI/SOX) vs `tlog` + auditd + SIEM (trzeba zbudować).

Trade-off strategiczny: Centrify = szybciej gotowe, vendor lock-in, wysokie koszty cykliczne. SSSD = więcej "klocków" do złożenia, brak lock-in, koszty głównie operacyjne. Po przejęciu Centrify przez Delinea w 2021 r. i niestabilności roadmapy, rynek migruje w stronę SSSD/FreeIPA.

### 8.4 — Prepare interview-ready conclusions and talking points

Patrz sekcje 10–12 w `centrify-vs-sssd.md` — migracja Centrify→SSSD, matryca "kiedy wybrać co", oraz gotowe pytania rozmowy kwalifikacyjnej (`realm join` vs `adjoin`, SID-based UID mapping, PAM auth vs account stage, allow/deny przez GPO).

---
### Notes

- Dokument `centrify-vs-sssd.md` jest napisany tak, żeby dał się czytać samodzielnie — nie zakłada przeczytania całego LAB-05. Punkt odniesienia to jednak baseline z tego labu (co faktycznie wdrożyłem), nie abstrakcyjna wiedza.
- Centrify DirectControl w 2026 r. formalnie nazywa się Delinea Server Suite / Authentication Suite (po przejęciu w 2021). W dokumencie zostawiam historyczną nazwę "Centrify", bo tak funkcjonuje w większości materiałów referencyjnych i rozmów technicznych.
- Skupiłem się na wymiarach, które mają realne znaczenie w decyzji wdrożeniowej (join, identity, access, GPO, audit, licensing), pomijając marginalne różnice (np. szczegóły konfiguracji `centrifydc.conf`).
- Brakujące w SSSD funkcje, które Centrify miał natywnie, da się złożyć z komponentów open-source: SSSD + FreeIPA (HBAC, sudo rules) + Ansible/Puppet (config drift) + tlog/auditd + SIEM (audit). Całość pokrywa ~95% use-case'ów Centrify przy 0 kosztach licencyjnych.

---
### Conclusion

#### What - Co zrobiłem?

- Napisałem [`notes/centrify-vs-sssd.md`](./centrify-vs-sssd.md) — 12-sekcyjny dokument porównawczy Centrify DirectControl vs SSSD/realmd, bazujący na faktycznym wdrożeniu z Kroków 1–7 tego labu.
- Pokryłem: join workflow, identity mapping, access control, GPO, Kerberos SSO, deployment, licensing, audit, migration path, rekomendacje "kiedy wybrać co", talking points na rozmowę kwalifikacyjną.
- Wpiąłem dokument do LAB-05 (Step 8) z mapą sekcji, żeby ułatwić nawigację.

---
#### Why - Dlaczego to zrobiłem?

Dwa cele: (1) **utrwalić wiedzę** — po wdrożeniu realnego SSSD w tym labie potrafię teraz rzetelnie zestawić go z komercyjną alternatywą, nie na podstawie marketingu, tylko własnego hands-on doświadczenia; (2) **mieć gotowy materiał na rozmowy kwalifikacyjne** — pytanie "czym różni się realmd od Centrify" pada regularnie w Linux-admin interviews dla ról mid/senior, szczególnie w firmach, które migrują z Centrify albo rozważają migrację.

---
#### Result - Co dzięki temu uzyskałem?

- Gotowy, samoistny dokument referencyjny w repo.
- Klarowny mental model: SSSD jest default'em, Centrify to niche dla konkretnych wymagań (zone-based UID, audit, GPO-for-Unix).
- Interview-ready talking points — odpowiedzi na typowe pytania, ugruntowane w wykonanym labie, nie w abstrakcyjnej teorii.

---
#### Lesson Learned - Co się nauczyłem?

- Zone-based identity model w Centrify jest historycznie sensowny (pre-2010 AD-UNIX mapping był ręczny i bolesny), ale SID-based mapping w SSSD go rozwiązuje deterministycznie i za darmo. Tego praktycznie nie widać, dopóki nie potrzebujesz **różnych** UID-ów dla tego samego usera w różnych częściach infrastruktury (legacy use-case).
- Braki SSSD vs Centrify są reale (advanced GPO dla Unix, native session recording), ale w 2026 r. wszystkie mają akceptowalne substytuty open-source (FreeIPA HBAC, Ansible, tlog, SIEM).
- "Vendor lock-in" nie jest przy Centrify pustym frazesem — migracja 100+ hostów wymaga planowania UID-ów, keytabów, PAM config i sudoers; to tygodnie pracy, nie dni.
- Po przejęciu Centrify przez Delinea cykl wydań i roadmap stały się nieprzewidywalne, co stanowi samodzielny argument za migracją nawet bez względu na koszty licencji.

---
#### Problem solved - Jakie problemy zostały rozwiązane?

- Niejasność "co właściwie SSSD oferuje w porównaniu z komercyjnymi alternatywami" → teraz jest feature-by-feature matryca z konkretnymi przykładami z własnego wdrożenia.
- Brak konkretnego materiału pod rozmowy kwalifikacyjne → dokument ma sekcję `Interview-ready talking points` z gotowymi, krótkimi odpowiedziami.
- Niepewność co do ścieżki migracji z Centrify do SSSD → sekcja 10 opisuje realistyczny plan (rolling per-zone/per-host, bez AD downtime).

---

## LAB-05 — Conclusion

### What - Co zrobiłem?

- **Krok 1:** Zainstalowałem i zweryfikowałem toolchain AD na RHEL 9 (`rhel-web01`): `realmd`, `sssd`, `sssd-tools`, `adcli`, `oddjob`, `oddjob-mkhomedir`, `authselect`, `krb5-workstation`, `samba-common-tools`.
- **Krok 2:** Skonfigurowałem pre-requisity: DNS (host używa `rhel-srv01` → forwarder do AD), FQDN `rhel-web01.linux.lab.local`, Kerberos (`krb5.conf` z `default_realm = LAB.LOCAL`), synchronizacja czasu (chrony ze źródłem AD).
- **Krok 3:** Dołączyłem `rhel-web01` do domeny `lab.local` przez `realm join -U Administrator`; obiekt komputera w `CN=Computers,DC=lab,DC=local`, keytab wypełniony SPN-ami `host/` i `RestrictedKrbHost/`, `authselect select sssd with-mkhomedir` ustawił PAM/NSS.
- **Krok 4:** Utworzyłem w AD grupy `linuxadmins`/`linuxusers`, konta `testuser01`/`testuser02`/`service02`, nadałem członkostwo; na Linuksie `realm permit -g linuxadmins linuxusers` skonfigurowało `simple_allow_groups` w `sssd.conf`; w Windowsie przeniosłem `RHEL-WEB01` do `OU=Linux Systems,OU=Lab,DC=lab,DC=local`.
- **Krok 5:** Powtórzyłem całość dla `ubuntu-ws02` (Ubuntu 22.04 LTS): naprawa netplan/cloud-init DNS, instalacja pakietów dla Ubuntu (`sssd-ad`, `libnss-sss`, `libpam-sss`, `pam-auth-update --enable mkhomedir`), `realm join`, ręczne dopisanie `use_fully_qualified_names = True` + `fallback_homedir = /home/%u@%d` + `default_shell = /bin/bash` (Ubuntu nie ustawia tych pól sam, w odróżnieniu od RHEL-a), przeniesienie do OU.
- **Krok 6:** Utworzyłem GPO `Linux Access Policy` podpięte do `OU=Linux Systems` z User Rights Assignment (Allow/Deny log on locally + through Remote Desktop Services dla linuxadmins/linuxusers/Domain Admins/Administrators i service02 w deny); na obu hostach Linux włączyłem `ad_gpo_access_control = enforcing`; zweryfikowałem matrycę SSH allow/deny.
- **Krok 7:** Potwierdziłem w pełnej sesji SSH automatyczne tworzenie home dir (`pam_oddjob_mkhomedir` na RHEL, `pam_mkhomedir.so` na Ubuntu), spójność UID/GID/home między hostami (SID-based mapping), i ślad deny w PAM (`pam_sss(sshd:account): Access denied ... 6 (Permission denied)`) jako twardy dowód egzekwowania GPO.
- **Krok 8:** Napisałem `notes/centrify-vs-sssd.md` — feature-by-feature porównanie Centrify DirectControl ↔ SSSD/realmd oparte o własne wdrożenie.

---
### Why - Dlaczego to zrobiłem?

Integracja Linuksa z Active Directory jest jednym z najczęstszych zadań w heterogenicznych środowiskach enterprise — gdy AD pozostaje centralnym directory dla użytkowników, a Linux obsługuje usługi (web, DB, app servers). Bez tej integracji każdy Linux-host ma osobną bazę kont i haseł, co łamie single-sign-on, komplikuje offboarding i uniemożliwia spójny audit. LAB-05 miał pokryć pełny cykl: od pakietów i DNS, przez join i PAM, po centralną politykę dostępu w GPO — tak, żebym znał każdą warstwę stacku, nie tylko przepisywał komendy. Dodatkowo walidacja na **dwóch** różnych dystrybucjach (RHEL 9 + Ubuntu 22.04) pokazała realne różnice implementacyjne (authselect vs pam-auth-update, oddjob vs pam_mkhomedir, domyślne wartości `sssd.conf`), które w produkcji są źródłem najczęstszych potknięć.

---
### Result - Co dzięki temu uzyskałem?

- **Działającą end-to-end integrację AD → Linux na dwóch dystrybucjach**: logowanie SSH hasłem AD, Kerberos SSO, auto-provisioning home, allow/deny przez politykę w AD.
- **Spójny model tożsamości**: `testuser01@lab.local` ma UID `264601103` i home `/home/testuser01@lab.local` na obu hostach — fundament pod LAB-07 (Samba) i LAB-08 (SMB cross-host).
- **Centralną politykę dostępu w GPO** podpiętą do `OU=Linux Systems`: dodanie kolejnych Linux-hostów = automatyczne objęcie polityką, bez ruszania ich lokalnej konfiguracji.
- **Dwa computer accounts** w docelowym `OU=Linux Systems,OU=Lab,DC=lab,DC=local` (`RHEL-WEB01`, `UBUNTU-WS02`), gotowe na kolejne GPO i organizacyjne zmiany.
- **Dokument `centrify-vs-sssd.md`** — gotowe source-of-truth do decyzji stack-level i do rozmów kwalifikacyjnych.

---
### Lesson Learned - Co się nauczyłem?

- **RHEL i Ubuntu realizują tę samą integrację różnymi narzędziami**: `authselect` vs `pam-auth-update`, `pam_oddjob_mkhomedir` vs `pam_mkhomedir.so`, inne domyślne zestawy `sssd.conf` (RHEL ustawia `use_fully_qualified_names = True`, Ubuntu nie). Dokumentacja upstream miesza te drogi, więc trzeba wiedzieć, gdzie szukać na danej dystrybucji.
- **SID-based UID mapping (`ldap_id_mapping = True`) jest w praktyce niezawodny**: ten sam SID → ten sam UID na każdym hoście, deterministycznie, bez potrzeby synchronizacji `/etc/passwd` ani dodawania `uidNumber` do atrybutów AD. To czyni cały scenariusz "identyczny user na wielu hostach" trywialnym.
- **GPO w SSSD to przede wszystkim User Rights Assignment**: `Allow/Deny log on locally` i `Allow/Deny log on through Remote Desktop Services` (ten ostatni mapuje na SSH). Inne sekcje GPO (`Administrative Templates`, kompletna polityka komputera) są ignorowane — do nich trzeba dodać Ansible/Puppet albo FreeIPA HBAC.
- **PAM ma kilka osobnych etapów**: `auth` (hasło) i `account` (polityka) to różne punkty decyzyjne. SSSD z enforcing GPO odrzuca w `account`, nie w `auth` — `pam_sss(sshd:auth): authentication success` + `pam_sss(sshd:account): Access denied` to kanoniczny ślad. Debug dowolnego access-denied musi zaczynać od rozróżnienia, który etap zawiódł.
- **Kolejność domen w `search:` i w `ldap_search_base` wpływa na resolve**: na Ubuntu 22.04 cloud-init generuje pierwotnie `search:` z samym IP DNS-a, co łamie resolve krótkich hostname'ów. Wymagało naprawy netplan + wyłączenia regeneracji przez cloud-init (`99-disable-network-config.cfg`).
- **`realm permit` vs `ad_gpo_access_control = enforcing` nie są addytywne** — włączenie GPO enforcing **zastępuje** `simple_allow_groups`, nie dokłada do niego. Przy rollbacku trzeba mieć to świadomie na uwadze, żeby nie odzyskać niespodziewanego allow.
- **`/var/lib/sss/gpo_cache/` bywa pusty mimo działającej polityki** — na tych wersjach SSSD decyzje są podejmowane on-the-fly bez zapisu `.pol`. Dowodem poprawności są **testy logowania**, nie zawartość cache.

---
### Problem solved - Jakie problemy zostały rozwiązane?

- **Brak centralnego directory dla Linux-hostów** → AD + SSSD: jedna baza użytkowników/grup/haseł, SSO przez Kerberos.
- **Rozproszona konfiguracja dostępu (`realm permit` per host, lokalne accounty)** → centralna polityka w GPO na `OU=Linux Systems`, zarządzana przez GPMC, automatycznie dziedziczona przez nowe hosty.
- **Asymetria między RHEL a Ubuntu** (inne narzędzia PAM/NSS, inne defaulty `sssd.conf`) → spójna konfiguracja: `user@lab.local` jako login, `/home/%u@%d` jako home, te same UID-y, identyczny matrix allow/deny.
- **Błędna konfiguracja DNS/netplan po cloud-init** na świeżej VM Ubuntu → naprawa + trwałe wyłączenie regeneracji.
- **Brak dowodu, że deny jest świadomą decyzją polityki** → wymuszenie świeżej próby SSH + odczyt `journalctl` pokazał explicit `pam_sss(sshd:account): Access denied ... by PAM account configuration`.
- **Brak materiału porównawczego Centrify vs SSSD** → `notes/centrify-vs-sssd.md` jako standalone dokument.
