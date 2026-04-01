# LAB-00: Bootstrapping Proxmox Lab — Working Notes

Start date: 26.03.2026
Status: Complete

---

## Step 1 — Configure isolated lab network bridge with NAT to internet ✅

I configured the bridge in Proxmox Web UI:
- pve > System > Network > Create > Linux Bridge

```
Name:    vmbr10
IP:      10.10.10.1/24
Gateway: (empty — NAT via iptables)
```

---

## Step 2 — Obtain OS images and LXC templates ✅

I downloaded the Windows ISO from Microsoft and uploaded it via Proxmox Web UI:
Proxmox Web UI > local > ISO Images > Upload

I downloaded LXC templates via Proxmox UI:
local > CT Templates > Templates > rocky-9, ubuntu-22.04

I downloaded the VirtIO drivers ISO from:
https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/
and uploaded it the same way.

---

## Step 3 — Windows DC VM: win-dc01 ✅

### 3.1 — Create VM (Windows Server 2022, 4 GB RAM, 40 GB disk)

I created the VM in Proxmox with the following parameters:

```
Proxmox UI > Create VM
General > Name: win-dc01
        > VM ID: 101
OS > ISO image: Windows Server 2022 ISO
   > Type: Microsoft Windows
   > Version: 11/2022/2025
   > Add additional driver for VirtIO drivers: virtio-win-0.1.285.iso
System > Machine: q35
       > BIOS: OVMF (UEFI)
       > EFI Storage: local-lvm
Disks > Bus: SCSI
      > Controller: VirtIO SCSI
      > Size: 40GB
      > Storage: local-lvm
CPU > Cores: 2
Memory > RAM: 4096 MB
Network > Bridge: vmbr10
        > Model: VirtIO (paravirtualized)
```

Problem — swtpm / TPM error:
Proxmox automatically added a virtual TPM when using UEFI/q35. Windows Server 2022 does not require TPM.
Resolution: I removed it via VM 101 > Hardware > TPM State > Remove

---

### 3.2 — Install OS and set static IP 10.10.10.10

I set language and locale:

```
Language: English
Keyboard: Polish
Region:   Poland
```

I selected edition: Standard Evaluation (Desktop Experience)
I selected installation type: Custom (Advanced)

The installer did not show any disks — I loaded the VirtIO storage driver (2k22) from the mounted virtio-win ISO.
After loading the driver the disk was visible, I continued the installation.

I set the `Administrator` password (see `credentials.env`) and logged in.

Note: RAM was initially 2048 MB — system was very slow. I increased it to 4096 MB in Proxmox.

---

### 3.3 — Install VirtIO network driver and enable RDP

I enabled RDP on the server (PowerShell as Administrator):

```text
via GUI: Server Manager > Local Server > Remote Desktop > Enable.
```

To connect from the laptop I set up an SSH tunnel to Proxmox using Powershell terminal:

```powershell
ssh -L 23101:10.10.10.10:3389 root@10.28.0.200
```

Then connected via RDP client to `localhost:13389`.
Note: use port `23101` (not 3389) to avoid conflict with the local RDP session on the laptop.

---

Windows did not detect the network card. I installed the VirtIO driver:
Device Manager > Ethernet Controller > Update driver > Browse my computer > D:\NetKVM\2k22\amd64
The card appeared as Red Hat VirtIO Ethernet Adapter.

I set a static IP:

```
IP:      10.10.10.10
Mask:    255.255.255.0 (/24)
Gateway: 10.10.10.1
DNS:     10.10.10.1  (temporary, before DC promotion)
```

I took a snapshot of win-dc01 named "fresh-installation".

---

### 3.4 — Promote to Domain Controller (lab.local)

I renamed the server to win-dc01:
- `System Properties > Computer Name > Change > win-dc01 > OK > Reboot`

I installed the AD DS role:
- `Server Manager > Add Roles and Features > Active Directory Domain Services + DNS Server > Install`

After installation I clicked the flag in 
- `Server Manager > Promote this server to a domain controller`

```
Deployment:              Add a new forest
Root domain name:        lab.local
Forest functional level: Windows Server 2016
Domain functional level: Windows Server 2016
DNS server:              yes
Global Catalog:          yes
DSRM Password:           <see credentials.env>
NetBIOS name:            LAB (auto)
Paths:                   default
```

Lesson Learned:
NetBIOS name is a short (max 15 characters) domain identifier used by legacy Windows protocols (NetBIOS, SMB).
DNS domain: `lab.local`, NetBIOS name: `LAB`.
Both login formats work: `LAB\Administrator` (NetBIOS style) and `Administrator@lab.local` (UPN/Kerberos style).
NetBIOS is legacy but AD still requires it during forest setup.

The server restarted automatically. I logged in as LAB\Administrator.

---

### 3.5 — Configure AD DNS and initial OU structure

I added A records in 
- `DNS Manager > Forward Lookup Zones > lab.local > New Host (A)`

```
win-mgmt01  10.10.10.11
rhel-srv01  10.10.10.20
ubuntu-ws01 10.10.10.30
ipa-srv01   10.10.10.40
repo-srv01  10.10.10.50
```

I created the OU structure in `Active Directory Users and Computers`:

```
lab.local
  └── Lab
       ├── Users
       ├── Computers
       └── Servers
```

I created user accounts in `Lab/Users`:

```
First Name   Login        Password
Testuser01   testuser01   <see credentials.env>
Testuser02   testuser02   <see credentials.env>
Service01    service01    <see credentials.env>
```

Account options: "Password never expires" checked, "User must change password" unchecked.

---

## Step 4 — Windows management VM: win-mgmt01 ✅

### 4.1 — Create VM (Windows 11 Enterprise Evaluation, 4 GB RAM, 60 GB disk)

I created a new VM in Proxmox with the following parameters:

```
Proxmox UI > Create VM
General > Name: win-mgmt01
        > VM ID: 102
OS > ISO image: Windows 11 Enterprise Evaluation ISO
   > Type: Microsoft Windows
   > Version: 11/2022/2025
   > Add additional driver for VirtIO drivers: virtio-win-0.1.285.iso
System > Machine: q35
       > BIOS: OVMF (UEFI)
       > EFI Storage: local-lvm
       > Add TPM: unchecked
Disks > Bus: SCSI
      > Controller: VirtIO SCSI
      > Size: 60GB
      > Storage: local-lvm
CPU > Cores: 2
Memory > RAM: 4096 MB
Network > Bridge: vmbr10
        > Model: VirtIO (paravirtualized)
```

I booted the VM and started installation with these settings:

```
Language:          English
Time and Currency: Polish
Keyboard:          Polish
Setup option:      Install Windows 11
```

Problem — TPM 2.0 required:
The installer showed "The PC must support TPM 2.0". Adding TPM in Proxmox caused a swtpm certificate error (swtpm_localca exit with status 1).
Workaround: pressed `Shift+F10` on the error screen, opened `regedit`, navigated to `HKEY_LOCAL_MACHINE\SYSTEM\Setup`, created key `LabConfig` with `DWORD` values:
- `BypassTPMCheck=1`
- `BypassSecureBootCheck=1`
- `BypassRAMCheck=1`
  
Closed `regedit` and went back — installer proceeded.

Problem — disk too small:
The installer required at least 52 GB. My disk was 40 GB.
I loaded the VirtIO SCSI driver first: Load Driver > amd64\w11\vioscsi.inf (Red Hat VirtIO SCSI pass-through Controller).
I deleted the VM and recreated it with 60 GB disk. Installer accepted the disk.

I selected Poland as region, chose no internet connection and set up a local account:

```
Username: LocalUser01
Password: <see credentials.env>
```

I completed the installation with default settings. The system logged in automatically as LocalUser01.

---

### 4.2 — Install VirtIO driver, set static IP, rename host

I installed the VirtIO network driver:
- `Device Manager > Ethernet Controller > Update driver > Browse my computer > D:\`

I set static IP:

```
IP:      10.10.10.11
Mask:    255.255.255.0 (/24)
Gateway: 10.10.10.1
DNS:     10.10.10.10
```

I renamed the host from the default name to `win-mgmt01` and restarted.
DC responded to ping on both IP and FQDN.

Note: Proxmox is now running bare metal on a 1 TB SSD.

---

### 4.3 — Join domain lab.local

I joined the domain using Admin account from AD DC:

```
Settings > System > About > Domain or workgroup > System Properties
Username:    Administrator
Password:    <see credentials.env>
Domain name: lab.local
```

After restart the login screen showed LAB.LOCAL\Administrator. I logged in with the Administrator password.

---

#### Lesson Learned — Internet access for VMs in an isolated network (NAT)

VMs on vmbr10 (10.10.10.0/24) have no internet access by default — the network is isolated.
To enable internet access, Proxmox must act as a NAT router.

Steps on Proxmox host:

```bash
# Enable IP forwarding (active immediately, lost on reboot)
echo 1 > /proc/sys/net/ipv4/ip_forward

# Add NAT masquerade rule (active immediately, lost on reboot)
iptables -t nat -A POSTROUTING -s 10.10.10.0/24 -o vmbr0 -j MASQUERADE
```

To make it persistent across reboots, add to `/etc/network/interfaces` inside the `iface vmbr0` block:

```
post-up   iptables -t nat -A POSTROUTING -s 10.10.10.0/24 -o vmbr0 -j MASQUERADE
post-down iptables -t nat -D POSTROUTING -s 10.10.10.0/24 -o vmbr0 -j MASQUERADE
```

Traffic flow: VM (10.10.10.x) → vmbr10 → Proxmox NAT → vmbr0 (10.28.0.200) → router → internet.
The router sees packets from 10.28.0.200, not from the internal 10.10.10.x range.

---

### 4.4 — Enable RDP and install RSAT

I enabled Remote Desktop:
```
Settings > System > Remote Desktop > Enable Remote Desktop → ON
```

I set up an SSH tunnel from the Windows host:
```bash
ssh -L 23111:10.10.10.11:3389 root@10.28.0.200
```

I installed RSAT tools (PowerShell as Administrator):

```powershell
Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0
Add-WindowsCapability -Online -Name Rsat.Dns.Tools~~~~0.0.1.0
Add-WindowsCapability -Online -Name Rsat.GroupPolicy.Management.Tools~~~~0.0.1.0
```


---

### 4.5 — Install PowerShell 7+ and ActiveDirectory module

I checked PowerShell version:
```powershell
$PSVersionTable
```

Download PowerShell 7 installer from:
https://github.com/PowerShell/PowerShell/releases
Choose: PowerShell-7.x.x-win-x64.msi
https://github.com/PowerShell/PowerShell/releases/download/v7.6.0/PowerShell-7.6.0-win-x64.msi


After installation, open PowerShell 7 and install the ActiveDirectory module:

```powershell
Install-Module -Name ActiveDirectory -Force
```

Or if RSAT is installed, the module is already available — just import it:

```powershell
Import-Module ActiveDirectory
Get-ADUser -Filter * -SearchBase "OU=Users,OU=Lab,DC=lab,DC=local"
```

---

### 4.6 — Verify management workstation

Run the following checks from win-mgmt01:

```powershell
# Check domain membership
(Get-WmiObject Win32_ComputerSystem).Domain

# List AD users from lab OU
Get-ADUser -Filter * -SearchBase "OU=Users,OU=Lab,DC=lab,DC=local" | Select Name, SamAccountName

# Test DNS resolution
Resolve-DnsName win-dc01.lab.local
Resolve-DnsName rhel-srv01.lab.local
```

Result
```powershell
PS C:\Windows\System32> (Get-WmiObject Win32_ComputerSystem).Domain
lab.local
PS C:\Windows\System32> Get-ADUser -Filter * -SearchBase "OU=Users,OU=Lab,DC=lab,DC=local" | Select Name, SamAccountName

Name       SamAccountName
----       --------------
Testuser01 testuser01
Testuser02 testuser02
Service02  service02

PS C:\Windows\System32> Resolve-DnsName win-dc01.lab.local

Name                                           Type   TTL   Section    IPAddress
----                                           ----   ---   -------    ---------
win-dc01.lab.local                             A      3600  Answer     10.10.10.10

PS C:\Windows\System32> Resolve-DnsName rhel-srv01.lab.local

Name                                           Type   TTL   Section    IPAddress
----                                           ----   ---   -------    ---------
rhel-srv01.lab.local                           A      3600  Answer     10.10.10.20
```

---

## Step 5 — Rocky Linux LXC containers: rhel-srv01, ipa-srv01, repo-srv01 ✅

All three containers were created with the same approach: Rocky Linux 9 template, static IP, DNS pointing to win-dc01 (10.10.10.10).

### rhel-srv01 (CT ID: 103)

```
Proxmox UI > Create CT
General > Hostname: rhel-srv01
        > CT ID: 103
        > Password: <see credentials.env>
Template > rocky-9
Disks > Storage: local-lvm
      > Size: 15GB
CPU > Cores: 1
Memory > RAM: 1536 MB
       > Swap: 512 MB
Network > Name: eth0
        > Bridge: vmbr10
        > IPv4: Static
        > IP: 10.10.10.20/24
        > Gateway: 10.10.10.1
DNS > DNS domain: lab.local
   > DNS server: 10.10.10.10
```

Static IP 10.10.10.20 — configured.

---

### ipa-srv01 (CT ID: 105)

```
Proxmox UI > Create CT
General > Hostname: ipa-srv01
        > CT ID: 105
        > Password: <see credentials.env>
Template > rocky-9
Disks > Storage: local-lvm
      > Size: 15GB
CPU > Cores: 1
Memory > RAM: 1536 MB
       > Swap: 512 MB
Network > Name: eth0
        > Bridge: vmbr10
        > IPv4: Static
        > IP: 10.10.10.40/24
        > Gateway: 10.10.10.1
DNS > DNS domain: lab.local
   > DNS server: 10.10.10.10
```

Static IP 10.10.10.40 — configured.

---

### repo-srv01 (CT ID: 106)

```
Proxmox UI > Create CT
General > Hostname: repo-srv01
        > CT ID: 106
        > Password: <see credentials.env>
Template > rocky-9
Disks > Storage: local-lvm
      > Size: 20GB
CPU > Cores: 1
Memory > RAM: 1024 MB
       > Swap: 512 MB
Network > Name: eth0
        > Bridge: vmbr10
        > IPv4: Static
        > IP: 10.10.10.50/24
        > Gateway: 10.10.10.1
DNS > DNS domain: lab.local
   > DNS server: 10.10.10.10
```

Static IP 10.10.10.50 — configured.

---

## Step 6 — Ubuntu LXC container: ubuntu-ws01 ✅

```
Proxmox UI > Create CT
General > Hostname: ubuntu-ws01
        > CT ID: 104
        > Password: <see credentials.env>
Template > ubuntu-22.04
Disks > Storage: local-lvm
      > Size: 10GB
CPU > Cores: 1
Memory > RAM: 1024 MB
       > Swap: 512 MB
Network > Name: eth0
        > Bridge: vmbr10
        > IPv4: Static
        > IP: 10.10.10.30/24
        > Gateway: 10.10.10.1
DNS > DNS domain: lab.local
   > DNS server: 10.10.10.10
```

Static IP 10.10.10.30 — configured.

---

## Step 7 — Verify network connectivity ✅

After all machines were provisioned, I verified connectivity from the Proxmox host and between VMs.

```bash
# From Proxmox host — ping all machines
ping -c 2 10.10.10.10   # win-dc01
ping -c 2 10.10.10.11   # win-mgmt01
ping -c 2 10.10.10.20   # rhel-srv01
ping -c 2 10.10.10.30   # ubuntu-ws01
ping -c 2 10.10.10.40   # ipa-srv01
ping -c 2 10.10.10.50   # repo-srv01
```

SSH verified: all LXC containers accessible via `ssh root@10.10.10.xx` from Proxmox host.

DNS resolution verified from win-mgmt01 — see Step 4.6 output above.

I took Proxmox snapshots of all machines after completing LAB-00:
win-dc01, win-mgmt01, rhel-srv01, ubuntu-ws01, ipa-srv01, repo-srv01.
