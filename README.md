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
Host / VM / LXC   IP             OS                        Role
----------------  -------------  ------------------------  --------------------------------
win-dc01          10.10.10.10    Windows Server 2022       AD DC, DNS, Group Policy
win-mgmt01        10.10.10.11    Windows 11 Enterprise     Management: RSAT, PowerShell, SSH
rhel-srv01        10.10.10.20    Rocky Linux 9 (LXC)       Apache, MySQL, Bind DNS, LDAP
ubuntu-ws01       10.10.10.30    Ubuntu 22.04 (LXC)        AD-joined client workstation
ipa-srv01         10.10.10.40    Rocky Linux 9 (LXC)       FreeIPA — LDAP, Kerberos, CA, DNS
repo-srv01        10.10.10.50    Rocky Linux 9 (LXC)       Local yum/apt mirror, ClamAV, Lynis
```

### Architecture diagram

```
┌─────────────────────────────────────────────────────┐
│  ALIENWARE M16 — bare metal                          │
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
│  │  rhel-srv01      │   │  ubuntu-ws01     │        │
│  │  Rocky Linux 9   │   │  Ubuntu 22.04    │        │
│  │  Apache, MySQL   │   │  AD-joined       │        │
│  │  Bind, LDAP      │   │  client          │        │
│  └──────────────────┘   └──────────────────┘        │
│                                                     │
│  ┌──────────────────┐   ┌──────────────────┐        │
│  │  ipa-srv01       │   │  repo-srv01      │        │
│  │  FreeIPA         │   │  Local repo      │        │
│  │  Kerberos, CA    │   │  ClamAV, Lynis   │        │
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
│   └── lab-02-apache.md
├── infrastructure/
│   ├── proxmox-setup.md    # Proxmox architecture documentation
│   └── lab-ssh-tunnel-connect.ps1  # One-click lab access script (SSH tunnels + RDP)
├── services/               # Per-service configs and test results (added per lab)
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
- [ ] LAB-02 — Apache hardened (in progress)
- [ ] LAB-03 — MySQL
- [ ] LAB-04 — OpenLDAP / 389DS
- [ ] LAB-05 — Linux-AD integration (SSSD/realmd)
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
