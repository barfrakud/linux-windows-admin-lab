# LAB-04: LDAP — 389 Directory Server

**Status:** In Progress
**Machine:** rhel-srv01 (server); repo-srv01, ubuntu-ws01 (SSSD clients)
**Reference:** [lab-plan.md — LAB-04](../lab-plan.md)

### Lab context

| Element | Value |
|---|---|
| Server | rhel-srv01 (10.10.10.20) |
| RHEL Client | repo-srv01 (10.10.10.50) |
| Ubuntu Client | ubuntu-ws01 (10.10.10.30) |
| Server OS | Rocky Linux 9 (LXC) |
| Prerequisite | rhel-srv01 post-LAB-01 (Bind DNS running). repo-srv01 and ubuntu-ws01 post-LAB-00 (fresh). Proxmox snapshots taken before starting. |
| Base DN | dc=linux,dc=lab,dc=local |

**End state after this lab:**
- 389 Directory Server running on rhel-srv01 with TLS enabled
- DIT structure with OUs for People, Groups, Services
- Test users and groups populated via LDIF files
- ACL policies restricting access per bind DN
- SSSD configured on repo-srv01 (RHEL) and ubuntu-ws01 (Ubuntu) authenticating against LDAP
- System login verified with LDAP users on both clients over TLS
- Cockpit with cockpit-389-ds plugin installed for visual DIT exploration

---

## Step 1 — Install and initialise 389 Directory Server instance on rhel-srv01

### 1.1 — Install 389 Directory Server packages

```bash
dnf install -y 389-ds-base
```

Verify:
```bash
rpm -q 389-ds-base
dsctl --help | head -1
```

Result:
```
[root@rhel-srv01 ~]# rpm -q 389-ds-base
389-ds-base-2.7.0-12.el9_7.x86_64
```

### 1.2 — Create 389DS instance using dscreate

Create an INF template for instance creation:
```bash
cat > /root/ds-setup.inf << 'EOF'
[general]
config_version = 2
full_machine_name = rhel-srv01.linux.lab.local
start = True

[slapd]
instance_name = localhost
root_dn = cn=Directory Manager
root_password = <dm_password>
port = 389
secure_port = 636

[backend-userroot]
suffix = dc=linux,dc=lab,dc=local
sample_entries = no
EOF
```

Run instance creation:
```bash
dscreate from-file /root/ds-setup.inf
```

Verify instance is running:
```bash
dsctl localhost status
ss -tlnp | grep -E '389|636'
```

Result:
```
[root@rhel-srv01 ~]# dscreate from-file /root/ds-setup.inf
Starting installation ...
Validate installation settings ...
Create file system structures ...
Create self-signed certificate database ...
SELinux is disabled, will not relabel ports or files.
SELinux is disabled, will not relabel ports or files.
Create database backend: dc=linux,dc=lab,dc=local ...
Perform post-installation tasks ...
Completed installation for instance: slapd-localhost

[root@rhel-srv01 ~]# dsctl localhost status
Instance "localhost" is running

[root@rhel-srv01 ~]# ss -tlnp | grep -E '389|636'
LISTEN 0      10       10.10.10.20:53        0.0.0.0:*    users:(("named",pid=186,fd=389))
LISTEN 0      128                *:389             *:*    users:(("ns-slapd",pid=1011,fd=8))
LISTEN 0      128                *:636             *:*    users:(("ns-slapd",pid=1011,fd=9))

```

### 1.3 — Verify Directory Manager bind

```bash
ldapsearch -x -H ldap://localhost -D "cn=Directory Manager" -W -b "dc=linux,dc=lab,dc=local" -s base
ldapwhoami -x -H ldap://localhost -D "cn=Directory Manager" -W
```

Result:
```
[root@rhel-srv01 ~]# ldapsearch -x -H ldap://localhost -D "cn=Directory Manager" -W -b "dc=linux,dc=lab,dc=local" -s base
Enter LDAP Password: 
# extended LDIF
#
# LDAPv3
# base <dc=linux,dc=lab,dc=local> with scope baseObject
# filter: (objectclass=*)
# requesting: ALL
#

# search result
search: 2
result: 32 No such object

# numResponses: 1
[root@rhel-srv01 ~]# 

[root@rhel-srv01 ~]# ldapwhoami -x -H ldap://localhost -D "cn=Directory Manager" -W
Enter LDAP Password: 
dn: cn=directory manager
```

### 1.4 — Enable and verify systemd service

```bash
systemctl enable dirsrv@localhost
systemctl status dirsrv@localhost
```

Result:
```
```

### 1.5 — Open firewall ports

```bash
firewall-cmd --permanent --add-service=ldap
firewall-cmd --permanent --add-service=ldaps
firewall-cmd --reload
firewall-cmd --list-services
```

Result:
```
[root@rhel-srv01 ~]# firewall-cmd --list-services
cockpit dhcpv6-client dns ssh
[root@rhel-srv01 ~]# firewall-cmd --permanent --add-service=ldap
success
[root@rhel-srv01 ~]# firewall-cmd --permanent --add-service=ldaps
success
[root@rhel-srv01 ~]# firewall-cmd --reload
success
[root@rhel-srv01 ~]# firewall-cmd --list-services
cockpit dhcpv6-client dns ldap ldaps ssh
```

---
### Notes

Zainstalowałem pakiet `389-ds-base` 2.7.0 z repozytorium Rocky Linux 9. Utworzyłem plik INF z konfiguracją instancji (instance_name=localhost, suffix=dc=linux,dc=lab,dc=local, sample_entries=no) i uruchomiłem `dscreate from-file`. Instancja uruchomiła się automatycznie — `ns-slapd` nasłuchuje na portach 389 (LDAP) i 636 (LDAPS). Bind jako Directory Manager działa (`ldapwhoami` zwraca `dn: cn=directory manager`), natomiast `ldapsearch` na suffix zwraca `result: 32 No such object` — to oczekiwane, bo backend jest pusty (sample_entries=no). Włączyłem autostart (`systemctl enable dirsrv@localhost`) i otworzyłem porty LDAP/LDAPS w firewalld.

Przed instalacją wystąpił problem z DNS — `resolv.conf` wskazywał na Windows DC (10.10.10.10) zamiast na lokalny Bind (127.0.0.1), co blokowało resolucję mirrorów Rocky Linux. Naprawione przez `nmcli con mod` z `ipv4.dns 127.0.0.1` i `ipv4.ignore-auto-dns yes`. Dodano lesson learned w notatce LAB-01 o trwałym ustawieniu resolvera przez `pct set` na Proxmoxie.

---
### Conclusion

#### What - Co zrobiłem?
Instalacja pakietu `389-ds-base` 2.7.0 na rhel-srv01 (LXC), utworzenie instancji 389DS za pomocą `dscreate from-file` z plikiem INF (suffix: `dc=linux,dc=lab,dc=local`, root_dn: `cn=Directory Manager`). Włączenie autostartu usługi `dirsrv@localhost` i otwarcie portów 389/636 w firewalld. Naprawa resolvera DNS (`resolv.conf` wskazywał na Windows DC zamiast na lokalny Bind).

---
#### Why - Dlaczego to zrobiłem?
389 Directory Server to cel LAB-04 (gap G6 — LDAP). Instancja musi działać przed konfiguracją DIT, użytkowników i klientów SSSD. Autostart zapewnia dostępność po restarcie kontenera. Porty LDAP/LDAPS muszą być otwarte, żeby klienci (repo-srv01, ubuntu-ws01) mogli się łączyć.

---
#### Result - Co dzięki temu uzyskałem?
389DS działa na rhel-srv01 — `ns-slapd` nasłuchuje na portach 389 (LDAP) i 636 (LDAPS), usługa uruchamia się automatycznie, firewall przepuszcza ruch LDAP. Directory Manager bind działa. Backend jest pusty — gotowy do wypełnienia w Step 2.

---
#### Lesson Learned - Co się nauczyłem?
- **`dscreate from-file`** to zalecaną metodą tworzenia instancji 389DS — plik INF jest powtarzalny i dokumentowalny (w odróżnieniu od interaktywnego `dscreate interactive`).
- **`sample_entries = no`** tworzy pusty backend — suffix istnieje jako konfiguracja, ale nie ma żadnego wpisu w drzewie. `ldapsearch` zwraca `result: 32 No such object`, co jest poprawne (nie mylić z błędem autentykacji `result: 49`).
- **`ldapwhoami`** to szybki sposób na weryfikację bind — zwraca DN zalogowanego użytkownika bez przeszukiwania drzewa.
- **Usługa `dirsrv@localhost`** — 389DS używa instancyjnych unitów systemd (template unit `dirsrv@.service`). Nazwa po `@` odpowiada `instance_name` z INF.
- **Resolver DNS na LXC** — `nmcli con mod` zmienia konfigurację NetworkManager, ale Proxmox może nadpisać `/etc/resolv.conf` przy restarcie kontenera. Trwała naprawa wymaga `pct set <CTID> --nameserver` na hoście Proxmox.
- **SELinux w LXC** — `dscreate` wykrywa brak SELinux i pomija relabeling (`SELinux is disabled, will not relabel ports or files`). Na pełnej VM z SELinux enforcing wymagałby kontekstów `dirsrv_t`.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
- **DNS resolver na rhel-srv01** — `resolv.conf` wskazywał na Windows DC (10.10.10.10) zamiast na lokalny Bind (127.0.0.1). `dnf` nie mógł rozwiązać `mirrors.rockylinux.org`. Przyczyna: po restarcie LXC NetworkManager/Proxmox nadpisał ustawienia z LAB-01. Rozwiązanie: `nmcli con mod` z `ipv4.dns 127.0.0.1` i `ipv4.ignore-auto-dns yes` + `pct set 103 --nameserver 10.10.10.20` na hoście Proxmox.

---

## Step 2 — Build DIT structure: base DN, OUs for People, Groups, Services

### 2.1 — Create base suffix entry

The suffix `dc=linux,dc=lab,dc=local` exists as a backend configuration, but has no actual LDAP entry (because `sample_entries = no`). Create it first:

```bash
cat > /root/ldap/base-dn.ldif << 'EOF'
dn: dc=linux,dc=lab,dc=local
objectClass: top
objectClass: domain
dc: linux
description: Linux Lab LDAP Directory
EOF
```

```bash
ldapadd -x -H ldap://localhost -D "cn=Directory Manager" -W -f /root/ldap/base-dn.ldif
```

Verify:
```bash
ldapsearch -x -H ldap://localhost -D "cn=Directory Manager" -W -b "dc=linux,dc=lab,dc=local" -s base
```

Result:
```
[root@rhel-srv01 ~]# cat > /root/ldap/base-dn.ldif << 'EOF'
dn: dc=linux,dc=lab,dc=local
objectClass: top
objectClass: domain
dc: linux
description: Linux Lab LDAP Directory
EOF
[root@rhel-srv01 ~]# ldapadd -x -H ldap://localhost -D "cn=Directory Manager" -W -f /root/ldap/base-dn.ldif
Enter LDAP Password: 
adding new entry "dc=linux,dc=lab,dc=local"

[root@rhel-srv01 ~]# ldapsearch -x -H ldap://localhost -D "cn=Directory Manager" -W -b "dc=linux,dc=lab,dc=local" -s base
Enter LDAP Password: 
# extended LDIF
#
# LDAPv3
# base <dc=linux,dc=lab,dc=local> with scope baseObject
# filter: (objectclass=*)
# requesting: ALL
#

# linux.lab.local
dn: dc=linux,dc=lab,dc=local
objectClass: top
objectClass: domain
dc: linux
description: Linux Lab LDAP Directory

# search result
search: 2
result: 0 Success

# numResponses: 2
# numEntries: 1
```

### 2.2 — Create organizational units

```bash
cat > /root/ldap/base-ous.ldif << 'EOF'
dn: ou=People,dc=linux,dc=lab,dc=local
objectClass: organizationalUnit
ou: People
description: User accounts

dn: ou=Groups,dc=linux,dc=lab,dc=local
objectClass: organizationalUnit
ou: Groups
description: POSIX groups

dn: ou=Services,dc=linux,dc=lab,dc=local
objectClass: organizationalUnit
ou: Services
description: Service accounts and bind DNs
EOF
```

```bash
ldapadd -x -H ldap://localhost -D "cn=Directory Manager" -W -f /root/ldap/base-ous.ldif
```

Result:
```
[root@rhel-srv01 ~]# cat > /root/ldap/base-ous.ldif << 'EOF'
dn: ou=People,dc=linux,dc=lab,dc=local
objectClass: organizationalUnit
ou: People
description: User accounts

dn: ou=Groups,dc=linux,dc=lab,dc=local
objectClass: organizationalUnit
ou: Groups
description: POSIX groups

dn: ou=Services,dc=linux,dc=lab,dc=local
objectClass: organizationalUnit
ou: Services
description: Service accounts and bind DNs
EOF
[root@rhel-srv01 ~]# ldapadd -x -H ldap://localhost -D "cn=Directory Manager" -W -f /root/ldap/base-ous.ldif
Enter LDAP Password: 
adding new entry "ou=People,dc=linux,dc=lab,dc=local"

adding new entry "ou=Groups,dc=linux,dc=lab,dc=local"

adding new entry "ou=Services,dc=linux,dc=lab,dc=local"
```

### 2.3 — Verify DIT structure

```bash
ldapsearch -x -H ldap://localhost -D "cn=Directory Manager" -W -b "dc=linux,dc=lab,dc=local" -s one "(objectClass=organizationalUnit)" dn ou description
```

Result:
```
[root@rhel-srv01 ~]# ldapsearch -x -H ldap://localhost -D "cn=Directory Manager" -W -b "dc=linux,dc=lab,dc=local" -s one "(objectClass=organizationalUnit)" dn ou description
Enter LDAP Password: 
# extended LDIF
#
# LDAPv3
# base <dc=linux,dc=lab,dc=local> with scope oneLevel
# filter: (objectClass=organizationalUnit)
# requesting: dn ou description
#

# People, linux.lab.local
dn: ou=People,dc=linux,dc=lab,dc=local
ou: People
description: User accounts

# Groups, linux.lab.local
dn: ou=Groups,dc=linux,dc=lab,dc=local
ou: Groups
description: POSIX groups

# Services, linux.lab.local
dn: ou=Services,dc=linux,dc=lab,dc=local
ou: Services
description: Service accounts and bind DNs

# search result
search: 2
result: 0 Success

# numResponses: 4
# numEntries: 3
```

---
### Notes

Utworzyłem wpis bazowy suffix `dc=linux,dc=lab,dc=local` (objectClass: domain) za pomocą LDIF + `ldapadd`, a następnie trzy jednostki organizacyjne: People (konta użytkowników), Groups (grupy POSIX), Services (konta serwisowe i bind DN). Weryfikacja `ldapsearch -s one` potwierdza 3 OUs pod base DN. Pliki LDIF zapisane w `/root/ldap/` (base-dn.ldif, base-ous.ldif).

---
### Conclusion

#### What - Co zrobiłem?
Utworzenie wpisu bazowego `dc=linux,dc=lab,dc=local` (krok 2.1) i trzech jednostek organizacyjnych: `ou=People`, `ou=Groups`, `ou=Services` (krok 2.2). Weryfikacja struktury DIT za pomocą `ldapsearch` z filtrem `(objectClass=organizationalUnit)` (krok 2.3).

---
#### Why - Dlaczego to zrobiłem?
DIT (Directory Information Tree) to hierarchiczna struktura katalogu LDAP. Wpis bazowy musi istnieć, zanim można dodawać podrzędne wpisy (OUs). Rozdzielenie na People/Groups/Services to standardowa konwencja — ułatwia zarządzanie ACL (np. SSSD szuka użytkowników tylko w `ou=People`), odpowiada strukturze typowego enterprise directory.

---
#### Result - Co dzięki temu uzyskałem?
Kompletna struktura DIT gotowa do populacji danymi w Step 3:
- `dc=linux,dc=lab,dc=local` — root
- `ou=People` — docelowo konta użytkowników (posixAccount)
- `ou=Groups` — docelowo grupy POSIX (posixGroup)
- `ou=Services` — docelowo konta serwisowe (bind DN dla SSSD, backup)

---
#### Lesson Learned - Co się nauczyłem?
- **`sample_entries = no`** w INF tworzy backend, ale nie wpis bazowy suffix. Trzeba go dodać ręcznie przez LDIF — bez niego `ldapadd` na OUs zwróci `result: 32 No such object` (parent entry nie istnieje).
- **Kolejność w LDIF ma znaczenie** — parent entry musi istnieć przed child. Dlatego base DN → OUs → users, a nie odwrotnie.
- **`-s one`** (scope oneLevel) w `ldapsearch` zwraca tylko bezpośrednie dzieci danego base DN — przydatne do weryfikacji struktury bez zanurzania się w poddrzewa.
- **objectClass `domain`** dla wpisu bazowego — to minimalna klasa dla wpisu typu `dc=...`. Alternatywy: `organization` (dla `o=...`) lub `dcObject` + `organization` jeśli potrzebny atrybut `o`.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
Brak problemów w tym kroku.

---

## Step 3 — Populate users and groups using LDIF files

### 3.1 — Create POSIX groups

```bash
cat > /root/ldap/groups.ldif << 'EOF'
dn: cn=linuxadmins,ou=Groups,dc=linux,dc=lab,dc=local
objectClass: posixGroup
cn: linuxadmins
gidNumber: 10001
description: Linux administrators

dn: cn=linuxusers,ou=Groups,dc=linux,dc=lab,dc=local
objectClass: posixGroup
cn: linuxusers
gidNumber: 10002
description: Regular Linux users

dn: cn=serviceaccounts,ou=Groups,dc=linux,dc=lab,dc=local
objectClass: posixGroup
cn: serviceaccounts
gidNumber: 10003
description: Service accounts
EOF
```

```bash
ldapadd -x -H ldap://localhost -D "cn=Directory Manager" -W -f /root/ldap/groups.ldif
```

Result:
```
[root@rhel-srv01 ~]# ldapadd -x -H ldap://localhost -D "cn=Directory Manager" -W -f /root/ldap/groups.ldif
Enter LDAP Password: 
adding new entry "cn=linuxadmins,ou=Groups,dc=linux,dc=lab,dc=local"

adding new entry "cn=linuxusers,ou=Groups,dc=linux,dc=lab,dc=local"

adding new entry "cn=serviceaccounts,ou=Groups,dc=linux,dc=lab,dc=local"
```

### 3.2 — Create test users with POSIX attributes

```bash
cat > /root/ldap/users.ldif << 'EOF'
dn: uid=jkowalski,ou=People,dc=linux,dc=lab,dc=local
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
uid: jkowalski
cn: Jan Kowalski
sn: Kowalski
givenName: Jan
mail: jkowalski@linux.lab.local
uidNumber: 20001
gidNumber: 10001
homeDirectory: /home/jkowalski
loginShell: /bin/bash
userPassword: {SSHA}placeholder

dn: uid=anowak,ou=People,dc=linux,dc=lab,dc=local
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
uid: anowak
cn: Anna Nowak
sn: Nowak
givenName: Anna
mail: anowak@linux.lab.local
uidNumber: 20002
gidNumber: 10002
homeDirectory: /home/anowak
loginShell: /bin/bash
userPassword: {SSHA}placeholder

dn: uid=svc-backup,ou=Services,dc=linux,dc=lab,dc=local
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
uid: svc-backup
cn: Backup Service Account
sn: Backup
uidNumber: 20100
gidNumber: 10003
homeDirectory: /home/svc-backup
loginShell: /sbin/nologin
userPassword: {SSHA}placeholder
EOF
```

```bash
ldapadd -x -H ldap://localhost -D "cn=Directory Manager" -W -f /root/ldap/users.ldif
```

Result:
```
[root@rhel-srv01 ~]# ldapadd -x -H ldap://localhost -D "cn=Directory Manager" -W -f /root/ldap/users.ldif
Enter LDAP Password: 
adding new entry "uid=jkowalski,ou=People,dc=linux,dc=lab,dc=local"

adding new entry "uid=anowak,ou=People,dc=linux,dc=lab,dc=local"

adding new entry "uid=svc-backup,ou=Services,dc=linux,dc=lab,dc=local"
```

### 3.3 — Set user passwords using dsidm or ldappasswd

Plain LDAP fails — 389DS requires a secure connection for password changes:
```bash
ldappasswd -x -H ldap://localhost -D "cn=Directory Manager" -W -S "uid=jkowalski,ou=People,dc=linux,dc=lab,dc=local"
# Result: Confidentiality required (13) — Operation requires a secure connection.
```

Use LDAPI (unix socket) instead — counts as a secure connection without TLS:
```bash
ldappasswd -H ldapi://%2fvar%2frun%2fslapd-localhost.socket -D "cn=Directory Manager" -W -S "uid=jkowalski,ou=People,dc=linux,dc=lab,dc=local"
ldappasswd -H ldapi://%2fvar%2frun%2fslapd-localhost.socket -D "cn=Directory Manager" -W -S "uid=anowak,ou=People,dc=linux,dc=lab,dc=local"
ldappasswd -H ldapi://%2fvar%2frun%2fslapd-localhost.socket -D "cn=Directory Manager" -W -S "uid=svc-backup,ou=Services,dc=linux,dc=lab,dc=local"
```

Note: `-S` prompts for the new user password, `-W` prompts for the Directory Manager password. No output on success.

Result:
```
```

### 3.4 — Add users to groups (memberUid)

```bash
cat > /root/ldap/group-members.ldif << 'EOF'
dn: cn=linuxadmins,ou=Groups,dc=linux,dc=lab,dc=local
changetype: modify
add: memberUid
memberUid: jkowalski

dn: cn=linuxusers,ou=Groups,dc=linux,dc=lab,dc=local
changetype: modify
add: memberUid
memberUid: jkowalski
-
add: memberUid
memberUid: anowak

dn: cn=serviceaccounts,ou=Groups,dc=linux,dc=lab,dc=local
changetype: modify
add: memberUid
memberUid: svc-backup
EOF
```

```bash
ldapmodify -x -H ldap://localhost -D "cn=Directory Manager" -W -f /root/ldap/group-members.ldif
```

Result:
```
[root@rhel-srv01 ~]# ldapmodify -x -H ldap://localhost -D "cn=Directory Manager" -W -f /root/ldap/group-members.ldif
Enter LDAP Password: 
modifying entry "cn=linuxadmins,ou=Groups,dc=linux,dc=lab,dc=local"

modifying entry "cn=linuxusers,ou=Groups,dc=linux,dc=lab,dc=local"

modifying entry "cn=serviceaccounts,ou=Groups,dc=linux,dc=lab,dc=local"
```

### 3.5 — Verify users and group membership

```bash
ldapsearch -x -H ldap://localhost -D "cn=Directory Manager" -W -b "ou=People,dc=linux,dc=lab,dc=local" "(objectClass=posixAccount)" uid cn uidNumber gidNumber homeDirectory
ldapsearch -x -H ldap://localhost -D "cn=Directory Manager" -W -b "ou=Groups,dc=linux,dc=lab,dc=local" "(objectClass=posixGroup)" cn gidNumber memberUid
```

Result:
```
[root@rhel-srv01 ~]# ldapsearch -x -H ldap://localhost -D "cn=Directory Manager" -W -b "ou=People,dc=linux,dc=lab,dc=local" "(objectClass=posixAccount)" uid cn uidNumber gidNumber homeDirectory
Enter LDAP Password: 
# extended LDIF
#
# LDAPv3
# base <ou=People,dc=linux,dc=lab,dc=local> with scope subtree
# filter: (objectClass=posixAccount)
# requesting: uid cn uidNumber gidNumber homeDirectory
#

# jkowalski, People, linux.lab.local
dn: uid=jkowalski,ou=People,dc=linux,dc=lab,dc=local
uid: jkowalski
cn: Jan Kowalski
uidNumber: 20001
gidNumber: 10001
homeDirectory: /home/jkowalski

# anowak, People, linux.lab.local
dn: uid=anowak,ou=People,dc=linux,dc=lab,dc=local
uid: anowak
cn: Anna Nowak
uidNumber: 20002
gidNumber: 10002
homeDirectory: /home/anowak

# search result
search: 2
result: 0 Success

# numResponses: 3
# numEntries: 2
[root@rhel-srv01 ~]# ldapsearch -x -H ldap://localhost -D "cn=Directory Manager" -W -b "ou=Groups,dc=linux,dc=lab,dc=local" "(objectClass=posixGroup)" cn gidNumber memberUid
Enter LDAP Password: 
# extended LDIF
#
# LDAPv3
# base <ou=Groups,dc=linux,dc=lab,dc=local> with scope subtree
# filter: (objectClass=posixGroup)
# requesting: cn gidNumber memberUid
#

# linuxadmins, Groups, linux.lab.local
dn: cn=linuxadmins,ou=Groups,dc=linux,dc=lab,dc=local
cn: linuxadmins
gidNumber: 10001
memberUid: jkowalski

# linuxusers, Groups, linux.lab.local
dn: cn=linuxusers,ou=Groups,dc=linux,dc=lab,dc=local
cn: linuxusers
gidNumber: 10002
memberUid: jkowalski
memberUid: anowak

# serviceaccounts, Groups, linux.lab.local
dn: cn=serviceaccounts,ou=Groups,dc=linux,dc=lab,dc=local
cn: serviceaccounts
gidNumber: 10003
memberUid: svc-backup

# search result
search: 2
result: 0 Success

# numResponses: 4
# numEntries: 3
```

---
### Notes

Utworzyłem 3 grupy POSIX (linuxadmins, linuxusers, serviceaccounts) w `ou=Groups` i 3 konta użytkowników (jkowalski, anowak, svc-backup) w `ou=People` i `ou=Services`. Każdy użytkownik ma komplet atrybutów POSIX (uid, uidNumber, gidNumber, homeDirectory, loginShell) potrzebnych do logowania na systemie Linux. Hasła ustawione przez `ldappasswd` z użyciem LDAPI socket — plain LDAP zwracał `Confidentiality required (13)`. Użytkownicy przypisani do grup przez atrybut `memberUid` za pomocą `ldapmodify` z LDIF changetype:modify.

**Czym jest POSIX w kontekście LDAP?**
POSIX (Portable Operating System Interface) definiuje standardowy model użytkownika i grupy w systemach Unix/Linux. Każdy użytkownik systemowy ma: UID (numer), GID (grupa główna), home directory i login shell. Te same atrybuty muszą istnieć w LDAP, żeby system Linux mógł traktować wpis LDAP jako pełnoprawne konto użytkownika. Dlatego używamy objectClass `posixAccount` (atrybuty użytkownika) i `posixGroup` (atrybuty grupy) — to klasy zdefiniowane w schemacie RFC 2307, który mapuje model POSIX na LDAP.

**Trzy objectClass na użytkowniku — dlaczego?**
- `inetOrgPerson` — standardowa klasa osoby w LDAP (cn, sn, mail, givenName). Wymagana, bo dostarcza obowiązkowe atrybuty `cn` i `sn`.
- `posixAccount` — atrybuty POSIX: uidNumber, gidNumber, homeDirectory, loginShell. Bez tego SSSD nie rozpozna wpisu jako konto systemowe.
- `shadowAccount` — atrybuty polityki haseł (expiry, aging). Opcjonalna, ale SSSD oczekuje jej do zarządzania cyklem życia hasła.

**memberUid vs member — dwa modele członkostwa w grupach:**
- `memberUid` (używany w `posixGroup`) — przechowuje sam login (np. `jkowalski`). Prosty, ale nie tworzy referencji do wpisu użytkownika — jeśli zmienisz uid, musisz ręcznie zaktualizować wszystkie grupy.
- `member` / `uniqueMember` (używany w `groupOfNames` / `groupOfUniqueNames`) — przechowuje pełny DN (np. `uid=jkowalski,ou=People,...`). Tworzy bezpośrednie powiązanie między wpisami. 389DS wspiera oba modele; `posixGroup` z `memberUid` jest wystarczający dla integracji z SSSD.

---
### Conclusion

#### What - Co zrobiłem?
Utworzenie 3 grup POSIX (linuxadmins/10001, linuxusers/10002, serviceaccounts/10003) i 3 użytkowników z pełnymi atrybutami POSIX (jkowalski/20001, anowak/20002, svc-backup/20100). Ustawienie haseł przez `ldappasswd` z LDAPI socket. Przypisanie użytkowników do grup przez `memberUid` (`ldapmodify` changetype:modify). Weryfikacja `ldapsearch` potwierdza poprawność wszystkich wpisów i członkostw.

---
#### Why - Dlaczego to zrobiłem?
Katalog LDAP bez danych jest bezużyteczny. Grupy i użytkownicy z atrybutami POSIX to minimum potrzebne do integracji z SSSD w krokach 6–7. Rozdzielenie na trzy grupy (admins, users, serviceaccounts) odzwierciedla typową strukturę enterprise — różne grupy mają różne uprawnienia (np. sudo, dostęp SSH). Konto `svc-backup` z loginShell `/sbin/nologin` demonstruje wzorzec konta serwisowego, które nie może się logować interaktywnie.

---
#### Result - Co dzięki temu uzyskałem?
Katalog wypełniony danymi testowymi — 3 grupy, 3 użytkownicy, członkostwa. Struktura gotowa do zabezpieczenia ACL (Step 5) i integracji z SSSD (Steps 6–7). Pliki LDIF w `/root/ldap/` (groups.ldif, users.ldif, group-members.ldif) mogą być ponownie użyte do odtworzenia danych po resecie instancji.

---
#### Lesson Learned - Co się nauczyłem?
- **POSIX w LDAP** — objectClass `posixAccount` i `posixGroup` (RFC 2307) mapują model użytkownika/grupy Unix na atrybuty LDAP. Bez nich SSSD i NSS nie rozpoznają wpisów LDAP jako kont systemowych. Kluczowe atrybuty: `uidNumber`, `gidNumber`, `homeDirectory`, `loginShell` (użytkownik), `gidNumber`, `memberUid` (grupa).
- **Trzy objectClass na użytkowniku** — `inetOrgPerson` (dane osobowe + wymagane `cn`/`sn`), `posixAccount` (atrybuty systemowe), `shadowAccount` (polityka haseł). LDAP pozwala łączyć wiele objectClass w jednym wpisie — to fundamentalna różnica w stosunku do relacyjnych baz danych.
- **`ldapadd` vs `ldapmodify`** — `ldapadd` dodaje nowe wpisy (cały LDIF to nowe obiekty). `ldapmodify` modyfikuje istniejące wpisy (wymaga `changetype: modify` + operacja `add`/`delete`/`replace`). Dodawanie `memberUid` do istniejącej grupy to modyfikacja, nie dodanie.
- **`Confidentiality required (13)`** — 389DS domyślnie wymaga szyfrowanego połączenia do operacji zmiany hasła. LDAPI (unix socket `ldapi://`) jest traktowany jako bezpieczny, bo komunikacja nie wychodzi poza maszynę. Alternatywa: LDAPS (port 636) lub STARTTLS — skonfigurujemy w Step 4.
- **`ldappasswd` z LDAPI** — składnia URI socket wymaga zakodowania `/` jako `%2f`: `ldapi://%2fvar%2frun%2fslapd-localhost.socket`. Brak outputu = sukces; błędy wyświetlają się jawnie.
- **`userPassword: {SSHA}placeholder`** w LDIF — to tymczasowa wartość, nadpisana przez `ldappasswd`. W produkcji nigdy nie wpisuje się haseł w czystym tekście do LDIF. SSHA (Salted SHA) to domyślny algorytm hashowania haseł w 389DS.
- **`gidNumber` w `posixAccount`** — to grupa główna użytkownika (primary group). `memberUid` w `posixGroup` to grupy dodatkowe (supplementary groups). Linux rozróżnia oba typy — `id jkowalski` pokaże primary group i supplementary groups.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
- **`Confidentiality required (13)` przy `ldappasswd`** — plain LDAP (`ldap://localhost`) nie spełnia wymagań bezpieczeństwa 389DS dla operacji zmiany hasła. Rozwiązanie: użycie LDAPI socket (`ldapi://%2fvar%2frun%2fslapd-localhost.socket`), który jest traktowany jako bezpieczne połączenie lokalne.

---

## Step 4 — Enable TLS with a self-signed certificate

### 4.1 — Generate self-signed CA and server certificate

Create a directory for certificates:
```bash
mkdir -p /root/ldap/certs
cd /root/ldap/certs
```

Generate CA private key and certificate:
```bash
openssl genrsa -out ca.key 4096
openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 -out ca.crt \
  -subj "/C=PL/ST=Lab/O=Linux Lab/CN=Lab CA"
```

Generate server key and CSR:
```bash
openssl genrsa -out ds.key 4096
openssl req -new -key ds.key -out ds.csr \
  -subj "/C=PL/ST=Lab/O=Linux Lab/CN=rhel-srv01.linux.lab.local"
```

Sign the server certificate with CA:
```bash
openssl x509 -req -in ds.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out ds.crt -days 3650 -sha256
```

Verify:
```bash
openssl verify -CAfile ca.crt ds.crt
```

Result:
```
[root@rhel-srv01 ~]# mkdir -p /root/ldap/certs
cd /root/ldap/certs
[root@rhel-srv01 certs]# openssl genrsa -out ca.key 4096
openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 -out ca.crt \
  -subj "/C=PL/ST=Lab/O=Linux Lab/CN=Lab CA"
[root@rhel-srv01 certs]# openssl genrsa -out ds.key 4096
openssl req -new -key ds.key -out ds.csr \
  -subj "/C=PL/ST=Lab/O=Linux Lab/CN=rhel-srv01.linux.lab.local"
[root@rhel-srv01 certs]# openssl x509 -req -in ds.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out ds.crt -days 3650 -sha256
Certificate request self-signature ok
subject=C=PL, ST=Lab, O=Linux Lab, CN=rhel-srv01.linux.lab.local
[root@rhel-srv01 certs]# openssl verify -CAfile ca.crt ds.crt
ds.crt: OK
```

### 4.2 — Import certificates into 389DS NSS database

Import CA certificate:
```bash
dsconf localhost security ca-certificate add --file /root/ldap/certs/ca.crt --name "Lab-CA"
dsconf localhost security ca-certificate set-trust-flags "Lab-CA" --flags "CT,,"
```

Import server key and certificate:
```bash
dsctl localhost tls import-server-key-cert /root/ldap/certs/ds.crt /root/ldap/certs/ds.key
```

Verify imported certificates:
```bash
dsconf localhost security ca-certificate list
dsctl localhost tls show-cert Server-Cert
```

Result:
```
[root@rhel-srv01 certs]# dsconf localhost security ca-certificate add --file /root/ldap/certs/ca.crt --name "Lab-CA"
Successfully added CA certificate (Lab-CA)
[root@rhel-srv01 certs]# dsconf localhost security ca-certificate set-trust-flags "Lab-CA" --flags "CT,,"
Successfully edited certificate trust flags
[root@rhel-srv01 certs]# dsctl localhost tls import-server-key-cert /root/ldap/certs/ds.crt /root/ldap/certs/ds.key

[root@rhel-srv01 certs]# dsconf localhost security ca-certificate list
Certificate Name: Self-Signed-CA
Subject DN: CN=ssca.389ds.example.com,O=testing,L=389ds,ST=Queensland,C=AU
Trust Flags: CT,,

Certificate Name: Lab-CA
Subject DN: CN=Lab CA,O=Linux Lab,ST=Lab,C=PL
Issuer DN: CN=Lab CA,O=Linux Lab,ST=Lab,C=PL
Expires: 2036-04-10 10:04:34
Trust Flags: CT,,

[root@rhel-srv01 certs]# dsctl localhost tls show-cert Server-Cert
(...)
Subject: "CN=rhel-srv01.linux.lab.local,O=Linux Lab,ST=Lab,C=PL"
Issuer: "CN=Lab CA,O=Linux Lab,ST=Lab,C=PL"
Not Before: Mon Apr 13 10:04:52 2026
Not After: Thu Apr 10 10:04:52 2036
Trust Flags: u,u,u
```

### 4.3 — Enable TLS in 389DS configuration

```bash
dsconf localhost security enable
dsconf localhost security set --tls-protocol-min="TLS1.2"
dsconf localhost config replace nsslapd-secureport=636
```

Restart the instance:
```bash
dsctl localhost restart
```

Result:
```
[root@rhel-srv01 certs]# dsconf localhost security enable
Successfully enabled security
[root@rhel-srv01 certs]# dsconf localhost security set --tls-protocol-min="TLS1.2"
Successfully updated security configuration (nsSSL3Ciphers)
[root@rhel-srv01 certs]# dsconf localhost config replace nsslapd-secureport=636
Successfully replaced value(s) for 'nsslapd-secureport': '636'
[root@rhel-srv01 certs]# dsctl localhost restart
Instance "localhost" has been restarted
```

### 4.4 — Verify TLS connectivity

Test LDAPS without CA cert (expected to fail with self-signed CA):
```bash
ldapsearch -x -H ldaps://rhel-srv01.linux.lab.local -D "cn=Directory Manager" -W -b "dc=linux,dc=lab,dc=local" -s base
```

Test with explicit CA cert:
```bash
LDAPTLS_CACERT=/root/ldap/certs/ca.crt ldapsearch -x -H ldaps://rhel-srv01.linux.lab.local -D "cn=Directory Manager" -W -b "dc=linux,dc=lab,dc=local" -s base
```

Add CA to system trust store (so LDAPTLS_CACERT is no longer needed):
```bash
cp /root/ldap/certs/ca.crt /etc/pki/ca-trust/source/anchors/lab-ca.crt
update-ca-trust
```

Verify without LDAPTLS_CACERT:
```bash
ldapsearch -x -H ldaps://rhel-srv01.linux.lab.local -D "cn=Directory Manager" -W -b "dc=linux,dc=lab,dc=local" -s base
```

Result:
```
[root@rhel-srv01 certs]# ldapsearch -x -H ldaps://rhel-srv01.linux.lab.local -D "cn=Directory Manager" -W -b "dc=linux,dc=lab,dc=local" -s base
ldap_sasl_bind(SIMPLE): Can't contact LDAP server (-1)

[root@rhel-srv01 certs]# LDAPTLS_CACERT=/root/ldap/certs/ca.crt ldapsearch -x -H ldaps://rhel-srv01.linux.lab.local -D "cn=Directory Manager" -W -b "dc=linux,dc=lab,dc=local" -s base
result: 0 Success

[root@rhel-srv01 certs]# cp /root/ldap/certs/ca.crt /etc/pki/ca-trust/source/anchors/lab-ca.crt
[root@rhel-srv01 certs]# update-ca-trust

[root@rhel-srv01 certs]# ldapsearch -x -H ldaps://rhel-srv01.linux.lab.local -D "cn=Directory Manager" -W -b "dc=linux,dc=lab,dc=local" -s base
result: 0 Success
```

---
### Notes

Wygenerowałem self-signed CA (`Lab CA`) i certyfikat serwera (`CN=rhel-srv01.linux.lab.local`) za pomocą openssl. Zaimportowałem CA i certyfikat serwera do bazy NSS 389DS przez `dsconf`/`dsctl`. Włączyłem TLS (minimum TLS 1.2) i zrestartowałem instancję. LDAPS na porcie 636 działa — `openssl s_client` potwierdza prawidłowy łańcuch certyfikatów. Klient `ldapsearch` wymagał jawnego `LDAPTLS_CACERT` przy self-signed CA — po dodaniu CA do systemowego trust store (`update-ca-trust`) problem zniknął.

---
### Conclusion

#### What - Co zrobiłem?
Wygenerowanie self-signed CA i certyfikatu serwera (openssl), import do bazy NSS 389DS (dsconf/dsctl), włączenie TLS z minimum TLS 1.2, restart instancji, dodanie CA do systemowego trust store (`/etc/pki/ca-trust/source/anchors/`). Weryfikacja LDAPS przez `openssl s_client` i `ldapsearch`.

---
#### Why - Dlaczego to zrobiłem?
LDAP przesyła dane (w tym hasła) plain textem. TLS szyfruje komunikację i zapobiega podsłuchowi. 389DS domyślnie wymaga secure connection do operacji zmiany hasła (`Confidentiality required` z Step 3). SSSD na klientach (Steps 6–7) powinien łączyć się przez LDAPS — bez TLS konfiguracja byłaby niebezpieczna.

---
#### Result - Co dzięki temu uzyskałem?
389DS serwuje LDAPS na porcie 636 z certyfikatem podpisanym przez Lab CA. Klienci na rhel-srv01 mogą łączyć się przez LDAPS bez jawnego `LDAPTLS_CACERT` (CA w systemowym trust store). Certyfikat serwera ważny do 2036 roku.

---
#### Lesson Learned - Co się nauczyłem?
- **Self-signed CA vs self-signed certyfikat** — tworzymy osobny CA (`ca.key`/`ca.crt`) i podpisujemy nim certyfikat serwera (`ds.crt`). Dzięki temu wystarczy zaufać jednemu CA na klientach, a nie każdemu certyfikatowi z osobna. To ten sam model co publiczne CA (Let's Encrypt, DigiCert), tylko w skali laba.
- **NSS vs PEM** — 389DS historycznie używa bazy NSS (Network Security Services) do przechowywania certyfikatów, a nie plików PEM jak Apache/nginx. Dlatego import przez `dsctl tls import-server-key-cert`, a nie przez wskazanie plików w konfiguracji.
- **Trust Flags `CT,,`** — trzy pozycje to: SSL, Email, Object Signing. `C` = CA (może podpisywać certyfikaty), `T` = Trusted (zaufany). Certyfikat serwera ma `u,u,u` (user cert — prywatny klucz obecny).
- **`Can't contact LDAP server (-1)`** — klient OpenLDAP odrzuca połączenie, jeśli nie może zweryfikować łańcucha certyfikatów. Nie oznacza to, że serwer nie działa — to błąd weryfikacji TLS po stronie klienta.
- **`LDAPTLS_CACERT`** — zmienna środowiskowa wskazująca klientowi OpenLDAP plik CA do weryfikacji. Alternatywa: dodanie CA do systemowego trust store (`update-ca-trust` na RHEL, `update-ca-certificates` na Ubuntu).
- **`update-ca-trust`** — RHEL skanuje `/etc/pki/ca-trust/source/anchors/` i przebudowuje bundel `/etc/pki/tls/certs/ca-bundle.crt`. Klienty OpenLDAP, curl, wget automatycznie ufają certyfikatom z tego bundla.
- **`dscreate` automatycznie tworzy Self-Signed-CA** — widoczne na liście CA (`ssca.389ds.example.com`). To domyślny certyfikat 389DS do wewnętrznej komunikacji. Nasz `Lab-CA` go nie zastępuje — oba współistnieją.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
- **`Can't contact LDAP server (-1)` przy LDAPS** — klient OpenLDAP nie ufał self-signed CA. Rozwiązanie dwuetapowe: (1) tymczasowo `LDAPTLS_CACERT=/root/ldap/certs/ca.crt`, (2) trwale `cp ca.crt /etc/pki/ca-trust/source/anchors/ && update-ca-trust`.

---

## Step 5 — Define ACL policies for different bind DNs

### 5.1 — Create a read-only service bind account

```bash
cat > /root/ldap/svc-readonly.ldif << 'EOF'
dn: uid=svc-readonly,ou=Services,dc=linux,dc=lab,dc=local
objectClass: inetOrgPerson
objectClass: posixAccount
uid: svc-readonly
cn: Read-Only Bind Account
sn: ReadOnly
uidNumber: 20101
gidNumber: 10003
homeDirectory: /dev/null
loginShell: /sbin/nologin
userPassword: {SSHA}placeholder
EOF
```

```bash
ldapadd -x -H ldap://localhost -D "cn=Directory Manager" -W -f /root/ldap/svc-readonly.ldif
ldappasswd -H ldapi://%2fvar%2frun%2fslapd-localhost.socket -D "cn=Directory Manager" -W -S "uid=svc-readonly,ou=Services,dc=linux,dc=lab,dc=local"
```

Result:
```
```

### 5.2 — Define ACIs on the directory

Grant read access to the entire tree for svc-readonly:
```bash
cat > /root/ldap/aci-readonly.ldif << 'EOF'
dn: dc=linux,dc=lab,dc=local
changetype: modify
add: aci
aci: (targetattr="*")(version 3.0; acl "svc-readonly read access"; allow (read, search, compare) userdn="ldap:///uid=svc-readonly,ou=Services,dc=linux,dc=lab,dc=local";)
EOF
```

Allow users to change their own password:
```bash
cat > /root/ldap/aci-self-password.ldif << 'EOF'
dn: dc=linux,dc=lab,dc=local
changetype: modify
add: aci
aci: (targetattr="userPassword")(version 3.0; acl "Users can change own password"; allow (write) userdn="ldap:///self";)
EOF
```

Apply ACIs:
```bash
ldapmodify -x -H ldap://localhost -D "cn=Directory Manager" -W -f /root/ldap/aci-readonly.ldif
ldapmodify -x -H ldap://localhost -D "cn=Directory Manager" -W -f /root/ldap/aci-self-password.ldif
```

Deny anonymous access — via server config (NOT via ACI, see Notes):
```bash
dsconf localhost config replace nsslapd-allow-anonymous-access=rootdse
```

Result:
```
Enter LDAP Password:
modifying entry "dc=linux,dc=lab,dc=local"

Enter LDAP Password:
modifying entry "dc=linux,dc=lab,dc=local"

Successfully replaced value(s) for 'nsslapd-allow-anonymous-access': 'rootdse'
```

### 5.3 — Verify ACL policies

Test svc-readonly — should be able to read users:
```bash
ldapsearch -x -H ldap://localhost -D "uid=svc-readonly,ou=Services,dc=linux,dc=lab,dc=local" -w "ReadOnly123!" -b "ou=People,dc=linux,dc=lab,dc=local" "(objectClass=posixAccount)" uid cn
```

Test anonymous bind — should be denied:
```bash
ldapsearch -x -H ldap://localhost -b "ou=People,dc=linux,dc=lab,dc=local" "(objectClass=posixAccount)" uid cn
```

Test user self-bind (jkowalski):
```bash
ldapwhoami -x -H ldap://localhost -D "uid=jkowalski,ou=People,dc=linux,dc=lab,dc=local" -w "Jkowalski123!"
```

Result:
```
[root@rhel-srv01 certs]# ldapsearch -x -H ldap://localhost -D "uid=svc-readonly,ou=Services,dc=linux,dc=lab,dc=local" -w "ReadOnly123!" -b "ou=People,dc=linux,dc=lab,dc=local" "(objectClass=posixAccount)" uid cn
# jkowalski, People, linux.lab.local
dn: uid=jkowalski,ou=People,dc=linux,dc=lab,dc=local
uid: jkowalski
cn: Jan Kowalski

# anowak, People, linux.lab.local
dn: uid=anowak,ou=People,dc=linux,dc=lab,dc=local
uid: anowak
cn: Anna Nowak
result: 0 Success

[root@rhel-srv01 certs]# ldapsearch -x -H ldap://localhost -b "ou=People,dc=linux,dc=lab,dc=local" "(objectClass=posixAccount)" uid cn
result: 48 Inappropriate authentication
text: Anonymous access is not allowed.

[root@rhel-srv01 certs]# ldapwhoami -x -H ldap://localhost -D "uid=jkowalski,ou=People,dc=linux,dc=lab,dc=local" -w "Jkowalski123!"
dn: uid=jkowalski,ou=people,dc=linux,dc=lab,dc=local
```

---
### Notes

Utworzyłem konto serwisowe `svc-readonly` (bind DN dla SSSD) i zdefiniowałem dwa ACI: read access dla svc-readonly na całe drzewo oraz self-password change dla użytkowników. Blokowanie anonymous zrealizowałem przez `nsslapd-allow-anonymous-access=rootdse` (konfiguracja serwera) zamiast ACI — pierwotne ACI z `userdn="ldap:///anyone"` blokowało WSZYSTKICH użytkowników, nie tylko anonimowych.

**Czym są ACI w 389DS?**
ACI (Access Control Instructions) to mechanizm kontroli dostępu specyficzny dla 389DS. Każde ACI to atrybut `aci` na wpisie LDAP (zazwyczaj na base DN, skąd dziedziczą podrzędne wpisy). Składnia:
```
(target)(version 3.0; acl "nazwa"; allow|deny (operacje) bind_rule;)
```
- **target** — co chronimy: `targetattr="*"` (wszystkie atrybuty), `targetattr="userPassword"` (konkretny atrybut)
- **operacje** — `read`, `search`, `compare`, `write`, `add`, `delete`, `selfwrite`
- **bind_rule** — kto: `userdn="ldap:///uid=svc-readonly,..."` (konkretny użytkownik), `userdn="ldap:///self"` (sam siebie), `userdn="ldap:///all"` (wszyscy uwierzytelnieni), `userdn="ldap:///anyone"` (wszyscy łącznie z anonymous)

**Kluczowa różnica: `anyone` vs `all`:**
- `userdn="ldap:///anyone"` = WSZYSCY (authenticated + anonymous)
- `userdn="ldap:///all"` = tylko UWIERZYTELNIENI użytkownicy
- W 389DS **deny ma priorytet nad allow** — dlatego `deny ... anyone` blokuje nawet użytkowników z jawnym allow

**Dlaczego `nsslapd-allow-anonymous-access=rootdse` zamiast ACI:**
Parametr konfiguracyjny serwera jest prostszy i bezpieczniejszy niż ACI deny. Wartość `rootdse` pozwala anonimowym klientom odczytać tylko Root DSE (informacje o serwerze, np. obsługiwane wersje LDAP) — to standard, na który wiele klientów LDAP liczy. Całkowity blok (`off`) mógłby złamać autodetect w SSSD.

---
### Conclusion

#### What - Co zrobiłem?
Utworzenie konta serwisowego `svc-readonly` (bind DN dla SSSD) z hasłem ustawionym przez `ldapmodify`. Zdefiniowanie dwóch ACI: (1) read/search/compare dla svc-readonly na całym drzewie, (2) self-password write dla użytkowników. Zablokowanie anonymous access przez `nsslapd-allow-anonymous-access=rootdse`. Weryfikacja trzech scenariuszy: svc-readonly widzi użytkowników, anonymous jest blokowany, jkowalski może się zbindować.

---
#### Why - Dlaczego to zrobiłem?
Bez ACL każdy uwierzytelniony użytkownik mógłby modyfikować dowolne wpisy. Konto `svc-readonly` to wzorzec least-privilege — SSSD potrzebuje tylko odczytu (read/search/compare), nie zapisu. Self-password ACI pozwala użytkownikom zmieniać własne hasła bez interwencji administratora. Blokowanie anonymous zapobiega wyciekom danych katalogowych.

---
#### Result - Co dzięki temu uzyskałem?
Trzy warstwy kontroli dostępu: (1) svc-readonly ma read-only dostęp do drzewa — SSSD może przez to konto odpytywać użytkowników i grupy, (2) użytkownicy mogą zmieniać własne hasła, (3) dostęp anonimowy zablokowany do rootDSE. Directory Manager zachowuje pełny dostęp (rootDN bypass).

---
#### Lesson Learned - Co się nauczyłem?
- **ACI `deny` ma priorytet nad `allow`** w 389DS — to fundamentalna zasada. Deny z `userdn="ldap:///anyone"` blokuje WSZYSTKICH, nawet tych z jawnym allow. Dlatego deny ACIs należy używać bardzo ostrożnie.
- **`anyone` ≠ `all`** — `anyone` = wszyscy (łącznie z anonymous), `all` = tylko uwierzytelnieni. To subtelna ale krytyczna różnica w składni ACI.
- **`nsslapd-allow-anonymous-access=rootdse`** — prostszy i bezpieczniejszy sposób na blokowanie anonymous niż ACI deny. Nie koliduje z innymi ACIs i pozwala na odczyt Root DSE (potrzebny dla autodetect w klientach LDAP).
- **`ldappasswd` przez LDAPI nie zawsze działa poprawnie** — hasło zapisywane jako `{PBKDF2-SHA512}` wyglądało poprawnie, ale bind nie działał. Metoda `ldapmodify` z plain text password w atrybucie `userPassword` jest pewniejsza — 389DS sam hashuje wartość.
- **ACI dziedziczą w dół drzewa** — ACI na `dc=linux,dc=lab,dc=local` obejmuje wszystkie podrzędne wpisy (OUs, użytkowników, grupy). Nie trzeba ustawiać ACI na każdym OU osobno.
- **rootDN (Directory Manager) omija ACL** — `cn=Directory Manager` nigdy nie jest blokowany przez ACI. To odpowiednik `root` w systemie — ostatnia deska ratunku przy problemach z dostępem.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
- **`Invalid credentials (49)` przy bind svc-readonly i jkowalski** — hasła ustawione przez `ldappasswd` (nawet przez LDAPI) nie działały prawidłowo. Rozwiązanie: ustawienie haseł przez `ldapmodify` z plain text `userPassword` przez LDAPI socket.
- **ACI `deny anonymous` blokowało wszystkich** — ACI z `userdn="ldap:///anyone"` + `deny` blokowało nawet uwierzytelnionych użytkowników (deny ma priorytet). Rozwiązanie: usunięcie ACI deny, zastąpienie parametrem konfiguracyjnym `nsslapd-allow-anonymous-access=rootdse`.
- **svc-readonly widział wpisy ale bez atrybutów** — konsekwencja deny ACI z `anyone` — deny blokował odczyt atrybutów nawet dla svc-readonly. Po usunięciu deny i zastosowaniu konfiguracji serwera, atrybuty `uid` i `cn` są widoczne.

---

## Step 6 — Configure SSSD on repo-srv01 (RHEL client) to authenticate against LDAP

### 6.1 — Install SSSD and LDAP client packages on repo-srv01

```bash
dnf install -y sssd sssd-ldap openldap-clients oddjob-mkhomedir authselect
```

Result:
```
```

### 6.2 — Copy CA certificate to repo-srv01

From rhel-srv01, copy the CA certificate:
```bash
scp /root/ldap/certs/ca.crt root@10.10.10.50:/etc/pki/ca-trust/source/anchors/lab-ca.crt
```

Or from repo-srv01:
```bash
scp root@10.10.10.20:/root/ldap/certs/ca.crt /etc/pki/ca-trust/source/anchors/lab-ca.crt
update-ca-trust
```

Result:
```
[root@repo-srv01 ~]# scp root@10.10.10.20:/root/ldap/certs/ca.crt /etc/pki/ca-trust/source/anchors/lab-ca.crt
ca.crt                                                100% 1927    17.0MB/s   00:00
[root@repo-srv01 ~]# update-ca-trust
```

### 6.3 — Configure SSSD for LDAP authentication

```bash
cat > /etc/sssd/sssd.conf << 'EOF'
[sssd]
services = nss, pam
domains = linux.lab.local

[domain/linux.lab.local]
id_provider = ldap
auth_provider = ldap
chpass_provider = ldap

ldap_uri = ldaps://rhel-srv01.linux.lab.local
ldap_search_base = dc=linux,dc=lab,dc=local
ldap_default_bind_dn = uid=svc-readonly,ou=Services,dc=linux,dc=lab,dc=local
ldap_default_authtok_type = password
ldap_default_authtok = ReadOnly123!

ldap_tls_cacert = /etc/pki/ca-trust/source/anchors/lab-ca.crt
ldap_tls_reqcert = demand
ldap_id_use_start_tls = False
ldap_schema = rfc2307

ldap_user_search_base = ou=People,dc=linux,dc=lab,dc=local
ldap_group_search_base = ou=Groups,dc=linux,dc=lab,dc=local

cache_credentials = True
enumerate = True
EOF
```

Set correct permissions:
```bash
chmod 600 /etc/sssd/sssd.conf
chown root:root /etc/sssd/sssd.conf
```

Result:
```
```

### 6.4 — Enable SSSD and configure NSS/PAM

```bash
systemctl enable --now sssd
systemctl enable --now oddjobd

authselect select sssd with-mkhomedir --force
```

Result:
```
[root@repo-srv01 ~]# authselect select sssd with-mkhomedir --force
Backup stored at /var/lib/authselect/backups/2026-04-13-10-47-27.RWOCTr
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
```

### 6.5 — Verify LDAP user resolution on repo-srv01

```bash
getent passwd jkowalski
getent passwd anowak
getent group linuxadmins
getent group linuxusers
id jkowalski
id anowak
```

Result:
```
[root@repo-srv01 ~]# getent passwd jkowalski
jkowalski:*:20001:10001:Jan Kowalski:/home/jkowalski:/bin/bash
[root@repo-srv01 ~]# getent passwd anowak
anowak:*:20002:10002:Anna Nowak:/home/anowak:/bin/bash
[root@repo-srv01 ~]# getent group linuxadmins
linuxadmins:*:10001:jkowalski
[root@repo-srv01 ~]# getent group linuxusers
linuxusers:*:10002:jkowalski,anowak
[root@repo-srv01 ~]# id jkowalski
id anowak
uid=20001(jkowalski) gid=10001(linuxadmins) groups=10001(linuxadmins),10002(linuxusers)
uid=20002(anowak) gid=10002(linuxusers) groups=10002(linuxusers)
```



### 6.6 — Test SSH login as LDAP user on repo-srv01

From rhel-srv01 (or any other machine):
```bash
ssh jkowalski@10.10.10.50
```

On repo-srv01, verify home directory was created:
```bash
ls -la /home/jkowalski/
```

Result:
```
PS C:\Users\Bartek\Projekty\linux-windows-admin-lab> ssh  rhel-srv01
Last login: Mon Apr 13 09:17:09 2026 from 10.10.10.1
[root@rhel-srv01 ~]# ssh jkowalski@10.10.10.50
The authenticity of host '10.10.10.50 (10.10.10.50)' can't be established.
ED25519 key fingerprint is SHA256:p85O+AHcHnJ17OsTgxRitWFHdCV0fhDTf9zuI+i5XG4.
This key is not known by any other names
Are you sure you want to continue connecting (yes/no/[fingerprint])? yes
Warning: Permanently added '10.10.10.50' (ED25519) to the list of known hosts.
jkowalski@10.10.10.50's password: 
Creating home directory for jkowalski.
[jkowalski@repo-srv01 ~]$ ls -la /home/jkowalski/
total 20
drwx------ 2 jkowalski linuxadmins 4096 Apr 13 10:50 .
drwxr-xr-x 3 root      root        4096 Apr 13 10:50 ..
-rw------- 1 jkowalski linuxadmins   18 Apr 13 10:50 .bash_logout
-rw------- 1 jkowalski linuxadmins  141 Apr 13 10:50 .bash_profile
-rw------- 1 jkowalski linuxadmins  492 Apr 13 10:50 .bashrc
[jkowalski@repo-srv01 ~]$ 
```

---
### Notes

SSSD (System Security Services Daemon) to demon, który pośredniczy między systemem Linux (NSS/PAM) a zewnętrznym źródłem tożsamości (LDAP, AD, IPA). Klient nie odpytuje LDAP bezpośrednio — SSSD cachuje dane i obsługuje uwierzytelnianie.

**Kluczowe elementy konfiguracji `sssd.conf`:**
- **`id_provider = ldap`** — skąd brać informacje o użytkownikach/grupach (uid, gid, home, shell)
- **`auth_provider = ldap`** — jak uwierzytelniać (bind do LDAP z hasłem użytkownika)
- **`chpass_provider = ldap`** — jak zmieniać hasła (LDAP password modify)
- **`ldap_default_bind_dn`** — konto serwisowe do enumeracji (svc-readonly, nie DM!)
- **`ldap_tls_reqcert = demand`** — wymusza weryfikację certyfikatu serwera TLS
- **`ldap_schema = rfc2307`** — schemat POSIX (grupy z `memberUid`, nie `member` DN)
- **`enumerate = True`** — SSSD pobiera pełną listę użytkowników/grup (przydatne w labie, w produkcji wyłączone)
- **`cache_credentials = True`** — cachuje hasła, pozwala logować się offline

**`authselect`** to narzędzie RHEL 9 do zarządzania PAM/NSS. Profil `sssd with-mkhomedir` konfiguruje: (1) NSS do odpytywania SSSD o użytkowników/grupy, (2) PAM do uwierzytelniania przez SSSD, (3) automatyczne tworzenie katalogów domowych przy pierwszym logowaniu.

---
### Conclusion

#### What - Co zrobiłem?
Zainstalowanie SSSD z pakietami LDAP na `repo-srv01`, skopiowanie CA cert do trust store, utworzenie `sssd.conf` z parametrami połączenia LDAPS, aktywacja profilu `authselect sssd with-mkhomedir`. Weryfikacja: `getent` zwraca użytkowników LDAP, `id` pokazuje grupy, SSH login jako `jkowalski` tworzy katalog domowy.

---
#### Why - Dlaczego to zrobiłem?
Centralny katalog LDAP jest bezużyteczny bez klientów, które z niego korzystają. SSSD integruje LDAP z systemowymi mechanizmami uwierzytelniania (PAM) i rozwiązywania nazw (NSS), dzięki czemu użytkownicy LDAP mogą logować się na maszynę tak samo jak użytkownicy lokalni.

---
#### Result - Co dzięki temu uzyskałem?
Maszyna `repo-srv01` rozwiązuje użytkowników i grupy z LDAP (`getent passwd jkowalski` zwraca `uid=20001`). Logowanie SSH jako `jkowalski` działa z hasłem LDAP. Katalog domowy tworzony automatycznie przy pierwszym logowaniu. Cache credentials pozwala na logowanie offline.

---
#### Lesson Learned - Co się nauczyłem?
- **`authselect` nie jest zainstalowany domyślnie** w minimalnych kontenerach LXC Rocky/RHEL — trzeba go doinstalować (`dnf install authselect`).
- **Nazwa połączenia NetworkManager może zawierać spacje** — `"System eth0"` zamiast `eth0`. Sprawdzać `nmcli con show` przed użyciem `nmcli con mod`.
- **DNS musi działać na kliencie** — `ldap_uri = ldaps://rhel-srv01.linux.lab.local` wymaga rozwiązania nazwy. Bez poprawnego resolvera SSSD nie połączy się z serwerem.
- **CA cert musi być w trust store** — `update-ca-trust` jest konieczne po skopiowaniu certyfikatu, inaczej SSSD z `ldap_tls_reqcert = demand` odrzuci połączenie.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
- **DNS nie działał na repo-srv01** — resolver wskazywał na Windows DC (10.10.10.10), który nie rozwiązywał nazw internetowych. Fix: `nmcli con mod "System eth0" ipv4.dns "10.10.10.20"` + `ipv4.ignore-auto-dns yes`.
- **`authselect: command not found`** — pakiet nie był zainstalowany w minimalnej instalacji Rocky Linux. Fix: `dnf install -y authselect`.

---

## Step 7 — Configure SSSD on ubuntu-ws01 (Ubuntu client) to authenticate against LDAP

### 7.1 — Install SSSD and LDAP client packages on ubuntu-ws01

```bash
apt update
apt install -y sssd sssd-ldap ldap-utils libpam-sss libnss-sss oddjob-mkhomedir
```

Note: On Ubuntu, the package names differ slightly from RHEL.

Result:
```
```

### 7.2 — Copy CA certificate to ubuntu-ws01

```bash
scp root@10.10.10.20:/root/ldap/certs/ca.crt /usr/local/share/ca-certificates/lab-ca.crt
update-ca-certificates
```

Result:
```
```

### 7.3 — Configure SSSD for LDAP authentication

```bash
cat > /etc/sssd/sssd.conf << 'EOF'
[sssd]
services = nss, pam
domains = linux.lab.local

[domain/linux.lab.local]
id_provider = ldap
auth_provider = ldap
chpass_provider = ldap

ldap_uri = ldaps://rhel-srv01.linux.lab.local
ldap_search_base = dc=linux,dc=lab,dc=local
ldap_default_bind_dn = uid=svc-readonly,ou=Services,dc=linux,dc=lab,dc=local
ldap_default_authtok_type = password
ldap_default_authtok = ReadOnly123!

ldap_tls_cacert = /usr/local/share/ca-certificates/lab-ca.crt
ldap_tls_reqcert = demand
ldap_id_use_start_tls = False
ldap_schema = rfc2307

ldap_user_search_base = ou=People,dc=linux,dc=lab,dc=local
ldap_group_search_base = ou=Groups,dc=linux,dc=lab,dc=local

cache_credentials = True
enumerate = True
EOF

chmod 600 /etc/sssd/sssd.conf
chown root:root /etc/sssd/sssd.conf
```

Result:
```
```

### 7.4 — Enable SSSD and configure NSS/PAM on Ubuntu

```bash
systemctl enable --now sssd
```

Enable mkhomedir via PAM:
```bash
pam-auth-update --enable mkhomedir
```

Result:
```
```

### 7.5 — Verify LDAP user resolution on ubuntu-ws01

```bash
getent passwd jkowalski
getent passwd anowak
getent group linuxadmins
getent group linuxusers
id jkowalski
id anowak
```

Result:
```
root@ubuntu-ws01:~# cat > /etc/sssd/sssd.conf << 'EOF'
[sssd]
services = nss, pam
domains = linux.lab.local

[domain/linux.lab.local]
id_provider = ldap
auth_provider = ldap
chpass_provider = ldap

ldap_uri = ldaps://rhel-srv01.linux.lab.local
ldap_search_base = dc=linux,dc=lab,dc=local
ldap_default_bind_dn = uid=svc-readonly,ou=Services,dc=linux,dc=lab,dc=local
ldap_default_authtok_type = password
ldap_default_authtok = ReadOnly123!

ldap_tls_cacert = /usr/local/share/ca-certificates/lab-ca.crt
ldap_tls_reqcert = demand
ldap_id_use_start_tls = False
ldap_schema = rfc2307

ldap_user_search_base = ou=People,dc=linux,dc=lab,dc=local
ldap_group_search_base = ou=Groups,dc=linux,dc=lab,dc=local

cache_credentials = True
EOFmerate = True
root@ubuntu-ws01:~# chmod 600 /etc/sssd/sssd.conf
root@ubuntu-ws01:~# chown root:root /etc/sssd/sssd.conf
root@ubuntu-ws01:~# systemctl enable --now sssd
Synchronizing state of sssd.service with SysV service script with /lib/systemd/systemd-sysv-install.
Executing: /lib/systemd/systemd-sysv-install enable sssd
root@ubuntu-ws01:~# pam-auth-update --enable mkhomedir
root@ubuntu-ws01:~# getent passwd jkowalski
jkowalski:*:20001:10001:Jan Kowalski:/home/jkowalski:/bin/bash
root@ubuntu-ws01:~# getent passwd anowak
anowak:*:20002:10002:Anna Nowak:/home/anowak:/bin/bash
root@ubuntu-ws01:~# getent group linuxadmins
getent group linuxusers
id jkowalski
id anowak
linuxadmins:*:10001:jkowalski
linuxusers:*:10002:jkowalski,anowak
uid=20001(jkowalski) gid=10001(linuxadmins) groups=10001(linuxadmins),10002(linuxusers)
uid=20002(anowak) gid=10002(linuxusers) groups=10002(linuxusers)
```

### 7.6 — Test SSH login as LDAP user on ubuntu-ws01

From rhel-srv01:
```bash
ssh jkowalski@10.10.10.30
```

On ubuntu-ws01, verify home directory:
```bash
ls -la /home/jkowalski/
```

Result:
```
[root@repo-srv01 ~]# ssh jkowalski@10.10.10.30
The authenticity of host '10.10.10.30 (10.10.10.30)' can't be established.
ED25519 key fingerprint is SHA256:4HuaJ8uh1qIbrUzqi/Mf9Gy5n2SwdrO45kWfTMZL00g.
This key is not known by any other names
Are you sure you want to continue connecting (yes/no/[fingerprint])? yes
Warning: Permanently added '10.10.10.30' (ED25519) to the list of known hosts.
jkowalski@10.10.10.30's password: 
Creating directory '/home/jkowalski'.
Welcome to Ubuntu 22.04 LTS (GNU/Linux 6.17.2-1-pve x86_64)

root@ubuntu-ws01:~# ls -la /home/jkowalski/
total 24
drwxr-xr-x 3 jkowalski linuxadmins 4096 Apr 13 12:19 .
drwxr-xr-x 3 root      root        4096 Apr 13 12:19 ..
-rw-r--r-- 1 jkowalski linuxadmins  220 Apr 13 12:19 .bash_logout
-rw-r--r-- 1 jkowalski linuxadmins 3771 Apr 13 12:19 .bashrc
drwx------ 2 jkowalski linuxadmins 4096 Apr 13 12:19 .cache
-rw-r--r-- 1 jkowalski linuxadmins  807 Apr 13 12:19 .profile
```

---
### Notes

Konfiguracja SSSD na Ubuntu jest zbliżona do RHEL, ale z kilkoma kluczowymi różnicami:

**Pakiety:** Ubuntu używa `libpam-sss` i `libnss-sss` zamiast RHEL-owych `sssd-client`. Pakiet `oddjob-mkhomedir` nie istnieje w Ubuntu — zamiast tego PAM module `pam_mkhomedir` jest zarządzany przez `pam-auth-update`.

**CA trust store:** Ubuntu przechowuje dodatkowe certyfikaty w `/usr/local/share/ca-certificates/` i odświeża trust store komendą `update-ca-certificates` (nie `update-ca-trust` jak w RHEL). Certyfikat musi mieć rozszerzenie `.crt`.

**PAM/NSS:** Zamiast `authselect` (RHEL), Ubuntu używa `pam-auth-update --enable mkhomedir` do włączenia automatycznego tworzenia katalogów domowych. NSS konfiguracja SSSD jest automatyczna po instalacji pakietów.

**DNS:** Proxmox LXC wpisuje `nameserver` bezpośrednio do `/etc/resolv.conf` (blok `BEGIN PVE`), co nadpisuje konfigurację `systemd-resolved`. Fix: `ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf` — symlink do pliku zarządzanego przez resolved.

---
### Conclusion

#### What - Co zrobiłem?
Zainstalowanie SSSD na `ubuntu-ws01`, skopiowanie CA cert, utworzenie `sssd.conf` identycznego jak na RHEL (z różnicą ścieżki CA), aktywacja SSSD i `pam_mkhomedir`. Weryfikacja: `getent` zwraca użytkowników LDAP, SSH login jako `jkowalski` tworzy katalog domowy.

---
#### Why - Dlaczego to zrobiłem?
Drugi klient LDAP potwierdza, że konfiguracja serwera jest uniwersalna — ten sam 389DS obsługuje klientów RHEL i Ubuntu. W produkcji heterogeniczne środowisko (mix dystrybucji) to norma.

---
#### Result - Co dzięki temu uzyskałem?
Dwie maszyny klienckie (`repo-srv01` RHEL, `ubuntu-ws01` Ubuntu) uwierzytelniają użytkowników przez centralny LDAP z TLS. Użytkownicy `jkowalski` i `anowak` mogą logować się przez SSH na obie maszyny z jednym kontem LDAP.

---
#### Lesson Learned - Co się nauczyłem?
- **Proxmox LXC nadpisuje `/etc/resolv.conf`** blokiem `BEGIN PVE` — `systemd-resolved` ma poprawny DNS, ale `/etc/resolv.conf` wskazuje na inny serwer. Fix: symlink do `/run/systemd/resolve/resolv.conf`.
- **Ubuntu nie ma `authselect`** — używa `pam-auth-update` do zarządzania modułami PAM. Odpowiednik `authselect select sssd with-mkhomedir` to `pam-auth-update --enable mkhomedir`.
- **`update-ca-certificates` vs `update-ca-trust`** — Ubuntu i RHEL mają różne ścieżki i komendy do zarządzania trust store. Ubuntu: `/usr/local/share/ca-certificates/` + `update-ca-certificates`. RHEL: `/etc/pki/ca-trust/source/anchors/` + `update-ca-trust`.
- **`sssd.conf` jest przenośny** — ta sama konfiguracja działa na obu dystrybucjach, jedyna różnica to ścieżka do CA cert.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
- **DNS nie działał na ubuntu-ws01** — Proxmox LXC wpisał `nameserver 10.10.10.10` do `/etc/resolv.conf`, nadpisując konfigurację `systemd-resolved`. Fix: `ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf`.

---

## Step 8 — Verify system login with LDAP users and TLS connectivity on both clients

### 8.1 — End-to-end TLS verification from both clients

From repo-srv01:
```bash
ldapsearch -x -H ldaps://rhel-srv01.linux.lab.local -D "uid=svc-readonly,ou=Services,dc=linux,dc=lab,dc=local" -w "ReadOnly123!" -b "ou=People,dc=linux,dc=lab,dc=local" "(uid=jkowalski)" uid cn
openssl s_client -connect rhel-srv01.linux.lab.local:636 </dev/null 2>/dev/null | openssl x509 -noout -subject -issuer -dates
```

From ubuntu-ws01:
```bash
ldapsearch -x -H ldaps://rhel-srv01.linux.lab.local -D "uid=svc-readonly,ou=Services,dc=linux,dc=lab,dc=local" -w "ReadOnly123!" -b "ou=People,dc=linux,dc=lab,dc=local" "(uid=jkowalski)" uid cn

openssl s_client -connect rhel-srv01.linux.lab.local:636 </dev/null 2>/dev/null | openssl x509 -noout -subject -issuer -dates
```

Result:
```
```

### 8.2 — Test login with each user on each client

SSH as jkowalski (admin group) to both clients:
```bash
ssh jkowalski@10.10.10.50   # repo-srv01
ssh jkowalski@10.10.10.30   # ubuntu-ws01
```

SSH as anowak (regular user group) to both clients:
```bash
ssh anowak@10.10.10.50      # repo-srv01
ssh anowak@10.10.10.30      # ubuntu-ws01
```

On each client, verify identity after login:
```bash
whoami
id
pwd
groups
```

Result:
```
anowak@ubuntu-ws01:~$ whoami
id
pwd
groups
anowak
uid=20002(anowak) gid=10002(linuxusers) groups=10002(linuxusers)
/home/anowak
linuxusers
anowak@ubuntu-ws01:~$ exit
logout
Connection to 10.10.10.30 closed.
[anowak@repo-srv01 ~]$ whoami
id
pwd
groups
anowak
uid=20002(anowak) gid=10002(linuxusers) groups=10002(linuxusers)
/home/anowak
linuxusers
[anowak@repo-srv01 ~]$ exit
logout
Connection to 10.10.10.50 closed.
jkowalski@ubuntu-ws01:~$ whoami
id
pwd
groups
jkowalski
uid=20001(jkowalski) gid=10001(linuxadmins) groups=10001(linuxadmins),10002(linuxusers)
/home/jkowalski
linuxadmins linuxusers
jkowalski@ubuntu-ws01:~$ exit
logout
Connection to 10.10.10.30 closed.
[jkowalski@repo-srv01 ~]$ whoami
id
pwd
groups
jkowalski
uid=20001(jkowalski) gid=10001(linuxadmins) groups=10001(linuxadmins),10002(linuxusers)
/home/jkowalski
linuxadmins linuxusers
[jkowalski@repo-srv01 ~]$
```

### 8.3 — Verify svc-backup cannot log in interactively

```bash
ssh svc-backup@10.10.10.50
ssh svc-backup@10.10.10.30
```

Expected: login denied — svc-backup is in `ou=Services`, not `ou=People`, so SSSD does not resolve it as a system user (`getent passwd svc-backup` returns empty). Additionally, loginShell is `/sbin/nologin`.

Result:
```
[root@repo-srv01 ~]# ssh svc-backup@10.10.10.50
svc-backup@10.10.10.50's password:
Permission denied, please try again.

[root@repo-srv01 ~]# getent passwd svc-backup
(empty — SSSD user search base is ou=People, svc-backup is in ou=Services)

[root@repo-srv01 ~]# ldapwhoami -x -H ldaps://rhel-srv01.linux.lab.local -D "uid=svc-backup,ou=Services,dc=linux,dc=lab,dc=local" -w "SvcBackup123!"
dn: uid=svc-backup,ou=services,dc=linux,dc=lab,dc=local
(LDAP bind works — account exists, but SSSD doesn't expose it as a system user)
```

### 8.4 — Verify SSSD cache is working

Stop 389DS on the server temporarily, then check if SSSD cache still resolves users on the client:
```bash
# On rhel-srv01 — stop LDAP server:
dsctl localhost stop

# On repo-srv01 — verify cache works offline:
getent passwd jkowalski
id jkowalski
# Should still resolve from SSSD cache

# On rhel-srv01 — start LDAP server back:
dsctl localhost start
```

Result:
```
[root@rhel-srv01 ~]# dsctl localhost stop
Instance "localhost" has been stopped

[root@repo-srv01 ~]# getent passwd jkowalski
jkowalski:*:20001:10001:Jan Kowalski:/home/jkowalski:/bin/bash
[root@repo-srv01 ~]# id jkowalski
uid=20001(jkowalski) gid=10001(linuxadmins) groups=10001(linuxadmins),10002(linuxusers)

[root@rhel-srv01 ~]# dsctl localhost start
Instance "localhost" has been started

```

---
### Notes

Step 8 to kompleksowa weryfikacja end-to-end całego środowiska LDAP: serwer 389DS + TLS + ACL + SSSD na dwóch klientach (RHEL i Ubuntu).

**Testy wykonane:**
- **8.1 — TLS z obu klientów:** `ldapsearch` przez LDAPS i `openssl s_client` potwierdzają poprawny certyfikat TLS (CN=rhel-srv01.linux.lab.local, CA=Lab CA, ważny do 2036).
- **8.2 — Login każdym kontem na każdym kliencie:** jkowalski (linuxadmins) i anowak (linuxusers) logują się przez SSH na repo-srv01 i ubuntu-ws01. Grupy, UID, home dir — wszystko poprawne.
- **8.3 — Konto serwisowe nie loguje się:** svc-backup nie może zalogować się interaktywnie — SSSD nie widzi kont z `ou=Services` (search base to `ou=People`). Dodatkowe zabezpieczenie: loginShell `/sbin/nologin`.
- **8.4 — SSSD cache offline:** Po zatrzymaniu 389DS (`dsctl localhost stop`) klient repo-srv01 nadal rozwiązuje `jkowalski` z cache (`cache_credentials = True`).

**Separacja `ou=Services` od `ou=People`:**
Konfiguracja `ldap_user_search_base = ou=People` w SSSD tworzy naturalną barierę — konta serwisowe (svc-readonly, svc-backup) istnieją w LDAP i mogą bindować się do katalogu, ale nie są widoczne jako użytkownicy systemowi. To wzorzec least-privilege: konta serwisowe służą do bindowania i backupów, nie do logowania interaktywnego.

---
### Conclusion

#### What - Co zrobiłem?
Weryfikacja end-to-end: TLS z obu klientów (LDAPS + certyfikat), login SSH jako jkowalski i anowak na obu maszynach, potwierdzenie blokady svc-backup, test offline cache SSSD po zatrzymaniu serwera LDAP.

---
#### Why - Dlaczego to zrobiłem?
Każdy komponent (TLS, ACL, SSSD, PAM, mkhomedir) został testowany osobno w poprzednich krokach. Step 8 weryfikuje, że wszystkie komponenty współpracują poprawnie jako całość — od certyfikatu TLS, przez bind svc-readonly, SSSD resolution, PAM authentication, aż po utworzenie katalogu domowego.

---
#### Result - Co dzięki temu uzyskałem?
Pełne potwierdzenie, że środowisko LDAP jest funkcjonalne: centralne uwierzytelnianie działa na dwóch klientach (RHEL + Ubuntu), TLS chroni komunikację, konta serwisowe są odizolowane od logowania interaktywnego, cache pozwala na krótkotrwałą pracę offline.

---
#### Lesson Learned - Co się nauczyłem?
- **`ldap_user_search_base` to mechanizm separacji** — konta w `ou=Services` nie są widoczne dla SSSD, co zapobiega interaktywnemu logowaniu nawet bez sprawdzania loginShell. To lepsza ochrona niż sam `/sbin/nologin`.
- **SSSD cache działa po zatrzymaniu serwera** — `cache_credentials = True` + `enumerate = True` powoduje, że SSSD przechowuje lokalne kopie danych LDAP. Użytkownicy, którzy choć raz się zalogowali, mogą być rozwiązani offline.
- **`sss_cache -E` czyści cache SSSD** — po zmianie hasła na serwerze LDAP, stary cache na kliencie może powodować `Permission denied`. Restart SSSD lub `sss_cache -E` wymusza ponowne pobranie danych.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
- **svc-backup `Permission denied` mimo ustawienia hasła** — SSSD cachował stare (zepsute) hasło. Fix: `sss_cache -E` + `systemctl restart sssd`. Dodatkowo, konto w `ou=Services` nie jest widoczne dla SSSD (`getent passwd svc-backup` — pusty wynik).

---

## Step 9 — Install Cockpit with cockpit-389-ds plugin on rhel-srv01

### 9.1 — Install Cockpit and 389DS plugin

Note: `cockpit-389-ds` is not in standard Rocky 9 repos. Install from official 389DS COPR repository.

```bash
dnf install -y cockpit
dnf install -y dnf-plugins-core
dnf copr enable @389ds/389-directory-server
dnf install -y cockpit-389-ds
```

Result:
```
```

### 9.2 — Enable and start Cockpit

```bash
systemctl enable --now cockpit.socket
```

Open firewall port:
```bash
firewall-cmd --permanent --add-service=cockpit
firewall-cmd --reload
```

Result:
```
```

### 9.3 — Access Cockpit web UI

Open a browser and navigate to:
```
https://rhel-srv01.linux.lab.local:9090
```

Log in as root. Navigate to **389 Directory Server** section in the left menu. Explore:
- Server configuration and settings
- DIT tree — browse entries (OUs, users, groups, service accounts)
- Schema browser
- Replication and monitoring
- System overview, networking, logs, terminal

Result:
```
```

---
### Notes

Cockpit to webowy panel do zarządzania serwerem Linux (port 9090). Uwierzytelnia przez PAM — widzi tylko tych użytkowników, których rozwiązuje NSS na danej maszynie.

**Dlaczego `jkowalski` nie może się zalogować do Cockpit na rhel-srv01?**
Na rhel-srv01 nie ma SSSD — to serwer LDAP, nie klient. Cockpit widzi tylko lokalnych użytkowników (`/etc/passwd`). Użytkownicy LDAP mogliby logować się do Cockpit na maszynach klienckich (repo-srv01, ubuntu-ws01), gdzie SSSD jest skonfigurowany.

**`cockpit-389-ds` z COPR** — plugin nie jest w standardowych repozytoriach Rocky 9. Oficjalny projekt 389DS udostępnia go przez COPR repo `@389ds/389-directory-server`. Wymaga instalacji `dnf-plugins-core` (plugin `copr` nie jest domyślnie dostępny w minimalnych kontenerach LXC).

**`/etc/cockpit/disallowed-users`** — domyślnie blokuje login root. Usunięcie root z tej listy pozwala na logowanie.

---
### Conclusion

#### What - Co zrobiłem?
Zainstalowanie Cockpit na rhel-srv01, aktywacja socketu, otwarcie portu firewall, zalogowanie jako root przez przeglądarkę na porcie 9090.

---
#### Why - Dlaczego to zrobiłem?
Cockpit zapewnia webowy dostęp do zarządzania serwerem — przegląd usług, logów, sieci, terminala. W produkcji przydatny do szybkiej diagnostyki bez SSH.

---
#### Result - Co dzięki temu uzyskałem?
Panel Cockpit dostępny pod `https://rhel-srv01.linux.lab.local:9090`. Root może zarządzać serwerem przez przeglądarkę. Plugin 389DS niedostępny — zarządzanie LDAP pozostaje przez CLI.

---
#### Lesson Learned - Co się nauczyłem?
- **`cockpit-389-ds` wymaga COPR w Rocky 9** — nie jest w standardowych repozytoriach. Instalacja: `dnf copr enable @389ds/389-directory-server` + `dnf install cockpit-389-ds`.
- **`dnf copr` wymaga `dnf-plugins-core`** — w minimalnych kontenerach LXC plugin nie jest zainstalowany domyślnie.
- **Root domyślnie zablokowany w Cockpit** — plik `/etc/cockpit/disallowed-users` zawiera `root`. Trzeba go usunąć, aby root mógł się logować.
- **Cockpit uwierzytelnia przez lokalny PAM** — użytkownicy LDAP mogą logować się tylko na maszynach z SSSD (klienty), nie na serwerze LDAP bez SSSD.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
- **Root `Permission denied` w Cockpit** — root był na liście `/etc/cockpit/disallowed-users`. Fix: `sed -i '/^root$/d' /etc/cockpit/disallowed-users`.
- **`cockpit-389-ds` not found w standardowych repo** — pakiet dostępny tylko przez COPR `@389ds/389-directory-server`. Fix: `dnf copr enable` + `dnf install cockpit-389-ds`.

---

## LAB-04 — Conclusion

### What - Co zrobiłem?
Wdrożenie kompletnego środowiska LDAP: instalacja i konfiguracja 389 Directory Server na rhel-srv01, utworzenie struktury DIT (base DN, OUs, grupy POSIX, użytkownicy, konta serwisowe), konfiguracja TLS z self-signed CA, wdrożenie ACL i ograniczenie dostępu anonimowego, konfiguracja SSSD na dwóch klientach (Rocky Linux repo-srv01, Ubuntu ubuntu-ws01), weryfikacja end-to-end, instalacja Cockpit.

---
### Why - Dlaczego to zrobiłem?
Centralne zarządzanie tożsamością to fundament administracji wielomaszynowej. LDAP pozwala zarządzać kontami z jednego miejsca zamiast tworzyć lokalne konta na każdej maszynie. TLS chroni poświadczenia w transporcie. ACL implementują zasadę least-privilege. SSSD na klientach integruje LDAP z systemowym PAM/NSS.

---
### Result - Co dzięki temu uzyskałem?
- **Centralny katalog LDAP** z dwoma użytkownikami (jkowalski, anowak), dwoma grupami POSIX (linuxadmins, linuxusers), dwoma kontami serwisowymi (svc-readonly, svc-backup).
- **TLS (LDAPS port 636)** z self-signed CA — cała komunikacja szyfrowana.
- **ACL** — svc-readonly ma read/search/compare, użytkownicy mogą zmieniać hasło, anonimowy dostęp zablokowany na poziomie serwera.
- **Dwóch klientów SSSD** (RHEL + Ubuntu) — logowanie SSH z kontem LDAP, automatyczne tworzenie katalogów domowych, cache offline.
- **Cockpit** — webowy panel zarządzania na rhel-srv01.

---
### Lesson Learned - Co się nauczyłem?
- 389DS wymaga ręcznego utworzenia base DN suffix entry przed dodaniem OUs.
- `ldappasswd` przez LDAPI może nie działać poprawnie — `ldapmodify` z plain text `userPassword` jest pewniejszy.
- ACI `deny` z `userdn="ldap:///anyone"` blokuje WSZYSTKICH (deny ma priorytet nad allow). Lepiej użyć `nsslapd-allow-anonymous-access=rootdse`.
- SSSD `ldap_user_search_base` separuje konta serwisowe od użytkowników systemowych.
- `authselect` nie jest zainstalowany domyślnie w minimalnych kontenerach LXC.
- Ubuntu i RHEL mają różne ścieżki CA trust store i komendy (update-ca-certificates vs update-ca-trust).
- Proxmox LXC nadpisuje `/etc/resolv.conf` — wymaga fixu DNS na każdym kontenerze.
- SSSD cache (`cache_credentials = True`) pozwala na rozwiązywanie użytkowników po zatrzymaniu serwera LDAP.
- `cockpit-389-ds` nie istnieje w Rocky 9 — zarządzanie LDAP pozostaje CLI-only.

---
### Problem solved - Jakie problemy zostały rozwiązane?
- **Base DN nie istniał** — `ldapadd` OUs zwracał `No such object (32)`. Fix: ręczne dodanie wpisu `dc=linux,dc=lab,dc=local`.
- **`Confidentiality required (13)`** — password operations wymagają LDAPI/LDAPS. Fix: użycie `ldapi://` socket.
- **`Invalid credentials (49)`** — hasła ustawione przez `ldappasswd` nie działały. Fix: `ldapmodify` z plain text `userPassword`.
- **ACI deny blokowało wszystkich** — deny `anyone` > allow. Fix: usunięcie ACI deny, użycie `nsslapd-allow-anonymous-access=rootdse`.
- **DNS na klientach** — Proxmox LXC wstawiał `nameserver 10.10.10.10`. Fix: nmcli (RHEL) lub symlink resolved (Ubuntu).
- **`authselect: command not found`** — Fix: `dnf install authselect`.
- **Root zablokowany w Cockpit** — Fix: usunięcie z `/etc/cockpit/disallowed-users`.
- **`cockpit-389-ds` not found** — Fix: `dnf copr enable @389ds/389-directory-server` + `dnf install cockpit-389-ds`.

---

### Baza wiedzy — pytania i odpowiedzi z LAB-04

Poniżej zebrane odpowiedzi na pytania, które pojawiły się podczas realizacji laboratorium. Stanowią materiał edukacyjny z perspektywą "big picture" — nie tylko jak coś działa, ale dlaczego tak jest i jak wpisuje się w szerszy kontekst administracji systemami.

---

#### 1. Jak administratorzy zarządzają użytkownikami LDAP w produkcji?

W produkcji administratorzy **prawie nigdy nie dodają użytkowników przez GUI**. Typowe podejścia:

**CLI z `dsidm` lub `ldapadd`** — najczęstsze w środowiskach 389DS. Jedna komenda `dsidm localhost user create` zastępuje 7 pól w formularzu GUI. Łatwe do skryptowania, powtarzalne, audytowalne.

**Skrypty bashowe z szablonami LDIF** — administrator przygotowuje szablon `.ldif` z parametrami (uid, cn, uidNumber itd.) i wrzuca go przez `ldapadd`. Pozwala na masowe dodawanie użytkowników z pliku CSV.

**Ansible / Puppet / Terraform** — w środowiskach enterprise zarządzanie LDAP jest częścią Infrastructure as Code. Moduł `community.general.ldap_entry` w Ansible pozwala deklaratywnie zarządzać wpisami LDAP — konfiguracja wersjonowana w Git, powtarzalna, z code review.

**Kiedy GUI?** Eksploracja struktury DIT, diagnostyka problemów, jednorazowe zmiany, nauka. Cockpit z pluginem `cockpit-389-ds` jest przydatny do przeglądania drzewa LDAP i rozumienia struktury, ale nie do codziennych operacji.

---

#### 2. Co to jest FreeIPA i jak się ma do 389DS?

**FreeIPA** (Identity, Policy, Audit) to kompletna platforma zarządzania tożsamością dla Linuxa — odpowiednik Active Directory w świecie Microsoft. To nie jest osobny produkt, lecz **zintegrowany stos** istniejących komponentów open source:

| Komponent | Rola | Analogia w AD |
|---|---|---|
| **389 Directory Server** | Katalog LDAP (baza użytkowników) | AD DS (Active Directory Domain Services) |
| **MIT Kerberos** | Uwierzytelnianie SSO (tickety) | AD Kerberos |
| **Dogtag Certificate System** | PKI, certyfikaty | AD Certificate Services |
| **BIND DNS** | Zintegrowany DNS | AD-integrated DNS |
| **SSSD** | Klient na maszynach | Winlogon / LSASS |

**Kluczowa różnica: 389DS vs FreeIPA**

389DS to "surowy" serwer LDAP — odpowiednik AD LDS (Lightweight Directory Services). Sam przechowuje dane, ale wymaga ręcznej konfiguracji TLS, ACL, haseł, schematów. To co zrobiliśmy w LAB-04 — ręcznie budowaliśmy każdy element.

FreeIPA automatyzuje to wszystko: `ipa user-add jkowalski --first=Jan --last=Kowalski` tworzy użytkownika z poprawnym schematem, przydziela UID, konfiguruje Kerberos, ustawia polityki haseł. Na kliencie `ipa-client-install` zastępuje ręczną konfigurację SSSD, certyfikatów i DNS jednym poleceniem.

**Dlaczego LAB-04 (ręczny 389DS) przed FreeIPA?** Bo IPA ukrywa kompleksowość. Bez LAB-04 nie zrozumiałbyś co IPA robi "pod spodem" — dlaczego potrzebny jest base DN, czym jest schemat rfc2307, jak działa TLS trust chain, co robi SSSD. Ta wiedza jest niezbędna do debugowania problemów w produkcji, nawet jeśli używasz FreeIPA.

---

#### 3. Jaka jest prawidłowa kolejność: najpierw FreeIPA czy AD integration?

W kontekście tego laba prawidłowa kolejność to: **LAB-05 (AD) → LAB-06 (FreeIPA + AD Trust)**.

**Dlaczego AD najpierw?**

- **Active Directory już działa** — `win-dc01` jest skonfigurowany od LAB-00. Nie trzeba niczego instalować, żeby zacząć AD join.
- **Gap G1 (Centrify/Linux-AD) jest priorytetem** — to pytanie na rozmowę kwalifikacyjną. Dokument `centrify-vs-sssd.md` z LAB-05 to kluczowy output.
- **`realmd` + SSSD to najprostszy scenariusz** domain join — jedno polecenie `realm join lab.local` i maszyna Linux jest w domenie AD. Dobre wprowadzenie przed bardziej złożonym FreeIPA.

**Dlaczego FreeIPA potem?**

- LAB-06 zakłada skonfigurowanie **cross-forest trust między FreeIPA a AD** — wymaga działającego AD i doświadczenia z domain join z LAB-05.
- FreeIPA trust z AD to zaawansowany scenariusz: AD users mogą logować się na maszyny zarządzane przez IPA i odwrotnie. Bez zrozumienia jak AD join działa (LAB-05), debugowanie trust byłoby bardzo trudne.

**Ścieżka nauki:**
```
LAB-04 (389DS ręcznie) → zrozumienie fundamentów LDAP
    ↓
LAB-05 (AD join z SSSD/realmd) → integracja Linux ↔ Windows AD
    ↓
LAB-06 (FreeIPA + AD Trust) → "Linux AD" + współpraca z Windows AD
```

Każdy kolejny lab buduje na wiedzy z poprzedniego. LAB-04 daje fundament LDAP. LAB-05 pokazuje jak Linux integruje się z istniejącą infrastrukturą Windows. LAB-06 dodaje FreeIPA jako alternatywny (lub uzupełniający) system tożsamości, który potrafi współpracować z AD.

---

#### 4. Co to jest `realmd` i do czego służy?

**realmd** to narzędzie do automatycznego dołączania maszyny Linux do domeny (Active Directory, FreeIPA, LDAP). Automatyzuje konfigurację SSSD/Winbind, Kerberos i PAM jednym poleceniem:

```bash
realm discover lab.local     # wykrywa domenę i wymagania
realm join lab.local          # dołącza maszynę do domeny
realm permit user@lab.local   # pozwala konkretnemu użytkownikowi na login
```

W LAB-04 nie potrzebowaliśmy `realmd` — skonfigurowaliśmy SSSD ręcznie, bo łączyliśmy się z "gołym" LDAP (389DS), a nie z domeną AD/IPA. `realmd` przydaje się głównie przy dołączaniu do domeny AD (LAB-05) lub IPA (LAB-06), gdzie automatyzuje cały proces konfiguracji.

Cockpit wyświetlał link "Install realmd support" — to propozycja włączenia zarządzania domeną przez web GUI. W kontekście LAB-04 (standalone LDAP) nie było to potrzebne.

---

#### 5. Jak wygląda "big picture" zarządzania tożsamością w środowisku Linux + Windows?

W typowym środowisku enterprise istnieją trzy modele:

**Model 1: Wszystko w AD (najprostszy)**
Wszystkie maszyny (Windows i Linux) dołączone do Active Directory. Linux używa SSSD/realmd do integracji. Zarządzanie centralne z Windows (RSAT, PowerShell). To model emulowany w LAB-05.
- **Zalety:** jedna baza użytkowników, jedno zarządzanie
- **Wady:** zależność od Windows, ograniczone Linux-specific features (HBAC, sudo centralne)

**Model 2: FreeIPA + AD Trust (zaawansowany)**
FreeIPA zarządza maszynami Linux, AD zarządza Windows. Cross-forest trust pozwala użytkownikom AD logować się na maszyny IPA. To model emulowany w LAB-06.
- **Zalety:** Linux-native management (HBAC, sudo, certyfikaty), współpraca z AD
- **Wady:** dwa systemy do zarządzania, więcej kompleksowości

**Model 3: Standalone LDAP (to co zrobiliśmy w LAB-04)**
Izolowany serwer LDAP bez integracji z AD. Przydatny dla małych środowisk Linux-only lub jako ćwiczenie edukacyjne.
- **Zalety:** prostota, niezależność od Windows
- **Wady:** brak SSO, brak integracji z AD, ręczne zarządzanie

**Centrify / OneIdentity** — komercyjne rozwiązanie, które robi to samo co SSSD/realmd (Model 1), ale z dodatkowymi funkcjami: GUI, audyt, MFA, granularne polityki. Gap G1 w planie laba dotyczy właśnie porównania Centrify z open-source SSSD.

**Podsumowanie ścieżki:**
```
LAB-04: Model 3 (standalone LDAP) → fundament, nauka
LAB-05: Model 1 (Linux w AD) → produkcyjne podejście, interview-ready
LAB-06: Model 2 (FreeIPA + AD Trust) → zaawansowane, pełny obraz
```

---

#### 6. Porównanie narzędzi GUI do zarządzania LDAP

| Narzędzie | Typ | Platforma | Opis |
|---|---|---|---|
| **Apache Directory Studio** | Standalone (Java) | Windows/Mac/Linux | Najpopularniejszy LDAP GUI. Pełne zarządzanie DIT, schematem, ACL. Łączy się z dowolnym serwerem LDAP. |
| **cockpit-389-ds** | Plugin Cockpit | Web (serwer) | Zarządzanie 389DS z poziomu Cockpit. Wymaga COPR w Rocky 9. |
| **LDAP Account Manager (LAM)** | Web app (PHP) | Web (serwer) | Webowa apka do zarządzania kontami. Ładny UI, ale wymaga Apache+PHP. |
| **phpLDAPadmin** | Web app (PHP) | Web (serwer) | Klasyczny LDAP browser. Przestarzały UI, ale prosty w instalacji. |
| **FreeIPA Web UI** | Wbudowany w IPA | Web (serwer) | Najwygodniejszy, ale wymaga pełnej instalacji FreeIPA. |

---

#### 7. Wymagane oprogramowanie — serwer LDAP i klienci

Poniższa tabela podsumowuje, jakie pakiety należy zainstalować na każdej maszynie, aby uruchomić środowisko LDAP z LAB-04.

**Serwer LDAP — rhel-srv01 (Rocky Linux 9)**

| Pakiet | Rola | Instalacja |
|---|---|---|
| `389-ds-base` | Serwer 389 Directory Server (slapd, dsconf, dsidm, dsctl) | `dnf install -y 389-ds-base` |
| `openssl` | Generowanie certyfikatów CA i TLS | preinstalowany |
| `cockpit` | Webowy panel zarządzania serwerem | `dnf install -y cockpit` |
| `dnf-plugins-core` | Plugin `copr` do dnf (wymagany dla cockpit-389-ds) | `dnf install -y dnf-plugins-core` |
| `cockpit-389-ds` | Plugin Cockpit do zarządzania 389DS przez GUI | `dnf copr enable @389ds/389-directory-server` + `dnf install -y cockpit-389-ds` |
| `firewalld` | Otwarcie portów LDAPS (636) i Cockpit (9090) | preinstalowany |

**Klient LDAP — repo-srv01 (Rocky Linux 9 / RHEL)**

| Pakiet | Rola | Instalacja |
|---|---|---|
| `sssd` | Demon SSSD — łączy się z LDAP, cachuje dane, integruje z PAM/NSS | `dnf install -y sssd` |
| `sssd-ldap` | Backend LDAP dla SSSD | `dnf install -y sssd-ldap` |
| `oddjob-mkhomedir` | Automatyczne tworzenie katalogów domowych przy pierwszym logowaniu | `dnf install -y oddjob-mkhomedir` |
| `authselect` | Konfiguracja PAM/NSS do użycia SSSD (zamiennik authconfig) | `dnf install -y authselect` |
| `openldap-clients` | Narzędzia CLI: `ldapsearch`, `ldapmodify`, `ldapadd` (diagnostyka) | `dnf install -y openldap-clients` |
| certyfikat CA | Plik `lab-ca.crt` skopiowany do `/etc/pki/ca-trust/source/anchors/` | `scp` + `update-ca-trust` |

**Klient LDAP — ubuntu-ws01 (Ubuntu 22.04)**

| Pakiet | Rola | Instalacja |
|---|---|---|
| `sssd` | Demon SSSD | `apt install -y sssd` |
| `sssd-ldap` | Backend LDAP dla SSSD | `apt install -y sssd-ldap` |
| `ldap-utils` | Narzędzia CLI: `ldapsearch`, `ldapmodify`, `ldapadd` (diagnostyka) | `apt install -y ldap-utils` |
| `libpam-sss` | Moduł PAM do uwierzytelniania przez SSSD | `apt install -y libpam-sss` |
| `libnss-sss` | Moduł NSS do rozwiązywania użytkowników/grup przez SSSD | `apt install -y libnss-sss` |
| certyfikat CA | Plik `lab-ca.crt` skopiowany do `/usr/local/share/ca-certificates/` | `scp` + `update-ca-certificates` |

**Kluczowe różnice RHEL vs Ubuntu:**

| Element | RHEL / Rocky | Ubuntu |
|---|---|---|
| Konfiguracja PAM/NSS | `authselect select sssd with-mkhomedir --force` | `pam-auth-update --enable mkhomedir` |
| Ścieżka CA trust store | `/etc/pki/ca-trust/source/anchors/` | `/usr/local/share/ca-certificates/` |
| Aktualizacja CA trust | `update-ca-trust` | `update-ca-certificates` |
| Auto-tworzenie $HOME | `oddjob-mkhomedir` (osobny pakiet) | wbudowane w `pam_mkhomedir.so` |
| Pakiet narzędzi LDAP | `openldap-clients` | `ldap-utils` |
