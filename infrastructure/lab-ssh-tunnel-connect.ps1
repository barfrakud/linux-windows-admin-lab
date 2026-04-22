# lab-ssh-tunnel-connect.ps1
# Łączy z maszynami laboratoryjnymi przez Proxmox jako jump host.
# Windows VMs  → tunel RDP (mstsc) na localhost:<port>
# Linux hosts  → nowe okno terminala z sesją SSH
#
# Wymaganie wstępne: działający ssh server na każdej linuxowej maszynie i włączona opcja PermitRootLogin yes - tylko w środowisku testowym!
# Uruchomienie: .\lab-ssh-tunnel-connect.ps1
# Jednorazowa konfiguracja kluczy SSH: .\lab-ssh-tunnel-connect.ps1 -SetupKeys

param(
    [switch]$SetupKeys
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

# ── Konfiguracja ─────────────────────────────────────────────────────────────

$PROXMOX_HOST = "10.28.0.200"
$PROXMOX_USER = "root"
$PROXMOX      = "$PROXMOX_USER@$PROXMOX_HOST"

$Script:AvailableHosts = @{}

$WindowsVMs = @(
    [PSCustomObject]@{ Name = "win-dc01";   IP = "10.10.10.10"; RdpPort = 3389; LocalPort = 23101 },
    [PSCustomObject]@{ Name = "win-mgmt01"; IP = "10.10.10.11"; RdpPort = 3389; LocalPort = 23111 }
)

$LinuxSSHHosts = @(
    [PSCustomObject]@{ Name = "rhel-srv01";  IP = "10.10.10.20"; User = "root" },
    [PSCustomObject]@{ Name = "rhel-web01";  IP = "10.10.10.21"; User = "root" },
    [PSCustomObject]@{ Name = "ubuntu-ws01"; IP = "10.10.10.30"; User = "root" },
    [PSCustomObject]@{ Name = "ubuntu-ws02"; IP = "10.10.10.31"; User = "root" },
    [PSCustomObject]@{ Name = "ipa-srv01";   IP = "10.10.10.40"; User = "root" },
    [PSCustomObject]@{ Name = "repo-srv01";  IP = "10.10.10.50"; User = "root" }
)

# ── Helpers ───────────────────────────────────────────────────────────────────

$TunnelPIDs = [System.Collections.Generic.List[int]]::new()

function Write-Header {
    param([string]$Text)
    Write-Host ""
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ("  " + ("-" * ($Text.Length))) -ForegroundColor DarkCyan
}

function Write-Status {
    param([string]$Label, [string]$Text, [string]$Color = "White")
    $pad = "    "
    Write-Host "$pad" -NoNewline
    Write-Host $Label -ForegroundColor DarkGray -NoNewline
    Write-Host " $Text" -ForegroundColor $Color
}

function Test-ProxmoxReachable {
    $ok = Test-Connection -ComputerName $PROXMOX_HOST -Count 2 -Quiet 2>$null
    return $ok
}

function Initialize-HostAvailability {
    Write-Host "    Sprawdzanie dostepnosci maszyn przez Proxmox..." -ForegroundColor DarkGray
    $checks = @()
    foreach ($vm  in $WindowsVMs) { $checks += "$($vm.IP):$($vm.RdpPort)" }
    foreach ($linuxHost in $LinuxSSHHosts) { $checks += "$($linuxHost.IP):22" }
    $checkList = $checks -join " "
    $sshCmd = "for entry in $checkList; do ip=`${entry%:*}; port=`${entry#*:}; (echo > /dev/tcp/`$ip/`$port) 2>/dev/null; echo `$ip:`$?; done"
    $output = & ssh -o "ConnectTimeout=10" -o "StrictHostKeyChecking=accept-new" $PROXMOX $sshCmd 2>&1
    foreach ($line in $output) {
        $line = "$line".Trim()
        if ($line -match "^([\d.]+):(\d+)$") {
            $Script:AvailableHosts[$Matches[1]] = ($Matches[2] -eq "0")
        }
    }
}

function Test-HostAvailable {
    param([string]$IP)
    return ($Script:AvailableHosts[$IP] -eq $true)
}

function Start-RDPTunnel {
    param($VM)

    # Sprawdź czy port jest już zajęty
    $portInUse = Get-NetTCPConnection -LocalPort $VM.LocalPort -State Listen -ErrorAction SilentlyContinue
    if ($portInUse) {
        Write-Status "[TUNEL]" "localhost:$($VM.LocalPort) — port już zajęty, tunel aktywny" "Yellow"
    } else {
        $tunnelArgs = @("-N", "-o", "StrictHostKeyChecking=accept-new", "-L", "$($VM.LocalPort):$($VM.IP):$($VM.RdpPort)", $PROXMOX)
        $proc = Start-Process -FilePath "ssh" -ArgumentList $tunnelArgs -WindowStyle Normal -PassThru
        $TunnelPIDs.Add($proc.Id)
        Write-Status "[TUNEL]" "localhost:$($VM.LocalPort) → $($VM.Name) (PID $($proc.Id))" "Green"
        Write-Status "[CZEK] " "Czekam az tunel bedzie gotowy..." "DarkGray"
        $ready = $false
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Milliseconds 500
            $listening = Get-NetTCPConnection -LocalPort $VM.LocalPort -State Listen -ErrorAction SilentlyContinue
            if ($listening) { $ready = $true; break }
        }
        if (-not $ready) {
            Write-Status "[WARN] " "Tunel nie odpowiada — sprawdz okno SSH (haslo?)" "Yellow"
        }
    }

    Write-Status "[RDP]  " "Uruchamianie mstsc → localhost:$($VM.LocalPort)" "Green"
    Start-Process "mstsc" -ArgumentList "/v:localhost:$($VM.LocalPort)"
}

function Open-SSHTerminal {
    param($LXC)
    $sshTarget  = "$($LXC.User)@$($LXC.IP)"
    $sshConnect = "ssh -J $PROXMOX $sshTarget"

    if (Get-Command "wt" -ErrorAction SilentlyContinue) {
        # Windows Terminal — nowa karta z tytułem
        Start-Process "wt" -ArgumentList "new-tab", "--title", $LXC.Name, "--", "ssh", "-J", $PROXMOX, $sshTarget
    } else {
        # Fallback — nowe okno PowerShell
        Start-Process "powershell" -ArgumentList "-NoExit", "-Command", $sshConnect
    }

    Write-Status "[SSH]  " "Otwarto terminal → $($LXC.Name) ($($LXC.IP))" "Green"
}

function Stop-Tunnels {
    if ($TunnelPIDs.Count -eq 0) { return }
    Write-Host ""
    Write-Host "  Zamykanie tuneli RDP..." -ForegroundColor DarkGray
    foreach ($pid_ in $TunnelPIDs) {
        $proc = Get-Process -Id $pid_ -ErrorAction SilentlyContinue
        if ($proc) {
            Stop-Process -Id $pid_ -Force
            Write-Status "[KILL] " "PID $pid_ zatrzymany" "DarkGray"
        }
    }
}

function Invoke-SSHKeySetup {
    $keyPath = "$env:USERPROFILE\.ssh\id_ed25519"
    Write-Header "Konfiguracja kluczy SSH"

    if (Test-Path $keyPath) {
        Write-Status "[OK]   " "Klucz SSH istnieje: $keyPath" "Green"
    } else {
        Write-Status "[GEN]  " "Generowanie klucza ed25519..." "Cyan"
        & ssh-keygen -t ed25519 -f $keyPath -N '""'
        if ($LASTEXITCODE -ne 0) {
            Write-Status "[FAIL] " "Nie udalo sie wygenerowac klucza" "Red"
            exit 1
        }
        Write-Status "[OK]   " "Klucz wygenerowany: $keyPath" "Green"
    }

    $pubKey = Get-Content "$keyPath.pub" -Raw
    $pubKey = $pubKey.Trim()

    Write-Status "[PUSH] " "Kopiowanie klucza do Proxmox (wymagane haslo)..." "Cyan"
    $deployCmd = "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '$pubKey' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && echo OK"
    $result = & ssh -o "StrictHostKeyChecking=accept-new" $PROXMOX $deployCmd

    if ($result -contains "OK") {
        Write-Status "[OK]   " "Klucz dodany do Proxmox authorized_keys" "Green"
    } else {
        Write-Status "[FAIL] " "Cos poszlo nie tak. Sprawdz polaczenie." "Red"
        exit 1
    }

    Write-Host ""
    Write-Status "[TEST] " "Test polaczenia bez hasla do Proxmox..." "Cyan"
    $test = & ssh -o "BatchMode=yes" -o "ConnectTimeout=5" $PROXMOX "echo OK" 2>&1
    if (-not ($test -contains "OK")) {
        Write-Host ""
        Write-Host "  Cos poszlo nie tak z Proxmox. Sprawdz authorized_keys." -ForegroundColor Red
        Read-Host "  Nacisnij Enter aby wyjsc" | Out-Null
        exit 1
    }
    Write-Status "[OK]   " "Proxmox - polaczenie bez hasla dziala" "Green"

    # Deploy key to each Linux host via ProxyJump
    Write-Header "Klucze SSH do hostow Linux"
    Write-Host "    Dla kazdego hosta wpisz haslo root (raz na maszyne)." -ForegroundColor DarkGray
    Write-Host ""

    foreach ($linuxHost in $LinuxSSHHosts) {
        Write-Host "    $($linuxHost.Name) ($($linuxHost.IP))..." -NoNewline -ForegroundColor DarkGray
        $lxcTarget = "$($linuxHost.User)@$($linuxHost.IP)"

        # First check if key already works
        $alreadyOk = & ssh -o "BatchMode=yes" -o "ConnectTimeout=5" -o "StrictHostKeyChecking=accept-new" `
            -J $PROXMOX $lxcTarget "echo OK" 2>&1
        if ($alreadyOk -contains "OK") {
            Write-Host " klucz juz dziala" -ForegroundColor Green
            continue
        }

        Write-Host " wymagane haslo" -ForegroundColor Yellow
        $result = & ssh -o "StrictHostKeyChecking=accept-new" -o "ConnectTimeout=10" `
            -J $PROXMOX $lxcTarget `
            "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '$pubKey' >> ~/.ssh/authorized_keys && sort -u ~/.ssh/authorized_keys -o ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && echo OK"

        if ($result -contains "OK") {
            Write-Status "[OK]   " "$($linuxHost.Name) - klucz dodany" "Green"
        } else {
            Write-Status "[SKIP] " "$($linuxHost.Name) - nie udalo sie (offline?)" "DarkGray"
        }
    }

    Write-Host ""
    Write-Host "  Gotowe! Od teraz skrypt dziala bez zadnych hasel." -ForegroundColor Green
    Write-Host ""
    Read-Host "  Nacisnij Enter aby wyjsc" | Out-Null
    exit 0
}

# ── Main ──────────────────────────────────────────────────────────────────────

Clear-Host
if ($SetupKeys) { Invoke-SSHKeySetup }
Write-Host ""
Write-Host "  ╔══════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "  ║   lab-ssh-tunnel-connect                 ║" -ForegroundColor Cyan
Write-Host "  ║   linux-windows-admin-lab • Proxmox lab  ║" -ForegroundColor Cyan
Write-Host "  ╚══════════════════════════════════════════╝" -ForegroundColor Cyan

# 1. Sprawdź Proxmox
Write-Header "Proxmox ($PROXMOX_HOST)"
Write-Host "    Ping..." -NoNewline -ForegroundColor DarkGray
if (-not (Test-ProxmoxReachable)) {
    Write-Host " FAIL" -ForegroundColor Red
    Write-Host ""
    Write-Host "  BŁĄD: Proxmox ($PROXMOX_HOST) nieosiągalny. Sprawdź sieć." -ForegroundColor Red
    exit 1
}
Write-Host " OK" -ForegroundColor Green
Initialize-HostAvailability

# 2. Windows VMs — tunele RDP
Write-Header "Windows VMs — RDP przez tunel SSH"
foreach ($vm in $WindowsVMs) {
    Write-Host "    $($vm.Name) ($($vm.IP))..." -NoNewline -ForegroundColor DarkGray
    if (Test-HostAvailable -IP $vm.IP) {
        Write-Host " dostępna" -ForegroundColor Green
        Start-RDPTunnel -VM $vm
    } else {
        Write-Host " niedostępna — pomijam" -ForegroundColor Red
    }
}

# 3. Linux hosts — okna SSH
Write-Header "Linux hosts — sesje SSH"
foreach ($lxc in $LinuxSSHHosts) {
    Write-Host "    $($lxc.Name) ($($lxc.IP))..." -NoNewline -ForegroundColor DarkGray
    if (Test-HostAvailable -IP $lxc.IP) {
        Write-Host " dostępna" -ForegroundColor Green
        Open-SSHTerminal -LXC $lxc
    } else {
        Write-Host " niedostępna — pomijam" -ForegroundColor Red
    }
}

# 4. Podsumowanie
Write-Header "Gotowe"
if ($TunnelPIDs.Count -gt 0) {
    Write-Host "    Aktywne tunele RDP (PIDs: $($TunnelPIDs -join ', '))" -ForegroundColor DarkGray
    Write-Host "    Tunele działają w tle — zamknij to okno gdy skończysz." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "    Naciśnij Enter aby zamknąć TUNELE i zakończyć." -ForegroundColor Yellow
    Write-Host "    Ctrl+C aby zostawić tunele i wyjść bez zamykania." -ForegroundColor DarkGray
    Write-Host ""
    try {
        Read-Host | Out-Null
        Stop-Tunnels
    } catch {
        # Ctrl+C — zostaw tunele
    }
} else {
    Write-Host "    Brak aktywnych tuneli RDP." -ForegroundColor DarkGray
    Write-Host ""
    Read-Host "    Naciśnij Enter aby wyjść" | Out-Null
}
