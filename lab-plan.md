# Lab Project Plan — Linux System Administrator Skills Gap Training

**Date:** 03.2026
**Goal:** Build practical experience in technologies required for a Linux System Administrator role and create a portfolio project on GitHub.

---

## 1. SKILLS GAP ANALYSIS

### 1.1. Identified gaps — CRITICAL priority (must-have from job description)

| # | Technology / Skill | Current status | Target |
|---|---------------------------|---------------|---------------------|
| G1 | **Centrify / Linux-AD integration** | SSSD/realmd lab, Samba+LDAP in production | Practical Linux-AD integration, Centrify workflow emulation |
| G2 | **FreeIPA (IPA Authentication)** | Indirect via LDAP | Install, configure, integrate with AD (trust), user management |
| G3 | **Bind DNS (RHEL/Ubuntu)** | Old experience on Solaris 10 | Configure on RHEL 9 + Ubuntu, forward/reverse zones, AD-integrated DNS |
| G4 | **MySQL administration** | Mainly PostgreSQL | Install, manage databases/users, backup/restore, replication |
| G5 | **Apache (RHEL hardened)** | Intermediate | Virtual hosts, TLS, reverse proxy, mod_security, SELinux contexts |
| G6 | **LDAP (OpenLDAP / 389DS)** | Old Solaris experience | Configure on RHEL, schema, ACL, integration with other services |
| G7 | **Ubuntu workstation admin** | Mainly Debian/RHEL | Daily management, AD integration, apt ecosystem |
| G8 | **Anti-malware (ClamAV, Lynis)** | Indirect | Deploy, configure scanning, reporting, automation |

### 1.2. Identified gaps — IMPORTANT priority (nice-to-have)

| # | Technology / Skill | Current status | Target |
|---|---------------------------|---------------|---------------------|
| G9 | **PowerShell + AD/Centrify automation** | PS + AD (no Centrify) | PS scripts for managing Linux accounts in AD |
| G10 | **Local repository management** | Fragmentary | Full yum/apt mirror, GPG signing, repo with custom packages |
| G11 | **Security hardening (NIST/CIS)** | NATO audits, no formal CIS | Harden RHEL/Ubuntu per CIS Benchmark, compliance documentation |
| G12 | **Release management (rollout/rollback)** | Experience but needs demonstration | Procedures with VM snapshots, Ansible rollback, documentation |

### 1.3. Strong areas (no lab needed, worth refreshing)

- Linux/RHEL 15+ years ✅
- Bash/Python scripting ✅
- Ansible (playbooks, roles, Vault) ✅
- VMware vSphere ✅
- Git ✅

---

## 2. LAB ARCHITECTURE

### 2.1. Physical infrastructure

**Physical host:** Alienware M16 — 13th Gen Intel i7-13700HX (16C/24T), 16 GB RAM, 1 TB SSD
**Hypervisor:** Proxmox VE 9 — bare metal install on 1 TB SSD
**Host IP:** 10.28.0.200 (vmbr0)
**Storage:** local-lvm (LVM-Thin on SSD) — all VM disks and LXC rootfs

```
┌─────────────────────────────────────────────────────┐
│  ALIENWARE M16 — bare metal                         │
│  CPU: i7-13700HX (16C/24T) | RAM: 16 GB | SSD: 1 TB │
├─────────────────────────────────────────────────────┤
│  Proxmox VE 9 — bare metal hypervisor               │
│  IP: 10.28.0.200 | Storage: local-lvm (1 TB SSD)    │
├─────────────────────────────────────────────────────┤
│                                                     │
│  ┌──────────────────┐   ┌──────────────────┐        │
│  │ VM: win-dc01     │   │ VM: win-mgmt01   │        │
│  │ Windows Srv 2022 │   │ Windows 11       │        │
│  │ AD DC + DNS + GP │   │ RSAT + PS 7      │        │
│  │ 4 GB | 40 GB     │   │ 4 GB | 60 GB     │        │
│  └──────────────────┘   └──────────────────┘        │
│                                                     │
│  ┌──────────────────┐   ┌──────────────────┐        │
│  │ LXC: rhel-srv01  │   │ VM: rhel-web01   │        │
│  │ Rocky Linux 9    │   │ Rocky Linux 9    │        │
│  │ Bind DNS, MySQL  │   │ Apache, TLS      │        │
│  │ LDAP             │   │ SELinux, proxy   │        │
│  │ 1.5 GB | 15 GB   │   │ 1 GB | 20 GB     │        │
│  └──────────────────┘   └──────────────────┘        │
│                                                     │
│  ┌──────────────────┐   ┌──────────────────┐        │
│  │ LXC: ubuntu-ws01 │   │ LXC: ipa-srv01   │        │
│  │ Ubuntu 22.04 LTS │   │ Rocky Linux 9    │        │
│  │ AD-joined client │   │ FreeIPA Server   │        │
│  │ 1 GB | 10 GB     │   │ LDAP, Kerberos   │        │
│  └──────────────────┘   │ 1.5 GB | 15 GB   │        │
│                         └──────────────────┘        │
│                                                     │
│  ┌──────────────────┐                               │
│  │ LXC: repo-srv01  │                               │
│  │ Rocky Linux 9    │                               │
│  │ Local yum/apt    │                               │
│  │ ClamAV, Lynis    │                               │
│  │ 1 GB | 20 GB     │                               │
│  └──────────────────┘                               │
│                                                     │
│  vmbr10 (10.10.10.0/24) — lab-internal, NAT         │
│  Gateway: Proxmox host (10.10.10.1 / 10.28.0.200)   │
│                                                     │
└─────────────────────────────────────────────────────┘
```

### 2.2. Network addressing

| Machine | IP | FQDN | Role |
|---------|-----|------|------|
| win-dc01 | 10.10.10.10 | win-dc01.lab.local | AD DC, DNS |
| win-mgmt01 | 10.10.10.11 | win-mgmt01.lab.local | Windows 11 management — RSAT, PowerShell, Centrify workflow emulation |
| rhel-srv01 | 10.10.10.20 | rhel-srv01.linux.lab.local | Bind DNS, MySQL, LDAP |
| rhel-web01 | 10.10.10.21 | rhel-web01.linux.lab.local | Apache, TLS, reverse proxy, SELinux |
| ubuntu-ws01 | 10.10.10.30 | ubuntu-ws01.linux.lab.local | Ubuntu client, AD-joined |
| ipa-srv01 | 10.10.10.40 | ipa-srv01.lab.local | FreeIPA server |
| repo-srv01 | 10.10.10.50 | repo-srv01.lab.local | Repo mirror, anti-malware |

### 2.3. RAM budget (actual configuration)

| Machine | Type | RAM | Notes |
|---------|-----|-----|-------|
| win-dc01 | VM (QEMU) | 4 GB | Windows Server 2022 |
| win-mgmt01 | VM (QEMU) | 4 GB | Windows 11 — RSAT, PowerShell 7 |
| rhel-srv01 | LXC | 1.5 GB | Bind DNS, MySQL, LDAP |
| rhel-web01 | VM (QEMU) | 1 GB | Apache, TLS, SELinux (full VM required) |
| ubuntu-ws01 | LXC | 1 GB | CLI only |
| ipa-srv01 | LXC | 1.5 GB | FreeIPA — if problematic, switch to VM |
| repo-srv01 | LXC | 1 GB | Lightweight |
| **Total** | | **14 GB** | ~2 GB left for Proxmox host |

Note on FreeIPA on LXC: FreeIPA requires systemd. If issues arise, use an unprivileged LXC with `nesting=1`, or replace with a lightweight VM.

---

## 3. LAB EXERCISE PLAN

### Structure per exercise

Each exercise has an identifier `LAB-XX` and follows this structure:
- **Scenario** — short narrative of what happens in the exercise
- **Goal** — one-line objective
- **Gap remedy** — gap ID(s) from Section 1 that this exercise addresses
- **Machine(s)** — lab targets
- **Steps** — high-level tasks; details are in `notes/lab-XX-*.md`
- **Documentation** — output artefacts committed to the repo

---

### Infrastructure preparation

#### LAB-00: Proxmox lab bootstrap ✅ COMPLETE

**Scenario:** The entire lab infrastructure is built from scratch on a bare-metal Proxmox host. An isolated internal network with NAT is created, then all VMs and LXC containers are provisioned, configured with static IPs, and verified. Windows DC is promoted to a domain controller and the management workstation is joined to the domain.

**Goal:** Build base infrastructure — network, templates, VMs/LXCs.

**Steps:**
1. Configure isolated lab network bridge with NAT to internet
2. Obtain OS images and LXC templates
3. Create and configure Windows DC VM — install OS, set static IP, promote to AD DC, configure DNS and initial OU structure
4. Create and configure Windows management VM — join domain, install RSAT and PowerShell 7+
5. Create and configure Rocky Linux LXC containers: rhel-srv01, ipa-srv01, repo-srv01
6. Create and configure Ubuntu LXC container: ubuntu-ws01
7. Verify network connectivity between all machines

**Deliverable:** All machines running, network communication verified (ping, SSH). ✅

**Notes:** `notes/lab-00-bootstrap.md`

---

### Core services — Bind, Apache, MySQL, LDAP

#### LAB-01: Bind DNS Server on RHEL

**Scenario:** Bind is deployed on `rhel-srv01` as the primary DNS resolver for all Linux machines. It is authoritative for the `linux.lab.local` subdomain (A records for all Linux hosts) and for the reverse zone `10.10.10.in-addr.arpa`. Queries for `lab.local` (Active Directory) are conditionally forwarded to win-dc01 — AD DNS continues to own its zone without modification. A delegation NS record added on win-dc01 makes `linux.lab.local` resolvable from Windows as well. After this lab, all Linux LXC containers use rhel-srv01 as their primary DNS resolver.

**Goal:** Deploy Bind on rhel-srv01 as the authoritative DNS for `linux.lab.local` and the reverse zone, with conditional forwarding to AD DNS for `lab.local`.

**Gap remedy:** G3 — Bind DNS (RHEL/Ubuntu)

**Machine:** rhel-srv01 (server); win-dc01 (delegation record); all Linux LXCs (resolver update)

**Prerequisite state:** rhel-srv01 post-LAB-00 (fresh). Take a Proxmox snapshot of rhel-srv01 before starting.

**Steps:**
1. Install Bind and DNS utilities
2. Configure forward zone for `linux.lab.local`
3. Configure reverse zone for the lab subnet
4. Set up conditional forwarding to AD DNS and external internet forwarder
5. Apply SELinux contexts and firewall rules
6. Add NS delegation on win-dc01 and update Linux LXC resolvers
7. Test forward and reverse resolution and cross-platform name resolution

**Documentation:** `notes/lab-01-bind.md`

**Interview questions covered:**
- "How would you configure Bind DNS on RHEL?"
- "How do you handle forward and reverse zones?"
- "How does DNS integrate between Linux Bind and Windows AD DNS?"
- "How would you set up DNS delegation in a mixed Windows/Linux environment?"

---

#### LAB-02: Apache Web Server with hardening ✅ COMPLETE

**Scenario:** A dedicated Rocky Linux 9 VM (`rhel-web01`) is provisioned specifically for this exercise. A full VM (not LXC) is required because SELinux enforcement — a key part of Apache hardening on RHEL — is not available in LXC containers (limitation documented in LAB-01). Apache is deployed on `rhel-web01` with multiple virtual hosts, TLS termination using a self-signed CA, and a reverse proxy configuration. Server hardening covers SELinux contexts and booleans, information disclosure, security response headers, and HTTP method restrictions.

**Goal:** Deploy a hardened Apache web server with virtual hosts, TLS, reverse proxy, and SELinux on a dedicated RHEL VM.

**Gap remedy:** G5 — Apache (RHEL hardened)

**Machine:** rhel-web01 (new VM, Rocky Linux 9 minimal); rhel-srv01 (DNS record integration)

**Prerequisite state:** Proxmox host ready (post-LAB-00). Rocky Linux 9 ISO available. rhel-srv01 post-LAB-01 (Bind running — needed for DNS integration of the new VM).

**Steps:**
1. Provision rhel-web01 VM and integrate into the lab environment
2. Install Apache with SSL module
3. Issue a TLS certificate (self-signed CA)
4. Configure virtual hosts: default with HTTP→HTTPS redirect, named static site, named reverse proxy
5. Configure SELinux contexts and booleans for each virtual host type
6. Open required firewall ports
7. Apply server hardening: suppress version disclosure, add security headers, restrict HTTP methods
8. Test all virtual hosts, verify TLS, SELinux, and hardening

**Documentation:** `notes/lab-02-apache.md`

---

#### LAB-03: MySQL Server Administration

**Scenario:** MySQL is installed on `rhel-srv01` and configured for a production-like workload. Separate database accounts are created per function (application user, backup user), server parameters are tuned for observability, and an automated backup script with rotation is implemented. The restore procedure is verified. SELinux contexts and network access restrictions complete the setup.

**Goal:** Install and manage MySQL on RHEL — databases, users, backup, security.

**Gap remedy:** G4 — MySQL administration

**Machine:** rhel-srv01

**Prerequisite state:** rhel-srv01 post-LAB-02 (Bind + Apache running). Take a Proxmox snapshot of rhel-srv01 before starting.

**Steps:**
1. Install MySQL and run initial security hardening
2. Create application database and role-separated users
3. Import sample dataset
4. Configure server parameters: network binding, slow query log, binary logging
5. Implement automated backup script with rotation (cron-scheduled)
6. Test full restore from backup
7. Configure SELinux contexts and firewall rules

**Documentation:**
- `services/mysql/README.md`
- `services/mysql/backup-script.sh`

---

#### LAB-04: LDAP — 389 Directory Server

**Scenario:** A standalone LDAP directory is deployed on `rhel-srv01` using 389 Directory Server. The directory tree is structured with standard OUs, populated with test users and groups via LDIF files, secured with TLS, and access-controlled via ACLs. SSSD is then configured to use this directory for local system authentication, completing the integration.

**Goal:** Deploy 389DS on RHEL as a central LDAP directory.

**Gap remedy:** G6 — LDAP (OpenLDAP / 389DS)

**Machine:** rhel-srv01

**Prerequisite state:** rhel-srv01 post-LAB-03 (Bind, Apache, MySQL running). Take a Proxmox snapshot of rhel-srv01 before starting.

**Steps:**
1. Install and initialise 389 Directory Server instance
2. Build DIT structure: base DN, OUs for People, Groups, Services
3. Populate users and groups using LDIF files
4. Enable TLS with a self-signed certificate
5. Define ACL policies for different bind DNs
6. Configure SSSD on rhel-srv01 to authenticate against LDAP
7. Verify system login with LDAP users and TLS connectivity

**Documentation:**
- `services/ldap/README.md`
- `services/ldap/schema/`
- `services/ldap/sssd-integration.md`

**Conflict note:** Configuring SSSD for 389DS authentication in this lab will conflict with LAB-05 (SSSD for AD). Before starting LAB-05, restore rhel-srv01 to the post-LAB-03 snapshot (pre-LAB-04 state) to ensure a clean SSSD configuration.

---

### Linux–Windows AD integration

#### LAB-05: Linux-AD integration with SSSD/realmd

**Scenario:** Both `rhel-srv01` and `ubuntu-ws01` are joined to the `lab.local` AD domain using SSSD and realmd. Login access is restricted to specific AD groups. The entire management workflow — OU structure, group membership, GPO — is conducted from `win-mgmt01` using RSAT and PowerShell, mirroring how Centrify-managed environments operate. The exercise concludes with a written Centrify-vs-SSSD comparison document.

**Goal:** Join RHEL and Ubuntu to the AD domain, emulating Centrify workflow.

**Gap remedy:** G1 — Centrify / Linux-AD integration

**Machines:** rhel-srv01, ubuntu-ws01, win-mgmt01

**Prerequisite state:** Restore rhel-srv01 to the post-LAB-03 snapshot (before LAB-04 SSSD-LDAP changes) — SSSD must not be pre-configured. ubuntu-ws01 post-LAB-00 (fresh). Take Proxmox snapshots of rhel-srv01 and ubuntu-ws01 before starting. After this lab both machines are AD-joined — take a new snapshot of each ("post-LAB-05") before proceeding to LAB-06.

**Steps:**
1. Install AD integration packages on rhel-srv01 (realmd, sssd, adcli, samba-common)
2. Discover and join the domain on rhel-srv01; configure SSSD identity and access providers
3. Restrict login to designated AD groups; configure automatic home directory creation
4. Repeat domain join and SSSD configuration on ubuntu-ws01
5. From win-mgmt01: create OU for Linux servers, create Linux admin/user groups, assign test users
6. Configure a GPO for the Linux Servers OU via GPMC
7. Verify end-to-end: AD user login on both Linux machines via SSH
8. Write `centrify-vs-sssd.md` comparing Centrify DirectControl ↔ SSSD/realmd feature by feature

**Documentation:**
- `ad-integration/README.md`
- `ad-integration/sssd.conf.example`
- `ad-integration/join-domain-rhel.sh`
- `ad-integration/join-domain-ubuntu.sh`
- `ad-integration/centrify-vs-sssd.md` ← key document for interview!

**Interview questions:**
- "Describe how you would integrate Linux with Active Directory"
- "What is your experience with Centrify?"
- "How do you control which AD users can log into Linux?"

---

#### LAB-06: FreeIPA Server + AD Trust

**Scenario:** FreeIPA is installed on `ipa-srv01` as a second identity provider running alongside Active Directory. A cross-forest trust is established so that AD users can access IPA-managed resources and vice versa. Host-Based Access Control rules and centralised sudo policies are configured to demonstrate IPA's access control model. `rhel-srv01` is enrolled as an IPA client and login is tested for both IPA and AD users.

**Goal:** Install FreeIPA and configure a cross-forest trust with Active Directory.

**Gap remedy:** G2 — FreeIPA (IPA Authentication)

**Machine:** ipa-srv01 (primary), rhel-srv01 (client)

**Prerequisite state:** ipa-srv01 post-LAB-00 (fresh). rhel-srv01 post-LAB-05 (AD-joined). Take a Proxmox snapshot of rhel-srv01 before IPA client enrolment. IPA client install requires leaving the AD domain first (`realm leave lab.local`). After this lab rhel-srv01 is no longer AD-joined — restore the post-LAB-05 snapshot when AD-joined state is needed again (e.g. LAB-10).

**Steps:**
1. Prepare ipa-srv01: hostname, DNS resolution, NTP synchronisation
2. Install FreeIPA server with integrated DNS
3. Configure users, groups, password policies, HBAC rules, and sudo rules
4. Establish AD trust: add conditional forwarder on win-dc01, run trust-add on ipa-srv01
5. Enrol rhel-srv01 as an IPA client
6. Test IPA user login, AD user login via trust, sudo rules, and HBAC restrictions

**Documentation:**
- `freeipa/README.md`
- `freeipa/install-guide.md`
- `freeipa/ad-trust-setup.md`
- `freeipa/hbac-sudo-policies.md`

**Interview questions:**
- "What is your experience with IPA authentication?"
- "How would you centralize sudo and access control for Linux?"

---

### Anti-malware, repositories, hardening

#### LAB-07: Anti-malware — ClamAV + Lynis

**Scenario:** ClamAV is deployed across the lab with scheduled scanning of sensitive directories and syslog-based alerting. An Ansible role handles deployment to multiple targets. Lynis security audits are run before and after remediation to capture a baseline and demonstrate measurable improvement. The before/after scores and the remediation log become the deliverable.

**Goal:** Deploy anti-malware scanning and security auditing across lab servers.

**Gap remedy:** G8 — Anti-malware (ClamAV, Lynis)

**Machines:** repo-srv01, rhel-srv01, ubuntu-ws01

**Prerequisite state:** Machines in their current configured state (post-LAB-06 or restored post-LAB-05 for rhel-srv01). Take Proxmox snapshots of rhel-srv01 and ubuntu-ws01 before running Lynis remediation — required to capture the before/after baseline comparison.

**Steps:**
1. Install and configure ClamAV on repo-srv01: signature updates, scan schedule, alerting
2. Deploy ClamAV to rhel-srv01 and ubuntu-ws01 via Ansible role
3. Run Lynis audit on all Linux servers; record baseline score
4. Identify and remediate top findings; document each change
5. Re-run Lynis audit and compare scores
6. Optionally run rkhunter for rootkit detection

**Documentation:**
- `security/antimalware/README.md`
- `security/antimalware/lynis-report-before.txt`
- `security/antimalware/lynis-report-after.txt`
- `security/antimalware/remediation-log.md`
- `ansible/roles/clamav/`

---

#### LAB-08: Local Repository Management

**Scenario:** `repo-srv01` becomes the lab's internal package mirror, serving both RPM (Rocky Linux) and DEB (Ubuntu) packages over HTTP. A custom RPM repository with GPG-signed packages is created. Client machines are pointed at the local mirror. A cron-scheduled sync script keeps the mirror current.

**Goal:** Create and serve local yum/apt mirrors for lab clients.

**Gap remedy:** G10 — Local repository management

**Machine:** repo-srv01 (server), rhel-srv01 + ubuntu-ws01 (clients)

**Prerequisite state:** repo-srv01 post-LAB-00 (fresh). Take a Proxmox snapshot of repo-srv01 before starting.

**Steps:**
1. Set up YUM/DNF mirror: sync upstream repo, create local repo metadata
2. Configure Apache on repo-srv01 to serve the RPM repo
3. Configure rhel-srv01 to use the local repo; verify package installation
4. Generate GPG key and sign packages
5. Set up APT mirror for Ubuntu packages
6. Configure ubuntu-ws01 to use the local APT mirror
7. Write and schedule a sync script for upstream synchronisation

**Documentation:**
- `services/repos/README.md`
- `services/repos/sync-repos.sh`

---

#### LAB-09: Security Hardening per CIS Benchmark

**Scenario:** RHEL 9 and Ubuntu 22.04 are hardened according to CIS Level 1 Server profiles. Controls are applied systematically across filesystem configuration, kernel network parameters, logging, access control, SSH, SELinux, and firewall policy. Ansible roles automate the process. Lynis and optionally OpenSCAP scores are recorded before and after to demonstrate measurable improvement. A mapping table links CIS controls to NIST SP 800-53 and ISO 27001.

**Goal:** Harden RHEL 9 and Ubuntu 22.04 per CIS Benchmark Level 1 Server profile.

**Gap remedy:** G11 — Security hardening (NIST/CIS)

**Machines:** rhel-srv01, ubuntu-ws01

**Prerequisite state:** rhel-srv01 and ubuntu-ws01 fully configured (post-LAB-08). Take Proxmox snapshots of both machines before starting. CIS hardening modifies SSH configuration, PAM, sysctl, and firewall rules — all previously configured services (Bind, Apache, MySQL, SSSD) must be re-tested and fixed up after applying controls. SSH hardening (e.g. PermitRootLogin no) affects direct root access — verify alternative admin access exists before applying.

**Steps:**
1. Obtain CIS Benchmark Level 1 Server profiles for RHEL 9 and Ubuntu 22.04
2. Record baseline Lynis score on both machines
3. Implement controls: filesystem mount options, disable unused services, kernel sysctl hardening
4. Implement controls: auditd rules, rsyslog configuration, log rotation
5. Implement controls: password policies, PAM lockout, umask, SSH hardening
6. Verify SELinux enforcing mode and firewall default-deny posture
7. Automate all controls as Ansible roles
8. Re-run Lynis (and optionally OpenSCAP) and compare scores
9. Produce CIS-to-NIST/ISO mapping table

**Documentation:**
- `security/hardening/README.md`
- `security/hardening/cis-rhel9-checklist.md`
- `security/hardening/cis-ubuntu2204-checklist.md`
- `security/hardening/nist-mapping.md`
- `ansible/roles/cis-hardening-rhel/`
- `ansible/roles/cis-hardening-ubuntu/`

---

### Automation and PowerShell

#### LAB-10: PowerShell — AD management + Linux integration

**Scenario:** The management workstation `win-mgmt01` is used as the sole control point for Linux account lifecycle management in Active Directory. PowerShell scripts handle user creation with POSIX attributes, group synchronisation, and status reporting — all without ever touching the DC directly. This emulates the automation layer that Centrify provides in production environments.

**Goal:** Automate Linux account management in Active Directory using PowerShell from win-mgmt01.

**Gap remedy:** G9 — PowerShell + AD/Centrify automation

**Machine:** win-mgmt01

**Prerequisite state:** win-mgmt01 post-LAB-05 (RSAT installed, domain joined). rhel-srv01 and ubuntu-ws01 must be AD-joined for end-to-end login verification — use post-LAB-05 snapshots if LAB-06 IPA enrolment changed their AD-joined status.

**Steps:**
1. Verify AD PowerShell module availability on win-mgmt01
2. Write scripts: new user with POSIX attributes, POSIX attribute update, POSIX user report, group sync
3. Test end-to-end: create user from win-mgmt01, verify in AD, verify SSH login on Linux machines
4. Write Centrify-vs-PowerShell automation comparison document

**Documentation:**
- `automation/powershell/README.md`
- `automation/powershell/scripts/`
- `automation/powershell/centrify-automation-comparison.md`

---

#### LAB-11: Ansible — Full post-install automation

**Scenario:** A complete Ansible project is built that can recreate the entire lab configuration from a single master playbook. Each prior exercise (LAB-01 to LAB-09) becomes an Ansible role. Ansible Vault manages secrets. Smoke tests in each role verify the deployed state. Running `site.yml` on a freshly provisioned set of containers produces a fully configured lab.

**Goal:** Fully automate lab configuration via Ansible — one role per service, one master playbook.

**Gap remedy:** G1–G11 — Full automation layer across all skills

**Machine:** Proxmox host or dedicated control LXC

**Prerequisite state:** Revert ALL lab machines (rhel-srv01, ubuntu-ws01, ipa-srv01, repo-srv01) to post-LAB-00 snapshots. Ansible must rebuild the entire stack from a clean baseline to prove end-to-end deployment works.

**Steps:**
1. Design Ansible project structure: inventory, group_vars, playbooks, roles
2. Create one role per service: bind, apache, mysql, ldap-389ds, sssd-ad-join, freeipa-server, freeipa-client, clamav, lynis, repo-server, cis-hardening-rhel, cis-hardening-ubuntu
3. Write master playbook `site.yml` that applies all roles to correct hosts
4. Implement Ansible Vault for all secrets (passwords, keys)
5. Add smoke tests to each role using assert and handlers
6. Run full stack deployment end-to-end and verify

**Documentation:**
- `ansible/README.md`
- Per-role `README.md` files

---

### Release management and documentation

#### LAB-12: Release Management — rollout, rollback, preventive maintenance

**Scenario:** A realistic release cycle is executed for an Apache version upgrade. The process covers pre-change checks, a Proxmox snapshot as a safety net, controlled rollout via Ansible with version pinning, smoke testing, and a practiced rollback. The exercise produces reusable templates for release plans, rollback procedures, and monthly preventive maintenance checklists. Git release workflow is demonstrated with feature branches and tags.

**Goal:** Demonstrate a repeatable, documented release management process.

**Gap remedy:** G12 — Release management (rollout/rollback)

**Machine:** rhel-srv01 (target), win-mgmt01 or control LXC (execution)

**Prerequisite state:** rhel-srv01 with Apache running (post-LAB-02 or post-LAB-09). Take a Proxmox snapshot of rhel-srv01 before starting — the rollback step (step 4) can use this snapshot to restore the pre-upgrade state via Proxmox.

**Steps:**
1. Prepare the release: take LXC snapshot, backup configuration files, document change record
2. Execute rollout via Ansible with version-pinned Apache package
3. Run smoke tests to verify the upgrade
4. Practice rollback: restore via Ansible or Proxmox snapshot restore
5. Produce release plan template and rollback procedure document
6. Produce monthly preventive maintenance checklist
7. Demonstrate Git release workflow: feature branch, PR, merge, version tag

**Documentation:**
- `docs/release-management/release-plan-template.md`
- `docs/release-management/rollback-procedure.md`
- `docs/release-management/preventive-maintenance.md`

---

## 4. GITHUB REPOSITORY STRUCTURE

```
win-linux-admin-lab/
├── README.md                          # Project overview, architecture, how to run
├── notes/                             # Working lab notes per LAB-XX
├── docs/
│   ├── architecture.md                # Infrastructure diagram and description
│   ├── network-diagram.md
│   ├── skills-matrix.md               # Which exercises cover which competencies
│   └── release-management/
├── infrastructure/
│   ├── proxmox-setup.md
│   └── scripts/                       # Bootstrap scripts
├── services/
│   ├── bind/
│   ├── apache/
│   ├── mysql/
│   ├── ldap/
│   └── repos/
├── ad-integration/
│   ├── README.md
│   ├── centrify-vs-sssd.md            # ← Key document for interview!
│   ├── join-domain-rhel.sh
│   └── join-domain-ubuntu.sh
├── freeipa/
│   ├── README.md
│   ├── ad-trust-setup.md
│   └── hbac-sudo-policies.md
├── security/
│   ├── antimalware/
│   └── hardening/
├── automation/
│   └── powershell/
└── ansible/
    ├── ansible.cfg
    ├── inventory/
    ├── playbooks/
    └── roles/
```

---

## 5. INTERVIEW GUIDE

### What this project demonstrates:

| Job requirement | Covered by | Evidence in repo |
|------------------------|---------------|----------------------|
| Linux RHEL servers | LAB-01–04, LAB-09 | `services/`, `ansible/roles/` |
| Ubuntu workstations | LAB-05, LAB-07, LAB-09 | `ad-integration/`, `security/` |
| Bind, Apache, MySQL, LDAP | LAB-01–04 | `services/bind,apache,mysql,ldap/` |
| Centrify / Linux-AD | LAB-05 + LAB-10 (win-mgmt01) | `ad-integration/centrify-vs-sssd.md` |
| IPA Authentication | LAB-06 | `freeipa/` |
| Anti-malware | LAB-07 | `security/antimalware/` |
| Ansible | LAB-11 | `ansible/` (full directory) |
| PowerShell + AD | LAB-10 (win-mgmt01) | `automation/powershell/` |
| Repos management | LAB-08 | `services/repos/` |
| SELinux | LAB-01–04, LAB-09 | Embedded in every service |
| Security standards | LAB-09 | `security/hardening/` |
| Release management | LAB-12 | `docs/release-management/` |
| Git | Entire project | GitHub repository |
| Bash scripting | LAB-01–08 | Scripts in every directory |
| Documentation | Entire project | `docs/`, README in every directory |

### Prepared interview answers:

**"What is your experience with Centrify?"**
→ "I built a complete Linux-AD integration lab. While I haven't used Centrify directly, I understand the architecture — it maps directly to SSSD zones, AD-based access control, and POSIX attribute management. I've documented a detailed comparison in my GitHub portfolio project." → show `centrify-vs-sssd.md`

**"How would you set up IPA authentication?"**
→ "In my lab I deployed FreeIPA with AD trust, HBAC rules, and centralized sudo. I can walk you through the entire setup." → show `freeipa/`

**"How do you handle anti-malware on Linux?"**
→ "I deployed ClamAV with scheduled scanning and Lynis for security auditing, automated with Ansible roles. I also ran before/after hardening scans to demonstrate measurable improvement." → show `security/antimalware/`

---

## 7. PREREQUISITES

### Downloads needed (before starting):
- [x] Windows Server 2022 Evaluation ISO (180-day trial) ✅
- [x] Windows 11 Enterprise Evaluation ISO (90-day trial) ✅
- [x] Rocky Linux 9 LXC template ✅
- [x] Ubuntu 22.04 LTS LXC template ✅
- [ ] CIS Benchmarks PDF: RHEL 9, Ubuntu 22.04 (free after registration at cisecurity.org)

### Accounts / access:
- [ ] Account on cisecurity.org (free)
- [ ] GitHub repo: `win-linux-admin-lab` (private → public when complete)

### Proxmox host (bare metal on Alienware M16) ✅:
- [x] Proxmox VE 9 installed bare metal on 1 TB SSD
- [x] Bridge vmbr10 (10.10.10.0/24) configured
- [x] NAT masquerade via iptables (persistent in /etc/network/interfaces)
- [x] Storage: local-lvm on SSD — sufficient for all VMs and LXCs
- [ ] Enable nesting for LXC if needed for systemd (FreeIPA)

---

## 8. TECHNICAL NOTES

### LXC vs VM — when to use which:

| Machine | Type | Reason |
|---------|-----|-------------|
| win-dc01 | VM (QEMU/KVM) | Windows Server requires full virtualisation |
| win-mgmt01 | VM (QEMU/KVM) | Windows 11 — RSAT, PowerShell, Centrify workflow emulation |
| rhel-srv01 | LXC | Lightweight, sufficient for services |
| ubuntu-ws01 | LXC | CLI only, no GUI needed |
| ipa-srv01 | LXC (nesting) or VM | FreeIPA requires systemd; LXC with nesting=1 should work, but VM is fallback |
| repo-srv01 | LXC | Simplest container |

### Potential issues:
1. FreeIPA on LXC — may require `features: nesting=1,keyctl=1` in LXC config. If it fails, replace with a lightweight VM (~1.5 GB RAM)
2. DNS conflicts — Bind on rhel-srv01 vs AD DNS vs FreeIPA DNS. Solution: use split-DNS, conditional forwarders
3. RAM pressure — do not run all machines simultaneously. FreeIPA and rhel-srv01 services can be used alternately
4. Windows licensing — use Evaluation editions: Windows Server 2022 (180 days), Windows 11 Enterprise (90 days). Sufficient for the entire project

---

*Plan based on analysis of job posting, compliance matrix and current CV.*
*Each exercise is designed to directly cover identified skill gaps and deliver a demonstrable artefact for the GitHub portfolio.*
