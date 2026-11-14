# Henox Tweak çekirdek fonksiyonları — hem arayüz iş parçacığında hem arka plan işlerinde çalışır.
# Bu dosya build sırasında henox.ps1 içine gömülür. Satır başında '@ kullanma.
function Send-UI($type, $data) { $sync.Queue.Enqueue([pscustomobject]@{ t = $type; d = $data }) }

function Write-HLog([string]$m, [string]$l = 'info') {
    try { Add-Content -LiteralPath $sync.LogFile -Value ("[{0}] [{1}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $l, $m) -Encoding UTF8 } catch {}
    Send-UI 'log' @{ m = $m; l = $l }
}

function Convert-HPath([string]$p) {
    if ($p -like 'HKU:\*') { return 'Registry::HKEY_USERS\' + $p.Substring(5) }
    return $p
}

function Get-HRegValue($e) {
    $p = Convert-HPath $e.path
    try { $k = Get-Item -LiteralPath $p -ErrorAction Stop } catch { return '<sil>' }
    $v = $k.GetValue($e.name, $null, 'DoNotExpandEnvironmentNames')
    if ($null -eq $v) { return '<sil>' }
    if ($v -is [byte[]]) { return (($v | ForEach-Object { $_.ToString('X2') }) -join ',') }
    return $v
}

function Set-HRegValue($e, $value) {
    $p = Convert-HPath $e.path
    if ("$value" -eq '<sil>') {
        if (Test-Path -LiteralPath $p) { Remove-ItemProperty -LiteralPath $p -Name $e.name -ErrorAction SilentlyContinue }
        return
    }
    if (-not (Test-Path -LiteralPath $p)) { New-Item -Path $p -Force | Out-Null }
    switch ($e.type) {
        'Binary' { $value = [byte[]](("$value" -split ',') | ForEach-Object { [Convert]::ToByte($_.Trim(), 16) }) }
        'DWord'  { $value = [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32][int64]$value), 0) }
        'QWord'  { $value = [int64]$value }
        default  { $value = "$value" }
    }
    New-ItemProperty -LiteralPath $p -Name $e.name -Value $value -PropertyType $e.type -Force | Out-Null
}

function Test-HRegValue($e) {
    $cur = Get-HRegValue $e
    if ("$($e.value)" -eq '<sil>') { return ("$cur" -eq '<sil>') }
    if ("$cur" -eq '<sil>') { return $false }
    switch ($e.type) {
        'DWord'  { try { return ([BitConverter]::ToUInt32([BitConverter]::GetBytes([int32]$cur), 0) -eq [uint32][int64]$e.value) } catch { return $false } }
        'Binary' { return ("$cur" -eq ("$($e.value)".ToUpper() -replace '\s', '')) }
        default  { return ("$cur" -eq "$($e.value)") }
    }
}

function Get-HServiceStart([string]$name) {
    $s = Get-Service -Name $name -ErrorAction SilentlyContinue
    if (-not $s) { return $null }
    $st = "$($s.StartType)"
    if ($st -eq 'Automatic') {
        $d = (Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$name" -Name DelayedAutostart -ErrorAction SilentlyContinue).DelayedAutostart
        if ($d -eq 1) { $st = 'AutomaticDelayedStart' }
    }
    return $st
}

function Set-HServiceStart([string]$name, [string]$mode) {
    $s = Get-Service -Name $name -ErrorAction SilentlyContinue
    if (-not $s) { Write-HLog "  servis bu sistemde yok, atlandı: $name" 'dim'; return }
    $map = @{ Automatic = 'auto'; AutomaticDelayedStart = 'delayed-auto'; Manual = 'demand'; Disabled = 'disabled' }
    $null = & sc.exe config $name start= $($map[$mode])
    if ($mode -eq 'Disabled' -and $s.Status -eq 'Running') { Stop-Service -Name $name -Force -ErrorAction SilentlyContinue }
    if ($mode -like 'Automatic*' -and $s.Status -ne 'Running') { Start-Service -Name $name -ErrorAction SilentlyContinue }
}

function Set-HTask([string]$full, [bool]$enable) {
    $i = $full.LastIndexOf('\')
    $tp = $full.Substring(0, $i + 1); $tn = $full.Substring($i + 1)
    $t = Get-ScheduledTask -TaskPath $tp -TaskName $tn -ErrorAction SilentlyContinue
    if (-not $t) { return }
    if ($enable) { $t | Enable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null } else { $t | Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null }
}

function ConvertTo-HHash($o) {
    if ($o -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}; foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = ConvertTo-HHash $p.Value }; return $h
    }
    return $o
}
function Read-HBackup {
    if (Test-Path -LiteralPath $sync.BackupFile) {
        try { return (ConvertTo-HHash (Get-Content -LiteralPath $sync.BackupFile -Raw -Encoding UTF8 | ConvertFrom-Json)) } catch {}
    }
    return @{}
}
function Save-HBackup($b) { $b | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $sync.BackupFile -Encoding UTF8 }

function Invoke-HTweak($t, [bool]$undo) {
    $b = Read-HBackup
    if (-not $undo) {
        # İlk uygulamada orijinal değerleri yedekle (tekrar uygulamada gerçek orijinal korunur)
        if (-not $b.ContainsKey($t.id)) {
            $bk = @{ reg = @{}; svc = @{}; at = (Get-Date -Format 'yyyy-MM-dd HH:mm') }
            foreach ($e in @($t.registry)) { if ($e) { $bk.reg["$($e.path)|$($e.name)"] = Get-HRegValue $e } }
            foreach ($s in @($t.services)) { if ($s) { $cur = Get-HServiceStart $s.name; if ($cur) { $bk.svc[$s.name] = $cur } } }
            $b[$t.id] = $bk; Save-HBackup $b
        }
        foreach ($e in @($t.registry)) { if ($e) { Set-HRegValue $e $e.value } }
        foreach ($s in @($t.services)) { if ($s) { Set-HServiceStart $s.name $s.startup } }
        foreach ($k in @($t.tasks))    { if ($k) { Set-HTask $k $false } }
        if ($t.script) { & ([scriptblock]::Create((@($t.script) -join "`n"))) | Out-Null }
    } else {
        $bk = $b[$t.id]
        foreach ($e in @($t.registry)) {
            if (-not $e) { continue }
            $key = "$($e.path)|$($e.name)"
            $orig = $e.original
            if ($bk -and $bk.reg -and $bk.reg.ContainsKey($key)) { $orig = $bk.reg[$key] }
            Set-HRegValue $e $orig
        }
        foreach ($s in @($t.services)) {
            if (-not $s) { continue }
            $orig = $s.original
            if ($bk -and $bk.svc -and $bk.svc.ContainsKey($s.name)) { $orig = $bk.svc[$s.name] }
            Set-HServiceStart $s.name $orig
        }
        foreach ($k in @($t.tasks)) { if ($k) { Set-HTask $k $true } }
        if ($t.undo) { & ([scriptblock]::Create((@($t.undo) -join "`n"))) | Out-Null }
        if ($b.ContainsKey($t.id)) { $b.Remove($t.id); Save-HBackup $b }
    }
}

function Test-HTweak($t) {
    if ($t.check) { try { return [bool](& ([scriptblock]::Create($t.check))) } catch { return $false } }
    $any = $false
    foreach ($e in @($t.registry)) { if ($e) { $any = $true; if (-not (Test-HRegValue $e)) { return $false } } }
    foreach ($s in @($t.services)) {
        if (-not $s) { continue }
        $cur = Get-HServiceStart $s.name
        if ($cur) { $any = $true; if ($cur -ne $s.startup) { return $false } }
    }
    return $any
}

function New-HRestorePoint {
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        $k = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
        $old = (Get-ItemProperty -Path $k -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue).SystemRestorePointCreationFrequency
        Set-ItemProperty -Path $k -Name SystemRestorePointCreationFrequency -Value 0 -Type DWord
        Write-HLog 'Geri yükleme noktası oluşturuluyor (30 sn - 2 dk sürebilir)...' 'dim'
        Checkpoint-Computer -Description ("Henox Tweak " + (Get-Date -Format 'dd.MM.yyyy HH:mm')) -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        if ($null -eq $old) { Remove-ItemProperty -Path $k -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue }
        else { Set-ItemProperty -Path $k -Name SystemRestorePointCreationFrequency -Value $old }
        Write-HLog 'Geri yükleme noktası oluşturuldu.' 'ok'
        return $true
    } catch {
        Write-HLog ("Geri yükleme noktası oluşturulamadı: " + $_.Exception.Message) 'warn'
        return $false
    }
}

function Restart-HExplorer {
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 1500
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
}

# ---- Başlangıç programları (Görev Yöneticisi ile aynı mekanizma: StartupApproved)
function Test-HStartupEnabled([string]$approved, [string]$name) {
    try { $v = (Get-Item -LiteralPath $approved -ErrorAction Stop).GetValue($name) } catch { return $true }
    if ($null -eq $v -or $v.Length -lt 1) { return $true }
    return (($v[0] % 2) -eq 0)
}
function Get-HStartup {
    $out = New-Object System.Collections.ArrayList
    $reg = @(
        @{ s = 'Bu kullanıcı';             k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run';             a = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' },
        @{ s = 'Tüm kullanıcılar';         k = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';             a = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' },
        @{ s = 'Tüm kullanıcılar (32 bit)'; k = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; a = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32' }
    )
    foreach ($r in $reg) {
        if (-not (Test-Path -LiteralPath $r.k)) { continue }
        $key = Get-Item -LiteralPath $r.k
        foreach ($n in $key.GetValueNames()) {
            if (-not $n) { continue }
            [void]$out.Add([pscustomobject]@{ Name = $n; Command = "$($key.GetValue($n))"; Scope = $r.s; Approved = $r.a; Enabled = (Test-HStartupEnabled $r.a $n) })
        }
    }
    $dirs = @(
        @{ s = 'Başlangıç klasörü';                 p = [Environment]::GetFolderPath('Startup');       a = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder' },
        @{ s = 'Başlangıç klasörü (tüm kullanıcılar)'; p = [Environment]::GetFolderPath('CommonStartup'); a = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder' }
    )
    foreach ($d in $dirs) {
        if (-not $d.p -or -not (Test-Path -LiteralPath $d.p)) { continue }
        Get-ChildItem -LiteralPath $d.p -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' } | ForEach-Object {
            [void]$out.Add([pscustomobject]@{ Name = $_.Name; Command = $_.FullName; Scope = $d.s; Approved = $d.a; Enabled = (Test-HStartupEnabled $d.a $_.Name) })
        }
    }
    return $out
}
function Set-HStartupEnabled($item, [bool]$on) {
    if (-not (Test-Path -LiteralPath $item.Approved)) { New-Item -Path $item.Approved -Force | Out-Null }
    $bytes = New-Object byte[] 12
    if ($on) { $bytes[0] = 2 } else { $bytes[0] = 3; [BitConverter]::GetBytes((Get-Date).ToFileTime()).CopyTo($bytes, 4) }
    Set-ItemProperty -LiteralPath $item.Approved -Name $item.Name -Value $bytes -Type Binary
}

# ---- Temizlik hedefleri
function Get-HCleanTargets {
    $la = $env:LOCALAPPDATA; $w = $env:windir; $pd = $env:ProgramData
    return @(
        @{ id = 'usertemp'; def = $true;  name = 'Kullanıcı geçici dosyaları';         desc = 'Programların bıraktığı geçici dosyalar (%TEMP%). Kullanımdaki dosyalar atlanır.'; paths = @($env:TEMP) },
        @{ id = 'wintemp';  def = $true;  name = 'Windows geçici dosyaları';           desc = 'C:\Windows\Temp'; paths = @("$w\Temp") },
        @{ id = 'wucache';  def = $true;  name = 'Windows Update indirme önbelleği';    desc = 'Kurulmuş güncellemelerin indirme dosyaları. Gerekirse yeniden indirilir.'; paths = @("$w\SoftwareDistribution\Download"); stop = @('wuauserv', 'bits') },
        @{ id = 'do';       def = $true;  name = 'Teslim İyileştirme önbelleği';        desc = 'Güncelleme paylaşımı için tutulan dosyalar.'; paths = @("$w\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache") },
        @{ id = 'wer';      def = $true;  name = 'Hata raporları ve çökme dökümleri';   desc = 'Eski hata raporları ve minidump dosyaları.'; paths = @("$pd\Microsoft\Windows\WER\ReportArchive", "$pd\Microsoft\Windows\WER\ReportQueue", "$la\CrashDumps", "$w\Minidump") },
        @{ id = 'thumbs';   def = $true;  name = 'Küçük resim önbelleği';               desc = 'Dosya Gezgini önizlemeleri. Klasörü açınca yeniden oluşur.'; paths = @("$la\Microsoft\Windows\Explorer"); filter = 'thumbcache_*.db' },
        @{ id = 'dxcache';  def = $false; name = 'DirectX gölgelendirici önbelleği';    desc = 'Oyunlarda bozuk grafik/takılma varsa temizle. İlk açılışta yeniden oluşur.'; paths = @("$la\D3DSCache") },
        @{ id = 'nvcache';  def = $false; name = 'NVIDIA gölgelendirici önbelleği';     desc = 'Sürücü güncellemesinden sonra takılma varsa temizle.'; paths = @("$la\NVIDIA\DXCache", "$la\NVIDIA\GLCache", "$pd\NVIDIA Corporation\NV_Cache") },
        @{ id = 'amdcache'; def = $false; name = 'AMD gölgelendirici önbelleği';        desc = 'Sürücü güncellemesinden sonra takılma varsa temizle.'; paths = @("$la\AMD\DxCache", "$la\AMD\GLCache", "$la\AMD\VkCache", "$la\AMD\DxcCache") },
        @{ id = 'recycle';  def = $false; name = 'Geri Dönüşüm Kutusu';                 desc = 'Tüm sürücülerdeki geri dönüşüm kutularını boşaltır. Geri alınamaz.'; paths = @(); special = 'recycle' }
    )
}
function Test-HSafePath([string]$p) {
    if (-not $p -or $p.Length -lt 8) { return $false }
    $full = [IO.Path]::GetFullPath($p).TrimEnd('\')
    $bad = @($env:SystemDrive, $env:windir, $env:USERPROFILE, $env:ProgramData, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA, $env:APPDATA) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }
    return ($bad -notcontains $full)
}
function Get-HTargetSize($t) {
    [int64]$sum = 0
    if ($t.special -eq 'recycle') {
        foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
            $rb = Join-Path $d.Root '$Recycle.Bin'
            if (Test-Path -LiteralPath $rb) { $s = (Get-ChildItem -LiteralPath $rb -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum; if ($s) { $sum += $s } }
        }
        return $sum
    }
    foreach ($p in $t.paths) {
        if (-not (Test-Path -LiteralPath $p -ErrorAction SilentlyContinue)) { continue }
        if ($t.filter) { $s = (Get-ChildItem -LiteralPath $p -Filter $t.filter -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum }
        else { $s = (Get-ChildItem -LiteralPath $p -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum }
        if ($s) { $sum += $s }
    }
    return $sum
}
function Clear-HTarget($t) {
    if ($t.special -eq 'recycle') { Clear-RecycleBin -Force -ErrorAction SilentlyContinue; return }
    foreach ($s in @($t.stop)) { if ($s) { Stop-Service -Name $s -Force -ErrorAction SilentlyContinue } }
    foreach ($p in $t.paths) {
        if (-not (Test-Path -LiteralPath $p -ErrorAction SilentlyContinue) -or -not (Test-HSafePath $p)) { continue }
        if ($t.filter) { Get-ChildItem -LiteralPath $p -Filter $t.filter -Force -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue }
        else { Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue } }
    }
    foreach ($s in @($t.stop)) { if ($s) { Start-Service -Name $s -ErrorAction SilentlyContinue } }
}
function Format-HSize([int64]$b) {
    if ($b -ge 1GB) { return ('{0:N2} GB' -f ($b / 1GB)) }
    if ($b -ge 1MB) { return ('{0:N0} MB' -f ($b / 1MB)) }
    if ($b -ge 1KB) { return ('{0:N0} KB' -f ($b / 1KB)) }
    return "$b B"
}

# ---- winget
function Invoke-HWinget([string[]]$wargs) {
    $last = ''
    & winget @wargs 2>&1 | ForEach-Object {
        $line = ("$_" -replace '[\u2580-\u259F\u2500-\u257F]', '').Trim()
        if ($line -and $line -notmatch '^[-\\|/]+$' -and $line -notmatch '^\d+(\.\d+)?\s*(KB|MB|GB)\s*/' -and $line -notmatch '^\d+%$' -and $line -ne $last) {
            Write-HLog ('  ' + $line) 'dim'; $last = $line
        }
    }
    return $LASTEXITCODE
}

# ---- DNS
function Set-HDns($servers) {
    $ad = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up')
    if (-not $ad) { $ad = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up') }
    if (-not $ad) { Write-HLog 'Bağlı ağ bağdaştırıcısı bulunamadı.' 'err'; return }
    foreach ($a in $ad) {
        if ($servers) { Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses $servers -ErrorAction Stop; Write-HLog ("  {0}: {1}" -f $a.Name, ($servers -join ', ')) 'ok' }
        else { Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ResetServerAddresses -ErrorAction Stop; Write-HLog ("  {0}: otomatik (internet sağlayıcın)" -f $a.Name) 'ok' }
    }
    Clear-DnsClientCache -ErrorAction SilentlyContinue
}
function Get-HDnsText {
    $ad = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up')
    $parts = foreach ($a in $ad) {
        $s = (Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
        "{0}: {1}" -f $a.Name, $(if ($s) { $s -join ', ' } else { '—' })
    }
    if ($parts) { return ($parts -join '   ·   ') } else { return 'Bağlı ağ yok' }
}
