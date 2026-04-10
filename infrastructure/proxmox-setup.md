# Proxmox Lab Setup — Infrastructure Documentation

Project: win-linux-admin-lab
Updated: 30.03.2026
Status: LAB-00 complete

---

## Physical Host

```
Model:    Alienware M16
CPU:      Intel i7-13700HX (16C/24T)
RAM:      16 GB
Storage:  1 TB SSD (NVMe)
Hypervisor: Proxmox VE 9 — bare metal install
Host IP:  10.28.0.200 (vmbr0, home LAN)
```

---

## Network Configuration

```
Interface   Subnet              Role
vmbr0       10.28.0.0/24        Proxmox management, WAN uplink
vmbr10      10.10.10.0/24       Lab network — isolated, NAT via iptables
```

NAT masquerade rule (persistent in `/etc/network/interfaces`):

```
post-up   iptables -t nat -A POSTROUTING -s 10.10.10.0/24 -o vmbr0 -j MASQUERADE
post-down iptables -t nat -D POSTROUTING -s 10.10.10.0/24 -o vmbr0 -j MASQUERADE
```

Traffic flow: VM (10.10.10.x) → vmbr10 → Proxmox NAT → vmbr0 → router → internet.

---

## Storage

```
Storage ID   Type       Path           Used for
local        dir        /var/lib/vz    ISO images, CT templates
local-lvm    LVM-Thin   /dev/pve       VM disks, LXC rootfs (all machines)
```

---

## Virtual Machines and Containers

```
Hostname     Type   OS                       IP            RAM     Disk   CT/VM ID
win-dc01     VM     Windows Server 2022      10.10.10.10   4 GB    40 GB  101
win-mgmt01   VM     Windows 11 Enterprise    10.10.10.11   4 GB    60 GB  102
rhel-srv01   LXC    Rocky Linux 9            10.10.10.20   1.5 GB  15 GB  103
ubuntu-ws01  LXC    Ubuntu 22.04             10.10.10.30   1 GB    10 GB  104
ipa-srv01    LXC    Rocky Linux 9            10.10.10.40   1.5 GB  15 GB  105
repo-srv01   LXC    Rocky Linux 9            10.10.10.50   1 GB    20 GB  106
```

VM configuration (both Windows VMs):

```
Machine:     q35
BIOS:        OVMF (UEFI)
Disk bus:    SCSI + VirtIO SCSI controller
Network:     VirtIO (paravirtualized), bridge vmbr10
```

---

## VM and LXC Access

Sieć `10.10.10.0/24` jest izolowana — dostęp z laptopa wyłącznie przez Proxmox (`10.28.0.200`) jako pośrednik.

### Windows VMs — RDP przez tunel SSH

SSH local port forwarding z laptopa, następnie RDC na `localhost:<port>`:

```bash
ssh -L 23101:10.10.10.10:3389 root@10.28.0.200   # win-dc01
ssh -L 23111:10.10.10.11:3389 root@10.28.0.200   # win-mgmt01
```

Połącz RDC: WIN → `mstsc` → `localhost:23101` lub `localhost:23111`

### Linux LXC — SSH

**Opcja 1 — ProxyJump (najprościej):**

```bash
# rhel-srv01
ssh -J root@10.28.0.200 root@10.10.10.20

# rhel-web01
ssh -J root@10.28.0.200 root@10.10.10.21

# ubuntu-ws01
ssh -J root@10.28.0.200 root@10.10.10.30

# ipa-srv01
ssh -J root@10.28.0.200 root@10.10.10.40

# repo-srv01
ssh -J root@10.28.0.200 root@10.10.10.50

```

**Opcja 2 — Tunel portów:**

```bash
# Terminal 1
ssh -L 10020:10.10.10.20:22 root@10.28.0.200
# Terminal 2
ssh root@localhost -p 10020
```

**Opcja 3 — `~/.ssh/config` (najwygodniej ręcznie):**

```
Host proxmox
    HostName 10.28.0.200
    User root

Host rhel-srv01
    HostName 10.10.10.20
    User root
    ProxyJump proxmox

Host ubuntu-ws01
    HostName 10.10.10.30
    User root
    ProxyJump proxmox

Host ipa-srv01
    HostName 10.10.10.40
    User root
    ProxyJump proxmox

Host repo-srv01
    HostName 10.10.10.50
    User root
    ProxyJump proxmox
```

Potem wystarczy: `ssh rhel-srv01`, `ssh ipa-srv01` itd.

### Konfiguracja sshd na kontenerach LXC

Rocky Linux LXC nie startuje `sshd` automatycznie. Instalacja przez konsolę Proxmox:

```bash
# Wejście do kontenera (przykład dla rhel-srv01 CT 103)
pct exec 103 -- bash

# Wewnątrz kontenera (Rocky Linux)
dnf install -y openssh-server
systemctl enable --now sshd

# Ubuntu (CT 104)
pct exec 104 -- bash
apt install -y openssh-server
systemctl enable --now ssh
```

CT IDs: `103` = rhel-srv01, `104` = ubuntu-ws01, `105` = ipa-srv01, `106` = repo-srv01

### Automatyczny dostęp — skrypt

Po skonfigurowaniu `sshd` na wszystkich maszynach, dostęp do całego labu (RDC do Windows + terminale SSH do Linux) można zautomatyzować skryptem:

```
lab-ssh-tunnel-connect.ps1
```

Skrypt wykrywa dostępne maszyny, zestawia tunele RDP i otwiera sesje SSH bez podawania haseł (wymaga jednorazowej konfiguracji kluczy: `.\lab-ssh-tunnel-connect.ps1 -SetupKeys`).


## Domain

```
Domain:       lab.local
Forest level: Windows Server 2016
DC:           win-dc01 (10.10.10.10)
DNS:          win-dc01 — authoritative for lab.local
NetBIOS:      LAB
DSRM pass:    <see credentials.env>
```

DNS A records registered in lab.local:

```
win-mgmt01   10.10.10.11
rhel-srv01   10.10.10.20
ubuntu-ws01  10.10.10.30
ipa-srv01    10.10.10.40
repo-srv01   10.10.10.50
```

---

## Deployment Status

All machines created, configured, network verified, snapshots taken.

```
Machine      Status     Snapshot
win-dc01     running    fresh-installation, post-LAB-00
win-mgmt01   running    post-LAB-00
rhel-srv01   running    post-LAB-00
ubuntu-ws01  running    post-LAB-00
ipa-srv01    running    post-LAB-00
repo-srv01   running    post-LAB-00
```

---

*Source: `notes/lab-00-bootstrap.md`*
