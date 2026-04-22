# Linux Windows Admin Lab

A hands-on homelab built to close skill gaps for a Linux System Administrator role. The environment runs on Proxmox VE installed bare metal on an Alienware M16, covering Active Directory, DNS, Apache, MySQL, FreeIPA, LDAP, security hardening, and more.

---

## Goal

Gain practical experience with technologies required for a Linux System Administrator role, and produce a documented, reproducible lab for a professional portfolio.

Key skill gaps addressed:

- Centrify / Linux–AD integration (SSSD, realmd)
- FreeIPA (IPA Authentication, AD trust)
- Bind DNS on RHEL and Ubuntu
- MySQL administration
- Apache web server (hardened, TLS, SELinux)
- OpenLDAP / 389DS
- Ubuntu workstation administration and AD join
- Anti-malware (ClamAV, Lynis)

---

## Infrastructure

**Physical host:** Alienware M16 — Intel i7-13700HX, 16 GB RAM, 1 TB SSD  
**Hypervisor:** Proxmox VE 9 installed bare metal  
**Proxmox host IP:** 10.28.0.200  
**Lab network:** `vmbr10` — 10.10.10.0/24, NAT via iptables through `vmbr0`

### Machines

```
Host / VM / LXC   IP             OS                           Role
----------------  -------------  ---------------------------  --------------------------------
win-dc01          10.10.10.10    Windows Server 2022 (VM)     AD DC, DNS, Group Policy
win-mgmt01        10.10.10.11    Windows 11 Enterprise (VM)   Management: RSAT, PowerShell, SSH
rhel-srv01        10.10.10.20    Rocky Linux 9 (LXC)          Bind DNS, LDAP
rhel-web01        10.10.10.21    Rocky Linux 9 (VM)           Apache, MySQL (LAMP), TLS, SELinux
ubuntu-ws01       10.10.10.30    Ubuntu 22.04 (LXC)           AD-joined client workstation
ubuntu-ws02       10.10.10.31    Ubuntu 22.04 (VM)            AD-joined client workstation
ipa-srv01         10.10.10.40    Rocky Linux 9 (LXC)          FreeIPA — LDAP, Kerberos, CA, DNS
repo-srv01        10.10.10.50    Rocky Linux 9 (LXC)          Local yum/apt mirror, ClamAV, Lynis
```

### Architecture diagram

```
┌─────────────────────────────────────────────────────┐
│  ALIENWARE M16 — bare metal                         │
│  CPU: i7-13700HX  |  RAM: 16 GB  |  SSD: 1 TB       │
├─────────────────────────────────────────────────────┤
│  Proxmox VE 9 — bare metal hypervisor               │
│  IP: 10.28.0.200  |  Storage: local-lvm (1 TB SSD)  │
├─────────────────────────────────────────────────────┤
│                                                     │
│  ┌──────────────────┐   ┌──────────────────┐        │
│  │  win-dc01        │   │  win-mgmt01      │        │
│  │  Windows Srv 2022│   │  Windows 11      │        │
│  │  AD DC, DNS      │   │  RSAT, PS 7      │        │
│  └──────────────────┘   └──────────────────┘        │
│                                                     │
│  ┌──────────────────┐   ┌──────────────────┐        │
│  │  rhel-srv01      │   │  rhel-web01      │        │
│  │  Rocky Linux 9   │   │  Rocky Linux 9   │        │
│  │  Bind DNS, LDAP  │   │  Apache, MySQL   │        │
│  │                  │   │  TLS, SELinux    │        │
│  └──────────────────┘   └──────────────────┘        │
│                                                     │
│  ┌──────────────────┐   ┌──────────────────┐        │
│  │  ubuntu-ws01     │   │  ubuntu-ws02     │        │
│  │  Ubuntu 22.04    │   │  Ubuntu 22.04    │        │
│  │  AD-joined       │   │  AD-joined       │        │
│  │  client (LXC)    │   │  client (VM)     │        │
│  └──────────────────┘   └──────────────────┘        │
│                                                     │
│  ┌──────────────────┐   ┌──────────────────┐        │
│  │  ipa-srv01       │   │  repo-srv01      │        │
│  │  FreeIPA         │   │  Local repo      │        │
│  │  Kerberos, CA    │   │  ClamAV, Lynis   │        │
│  │                  │   │                  │        │
│  └──────────────────┘   └──────────────────┘        │
│                                                     │
│  vmbr10 — 10.10.10.0/24 (NAT via vmbr0)             │
└─────────────────────────────────────────────────────┘
```

---

## Repository Structure

```
.
├── notes/                  # Working lab notes per LAB-XX
│   ├── lab-00-bootstrap.md
│   ├── lab-01-bind.md
│   ├── lab-02-apache.md
│   ├── lab-03-mysql.md
│   ├── lab-04-ldap.md
│   ├── lab-05-linux-ad.md
│   └── centrify-vs-sssd.md
├── infrastructure/
│   ├── proxmox-setup.md    # Proxmox architecture documentation
│   └── lab-ssh-tunnel-connect.ps1  # One-click lab access script (SSH tunnels + RDP)
├── services/
│   └── ldap/scripts/       # LDAP account management scripts (bash + Ansible)
├── lab-plan.md             # Full project plan with all lab steps
├── LICENSE
└── README.md
```

---

## Progress

- [x] LAB-00 Phase 0 — Infrastructure bootstrap
  - [x] Proxmox VE bare metal, vmbr10 bridge, NAT
  - [x] win-dc01 — Windows Server 2022, AD DC, DNS, OUs, test accounts
  - [x] win-mgmt01 — Windows 11, domain-joined, RSAT, PowerShell 7, RDP via SSH tunnel
  - [x] rhel-srv01, ubuntu-ws01, ipa-srv01, repo-srv01 — LXC containers created and configured
  - [x] Snapshots taken of all machines
- [x] LAB-01 — Bind DNS on RHEL
  - [x] BIND authoritative for `linux.lab.local` + reverse zone
  - [x] Conditional forwarding to AD DNS, NS delegation on win-dc01
  - [x] All Linux resolvers updated to BIND
- [x] LAB-02 — Apache Web Server with hardening
  - [x] rhel-web01 VM provisioned (Rocky Linux 9, full VM for SELinux)
  - [x] Apache with TLS (self-signed CA), 3 virtual hosts
  - [x] SELinux enforcing — contexts and booleans configured
  - [x] Firewall, hardening (version suppression, security headers, TRACE blocked)
  - [x] Cross-platform verification (Linux + Windows)
- [x] LAB-03 — MySQL Server Administration
  - [x] MySQL 8.0.45 installed and hardened on rhel-web01 (LAMP stack)
  - [x] Application database with role-separated users (webapp_user, backup_user)
  - [x] Sample dataset imported, privilege separation verified
  - [x] Server tuning: bind-address localhost, slow query log, binary logging
  - [x] Automated backup script with 7-day rotation (cron)
  - [x] Full restore tested (DROP → restore → verify)
  - [x] SELinux contexts, booleans, firewall verified — zero AVC denials
- [x] LAB-04 — 389 Directory Server
  - [x] 389DS installed and configured on rhel-srv01 with TLS (LDAPS port 636)
  - [x] DIT: ou=People, ou=Groups, ou=Services — users and groups populated via LDIF
  - [x] ACL policies configured (Directory Manager, self-write, anonymous read restricted)
  - [x] SSSD configured on repo-srv01 (RHEL) and ubuntu-ws01 (Ubuntu) — login verified
  - [x] Account management scripts: bash + Ansible playbooks in `services/ldap/scripts/`
- [x] LAB-05 — Linux-AD integration (SSSD/realmd)
  - [x] rhel-web01 joined to `lab.local` via `realm join` (RHEL 9 toolchain: realmd, sssd, adcli, authselect)
  - [x] ubuntu-ws02 joined to `lab.local` (Ubuntu 22.04: sssd-ad, libnss-sss, libpam-sss, pam-auth-update)
  - [x] AD groups `linuxadmins`/`linuxusers` + test users (`testuser01`, `testuser02`, `service02`) provisioned
  - [x] Both hosts moved to `OU=Linux Systems,OU=Lab,DC=lab,DC=local`
  - [x] GPO `Linux Access Policy` with User Rights Assignment (Allow/Deny logon) linked to the OU
  - [x] SSSD `ad_gpo_access_control = enforcing` on both hosts; SSH allow/deny matrix verified
  - [x] SID-based UID mapping yields identical `uid`/`gid`/home across RHEL and Ubuntu
  - [x] `pam_oddjob_mkhomedir` (RHEL) and `pam_mkhomedir` (Ubuntu) confirmed creating `/home/%u@%d` on first login
  - [x] Deliverable: `notes/centrify-vs-sssd.md` — feature-by-feature comparison
- [ ] LAB-06 — FreeIPA + AD trust
- [ ] LAB-07 — ClamAV + Lynis
- [ ] LAB-08 — Local repository management
- [ ] LAB-09 — CIS hardening
- [ ] LAB-10 — PowerShell AD automation
- [ ] LAB-11 — Ansible full automation
- [ ] LAB-12 — Release management

---

## Notes

All lab steps are documented in `notes/lab-XX-*.md` — written in first person, in plain English, with technical parameters in code blocks.

Credentials in notes are replaced with placeholders (`<see credentials.env>`). Store your own passwords in a local `credentials.env` file — it is excluded from version control via `.gitignore`.
