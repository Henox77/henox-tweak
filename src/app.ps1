<#
    Henox Tweak — Türkçe, açık kaynak Windows iyileştirme aracı
    https://tweak.henox.dev  ·  https://github.com/Henox77/henox-tweak  ·  MIT Lisansı

    Bu dosya tek başına çalışır ve kaynak kodu okunabilir haldedir (gizlenmiş/şifrelenmiş kod yoktur).
    Yapılan her değişikliğin orijinal değeri yedeklenir:  %ProgramData%\HenoxTweak\backup.json
    İşlem günlükleri:                                       %ProgramData%\HenoxTweak\logs\

    Kullanım (Yönetici PowerShell / Terminal):
        irm tweak.henox.dev/run | iex

    Otomasyon (kaydedilmiş bir ayar dosyasını uygula):
        & ([scriptblock]::Create((irm tweak.henox.dev/run))) -Config C:\henox-ayarlarim.json -Run
#>
param([string]$Config, [switch]$Run)

& {
$HT_VERSION = '__VERSION__'
$HT_RUN     = 'https://tweak.henox.dev/run'

# ─────────────────────────────────────────────────────────────── Ön kontroller
function Get-RelaunchArgs {
    $extra = ''
    if ($Config) { $extra += " -Config `"$Config`"" }
    if ($Run)    { $extra += ' -Run' }
    if ($PSCommandPath) { return "-NoProfile -ExecutionPolicy Bypass -STA -File `"$PSCommandPath`"$extra" }
    if ($extra) { return "-NoProfile -ExecutionPolicy Bypass -STA -Command `"& ([scriptblock]::Create((irm $HT_RUN)))$extra`"" }
    return "-NoProfile -ExecutionPolicy Bypass -STA -Command `"irm $HT_RUN | iex`""
}
if ($PSVersionTable.PSEdition -eq 'Core' -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    Write-Host 'Henox Tweak, Windows PowerShell 5.1 ile yeniden başlatılıyor...' -ForegroundColor Cyan
    Start-Process powershell.exe -ArgumentList (Get-RelaunchArgs) -Verb RunAs
    return
}
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and $env:HENOX_DEV -ne '1') {
    Write-Host 'Henox Tweak yönetici izni gerektirir. Açılan UAC penceresinde "Evet"e bas.' -ForegroundColor Cyan
    try { Start-Process powershell.exe -ArgumentList (Get-RelaunchArgs) -Verb RunAs -ErrorAction Stop } catch { Write-Host 'Yönetici izni verilmedi, çıkılıyor.' -ForegroundColor Red }
    return
}

try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
$OutputEncoding = [Text.Encoding]::UTF8
try { $Host.UI.RawUI.WindowTitle = "Henox Tweak $HT_VERSION" } catch {}
Write-Host ''
Write-Host '  henox' -NoNewline; Write-Host '/tweak ' -ForegroundColor Blue -NoNewline; Write-Host "v$HT_VERSION  açılıyor... (bu pencereyi kapatma, uygulama da kapanır)" -ForegroundColor DarkGray
Write-Host ''

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# ─────────────────────────────────────────────────────────────── Veri
$HT = [pscustomobject]@{
    Tweaks  = ConvertFrom-Json @'
__TWEAKS_JSON__
'@
    Apps    = ConvertFrom-Json @'
__APPS_JSON__
'@
    Debloat = ConvertFrom-Json @'
__DEBLOAT_JSON__
'@
}

$DataDir = Join-Path $env:ProgramData 'HenoxTweak'
New-Item -ItemType Directory -Path (Join-Path $DataDir 'logs') -Force | Out-Null
$sync = [hashtable]::Synchronized(@{})
$sync.Queue      = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
$sync.LogFile    = Join-Path $DataDir ("logs\{0}.log" -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'))
$sync.BackupFile = Join-Path $DataDir 'backup.json'
$SettingsFile    = Join-Path $DataDir 'settings.json'

# ─────────────────────────────────────────────────────────────── Çekirdek (src/core.ps1)
$CoreCode = @'
__CORE__
'@
. ([scriptblock]::Create($CoreCode))

# ─────────────────────────────────────────────────────────────── Arka plan işleri
$S = @{ Busy = $false; Jobs = @{}; Visited = @{}; Installed = @(); Appx = @(); CleanSizes = @{}; Page = ''; Filters = @{}; AppShowSel = $false; Auto = $false }
$Handlers = @{}

function Start-HJob([string]$tag, [scriptblock]$work, $arg = $null, [switch]$Background) {
    if (-not $Background) {
        if ($S.Busy) { Toast 'Başka bir işlem sürüyor, bitmesini bekle.' 'Warn'; return }
        $S.Busy = $true; Set-BusyUI $true
    }
    $jid = [guid]::NewGuid().ToString('N')
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
    foreach ($v in 'sync', 'HT', 'CoreCode') { $rs.SessionStateProxy.SetVariable($v, (Get-Variable $v -ValueOnly)) }
    $rs.SessionStateProxy.SetVariable('JobArg', $arg)
    $rs.SessionStateProxy.SetVariable('JobBody', $work.ToString())
    $rs.SessionStateProxy.SetVariable('JobTag', $tag)
    $rs.SessionStateProxy.SetVariable('JobId', $jid)
    $rs.SessionStateProxy.SetVariable('JobBg', [bool]$Background)
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript({
        . ([scriptblock]::Create($CoreCode))
        try {
            $r = & ([scriptblock]::Create($JobBody)) $JobArg
            Send-UI 'done' @{ id = $JobId; tag = $JobTag; ok = $true; bg = $JobBg; data = $r }
        } catch {
            Write-HLog ('HATA: ' + $_.Exception.Message) 'err'
            Send-UI 'done' @{ id = $JobId; tag = $JobTag; ok = $false; bg = $JobBg; data = $null }
        }
    })
    $S.Jobs[$jid] = @{ ps = $ps; rs = $rs; h = $ps.BeginInvoke() }
}
function Complete-HJob($d) {
    $j = $S.Jobs[$d.id]
    if ($j) { try { [void]$j.ps.EndInvoke($j.h) } catch {}; $j.ps.Dispose(); $j.rs.Close(); $j.rs.Dispose(); $S.Jobs.Remove($d.id) }
    if (-not $d.bg) { $S.Busy = $false; Set-BusyUI $false }
    $res = $null
    if ($null -ne $d.data) { $arr = @($d.data); if ($arr.Count) { $res = $arr[$arr.Count - 1] } }
    if ($Handlers.ContainsKey($d.tag)) { try { & $Handlers[$d.tag] $res $d.ok } catch { Write-HLog ('Arayüz hatası: ' + $_.Exception.Message) 'err' } }
}

# ─────────────────────────────────────────────────────────────── Pencere
[xml]$xaml = @'
__XAML__
'@
$win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$W = @{}
$xaml.SelectNodes('//*[@*[local-name()="Name"]]') | ForEach-Object {
    $n = $_.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml'); if (-not $n) { $n = $_.GetAttribute('Name') }
    if ($n) { $W[$n] = $win.FindName($n) }
}

# ─────────────────────────────────────────────────────────────── Tema
$Themes = @{
    dark  = [ordered]@{ Bg = '#0E0F12'; Surface = '#15171C'; Surface2 = '#1C1F26'; Surface3 = '#262A34'; Line = '#23262F'; Line2 = '#353841'; Txt = '#EDEEF3'; Mut = '#A3A7B2'; Dim = '#6E727C'
                        Acc = '#3D6BFF'; AccSoft = '#263D6BFF'; OnAcc = '#FFFFFF'; Ok = '#4ADE80'; OkSoft = '#1F4ADE80'; Warn = '#FBBF24'; WarnSoft = '#1FFBBF24'; Err = '#F87171'; ErrSoft = '#1FF87171'
                        Info = '#7AA2FF'; InfoSoft = '#1F7AA2FF'; Hover = '#12FFFFFF'; Overlay = '#B3000000' }
    light = [ordered]@{ Bg = '#F3F4F7'; Surface = '#FFFFFF'; Surface2 = '#F4F5F8'; Surface3 = '#E4E6EB'; Line = '#E3E5EA'; Line2 = '#CDD0D7'; Txt = '#16181D'; Mut = '#4A4E58'; Dim = '#80848E'
                        Acc = '#2E5BEA'; AccSoft = '#1A2E5BEA'; OnAcc = '#FFFFFF'; Ok = '#15803D'; OkSoft = '#1A16A34A'; Warn = '#B45309'; WarnSoft = '#1AD97706'; Err = '#DC2626'; ErrSoft = '#1ADC2626'
                        Info = '#2457D6'; InfoSoft = '#142457D6'; Hover = '#0B000000'; Overlay = '#73000000' }
}
try {
    if (-not ('HenoxNative.Dwm' -as [type])) {
        Add-Type -Namespace HenoxNative -Name Dwm -MemberDefinition '[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int val, int size);' -ErrorAction Stop
    }
} catch {}
function Set-DwmAttr([int]$attr, [int]$val) {
    try { $h = (New-Object System.Windows.Interop.WindowInteropHelper($win)).Handle; if ($h -ne [IntPtr]::Zero) { [void][HenoxNative.Dwm]::DwmSetWindowAttribute($h, $attr, [ref]$val, 4) } } catch {}
}
function Read-Settings { try { if (Test-Path -LiteralPath $SettingsFile) { return (Get-Content -LiteralPath $SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json) } } catch {}; return $null }
function Save-Settings { try { @{ theme = $S.Theme } | ConvertTo-Json | Set-Content -LiteralPath $SettingsFile -Encoding UTF8 } catch {} }
function Set-Theme([string]$name, [switch]$Instant) {
    $pal = $Themes[$name]
    foreach ($k in $pal.Keys) {
        $to = [System.Windows.Media.ColorConverter]::ConvertFromString($pal[$k])
        # Kaynağa eklenen sabit fırçalar WPF tarafından dondurulur; bu yüzden her geçişte yeni fırça oluşturulur.
        # Animasyon, fırça sözlüğe eklenmeden ÖNCE başlatılır (animasyonlu fırça dondurulmaz).
        if ($Instant) { $nb = [System.Windows.Media.SolidColorBrush]::new($to) }
        else {
            $nb = [System.Windows.Media.SolidColorBrush]::new($win.Resources[$k].Color)
            $ca = [System.Windows.Media.Animation.ColorAnimation]::new($to, [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(380)))
            $ce = [System.Windows.Media.Animation.CubicEase]::new(); $ce.EasingMode = 'EaseInOut'; $ca.EasingFunction = $ce
            $nb.BeginAnimation([System.Windows.Media.SolidColorBrush]::ColorProperty, $ca)
        }
        $win.Resources[$k] = $nb.psobject.BaseObject
    }
    $S.Theme = $name
    $W.BtnTheme.Content = $(if ($name -eq 'dark') { [string][char]0xE706 } else { [string][char]0xE708 })
    Set-DwmAttr 20 $(if ($name -eq 'dark') { 1 } else { 0 })
}

# ─────────────────────────────────────────────────────────────── Yardımcılar
$BC = New-Object System.Windows.Media.BrushConverter
$Mono = $win.FindResource('Mono'); $IconFont = $win.FindResource('Icons')
$DP = @{
    TbFg = [System.Windows.Controls.TextBlock]::ForegroundProperty
    BdBg = [System.Windows.Controls.Border]::BackgroundProperty
    BdBr = [System.Windows.Controls.Border]::BorderBrushProperty
    Opacity = [System.Windows.UIElement]::OpacityProperty
    TY = [System.Windows.Media.TranslateTransform]::YProperty
    TX = [System.Windows.Media.TranslateTransform]::XProperty
    Width = [System.Windows.FrameworkElement]::WidthProperty
    Height = [System.Windows.FrameworkElement]::HeightProperty
}
function Br([string]$hex) { return $BC.ConvertFromString($hex) }
function New-Text([string]$text, [double]$size = 13, [string]$key = 'Txt', [string]$weight = 'Normal', [switch]$Wrap) {
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $text; $t.FontSize = $size; $t.FontWeight = $weight
    $t.SetResourceReference($DP.TbFg, $key)
    if ($Wrap) { $t.TextWrapping = 'Wrap' }
    return $t
}
function New-Icon([int]$code, [double]$size = 14, [string]$key = 'Mut') {
    $t = New-Text ([string][char]$code) $size $key; $t.FontFamily = $IconFont; $t.VerticalAlignment = 'Center'
    return $t
}
function New-Card([string]$bg = 'Surface') {
    $b = New-Object System.Windows.Controls.Border
    $b.SetResourceReference($DP.BdBg, $bg); $b.SetResourceReference($DP.BdBr, 'Line')
    $b.BorderThickness = 1; $b.CornerRadius = 10
    return $b
}
function New-Badge([string]$text, [string]$kind = 'Info') {
    $b = New-Object System.Windows.Controls.Border
    $b.CornerRadius = 4; $b.Padding = '6,1,6,2'; $b.Margin = '8,0,0,0'; $b.VerticalAlignment = 'Center'
    if ($kind -eq 'Dim') { $b.SetResourceReference($DP.BdBg, 'Surface3') } else { $b.SetResourceReference($DP.BdBg, "${kind}Soft") }
    $t = New-Text $text 10 $kind 'SemiBold'
    $b.Child = $t
    return $b
}
function New-Section([string]$title, [string]$desc) {
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Margin = '2,20,0,10'
    $h = New-Text ($title.ToUpper([Globalization.CultureInfo]'tr-TR')) 11.5 'Acc' 'Bold'; $h.FontFamily = $Mono
    $sp.Children.Add($h) | Out-Null
    if ($desc) { $d = New-Text $desc 12 'Dim'; $d.Margin = '0,3,0,0'; $d.TextWrapping = 'Wrap'; $sp.Children.Add($d) | Out-Null }
    return $sp
}
function New-Ease { $e = New-Object System.Windows.Media.Animation.CubicEase; $e.EasingMode = 'EaseOut'; return $e }
function Anim($target, $dp, [double]$to, [int]$ms = 220, $from = $null, [int]$delay = 0) {
    $a = New-Object System.Windows.Media.Animation.DoubleAnimation
    $a.To = $to; if ($null -ne $from) { $a.From = [double]$from }
    $a.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds($ms))
    if ($delay) { $a.BeginTime = [TimeSpan]::FromMilliseconds($delay) }
    $a.EasingFunction = New-Ease
    $target.BeginAnimation($dp, $a)
}
function Reveal($el, [int]$i = 0) {
    # Listelerdeki öğeler sırayla, aşağıdan yukarı süzülerek görünür
    $d = [math]::Min($i * 16, 360)
    $el.Opacity = 0
    $tt = New-Object System.Windows.Media.TranslateTransform 0, 8
    $el.RenderTransform = $tt
    Anim $el $DP.Opacity 1 260 0 $d
    Anim $tt $DP.TY 0 340 8 $d
}
function Set-Status([string]$t, [string]$kind = 'Ok') { $W.StatusText.Text = $t; $W.StatusDot.SetResourceReference([System.Windows.Shapes.Shape]::FillProperty, $kind) }
function Open-Url([string]$u) { try { Start-Process $u } catch {} }
function Add-LogLine([string]$m, [string]$l = 'info') {
    $map = @{ info = 'Mut'; ok = 'Ok'; warn = 'Warn'; err = 'Err'; dim = 'Dim'; head = 'Txt' }
    $p = New-Object System.Windows.Documents.Paragraph
    $p.Margin = '0'; $p.LineHeight = 19
    $r1 = New-Object System.Windows.Documents.Run ((Get-Date -Format 'HH:mm:ss') + '  '); $r1.SetResourceReference([System.Windows.Documents.TextElement]::ForegroundProperty, 'Dim')
    $r2 = New-Object System.Windows.Documents.Run $m; $key = $map[$l]; if (-not $key) { $key = 'Mut' }
    $r2.SetResourceReference([System.Windows.Documents.TextElement]::ForegroundProperty, $key)
    if ($l -eq 'head') { $r2.FontWeight = 'SemiBold' }
    $p.Inlines.Add($r1); $p.Inlines.Add($r2)
    $blocks = $W.LogBox.Document.Blocks
    $blocks.Add($p)
    while ($blocks.Count -gt 800) { [void]$blocks.Remove($blocks.FirstBlock) }
    $W.LogBox.ScrollToEnd()
    if ($l -eq 'err') { Set-Status $m 'Err' }
}

# ---- İlerleme çubuğu (belirli / belirsiz, animasyonlu)
function Set-Progress($pct) {
    $W.ProgTrack.Opacity = 1
    $tt = $W.ProgFill.RenderTransform
    if ($null -eq $pct) {
        $W.ProgFill.BeginAnimation($DP.Width, $null); $W.ProgFill.Width = 66
        $a = New-Object System.Windows.Media.Animation.DoubleAnimation -66, 220, (New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(1100)))
        $a.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
        $a.EasingFunction = (New-Object System.Windows.Media.Animation.SineEase)
        $tt.BeginAnimation($DP.TX, $a)
    } else {
        $tt.BeginAnimation($DP.TX, $null); $tt.X = 0
        Anim $W.ProgFill $DP.Width ([math]::Max(4, 220 * [double]$pct / 100)) 300
    }
}
function Hide-Progress { $W.ProgFill.RenderTransform.BeginAnimation($DP.TX, $null); Anim $W.ProgTrack $DP.Opacity 0 300; $W.ProgFill.BeginAnimation($DP.Width, $null); $W.ProgFill.Width = 0 }

# ---- Bildirim balonları
function Toast([string]$msg, [string]$kind = 'Ok', [string]$actionText = '', [string]$actionId = '') {
    $icons = @{ Ok = 0xE73E; Warn = 0xE7BA; Err = 0xE783; Info = 0xE946 }
    $b = New-Card 'Surface2'; $b.SetResourceReference($DP.BdBr, 'Line2'); $b.Padding = '14,12'; $b.Margin = '0,0,0,10'
    $fx = New-Object System.Windows.Media.Effects.DropShadowEffect; $fx.BlurRadius = 24; $fx.ShadowDepth = 6; $fx.Opacity = 0.3; $b.Effect = $fx
    $g = New-Object System.Windows.Controls.Grid
    foreach ($wd in 'Auto', '*', 'Auto') { $cd = New-Object System.Windows.Controls.ColumnDefinition; $cd.Width = $wd; $g.ColumnDefinitions.Add($cd) }
    $ib = New-Object System.Windows.Controls.Border; $ib.Width = 26; $ib.Height = 26; $ib.CornerRadius = 7; $ib.SetResourceReference($DP.BdBg, "${kind}Soft"); $ib.Margin = '0,0,12,0'; $ib.VerticalAlignment = 'Top'
    $ic = New-Icon $icons[$kind] 12.5 $kind; $ic.HorizontalAlignment = 'Center'; $ib.Child = $ic
    $tx = New-Text $msg 12.5 'Txt' -Wrap; $tx.VerticalAlignment = 'Center'; $tx.LineHeight = 18
    [System.Windows.Controls.Grid]::SetColumn($tx, 1)
    $g.Children.Add($ib) | Out-Null; $g.Children.Add($tx) | Out-Null
    if ($actionText) {
        $ab = New-Object System.Windows.Controls.Button; $ab.Style = $win.FindResource('Btn'); $ab.Content = $actionText; $ab.Padding = '10,4'; $ab.Margin = '10,0,0,0'; $ab.Tag = $actionId; $ab.VerticalAlignment = 'Center'
        $ab.Add_Click({ Invoke-ToastAction $this.Tag })
        [System.Windows.Controls.Grid]::SetColumn($ab, 2); $g.Children.Add($ab) | Out-Null
    }
    $b.Child = $g
    $tt = New-Object System.Windows.Media.TranslateTransform 40, 0; $b.RenderTransform = $tt; $b.Opacity = 0
    $W.ToastHost.Children.Insert(0, $b)
    Anim $b $DP.Opacity 1 220 0; Anim $tt $DP.TX 0 320 40
    while ($W.ToastHost.Children.Count -gt 4) { $W.ToastHost.Children.RemoveAt($W.ToastHost.Children.Count - 1) }
    $t = New-Object System.Windows.Threading.DispatcherTimer; $t.Interval = [TimeSpan]::FromMilliseconds($(if ($actionText) { 7000 } else { 4200 })); $t.Tag = @{ b = $b; step = 0 }
    $t.Add_Tick({
        $st = $this.Tag
        if ($st.step -eq 0) { $st.step = 1; Anim $st.b $DP.Opacity 0 250; Anim $st.b.RenderTransform $DP.TX 40 250; $this.Interval = [TimeSpan]::FromMilliseconds(280) }
        else { $this.Stop(); $W.ToastHost.Children.Remove($st.b) }
    })
    $t.Start()
}
function Invoke-ToastAction([string]$id) {
    switch ($id) {
        'explorer' { Restart-HExplorer; Toast 'Dosya Gezgini yeniden başlatıldı.' 'Ok' }
        'log'      { if ($W.LogDrawer.Height -lt 10) { Toggle-Log } }
    }
}

# ---- Pencere içi diyalog (modal, animasyonlu)
function Show-Dialog([string]$title, [string]$text, [string[]]$buttons, [string]$kind = 'Info', [int]$primary = 0) {
    $icons = @{ Info = 0xE946; Warn = 0xE7BA; Err = 0xE783; Ok = 0xE73E; Question = 0xE9CE }
    $acc = @{ Info = 'Acc'; Warn = 'Warn'; Err = 'Err'; Ok = 'Ok'; Question = 'Acc' }
    $soft = @{ Info = 'AccSoft'; Warn = 'WarnSoft'; Err = 'ErrSoft'; Ok = 'OkSoft'; Question = 'AccSoft' }
    $W.DlgTitle.Text = $title; $W.DlgText.Text = $text
    $W.DlgIcon.Text = [string][char]$icons[$kind]; $W.DlgIcon.SetResourceReference($DP.TbFg, $acc[$kind]); $W.DlgIconBg.SetResourceReference($DP.BdBg, $soft[$kind])
    $W.DlgButtons.Children.Clear()
    for ($i = 0; $i -lt $buttons.Count; $i++) {
        $b = New-Object System.Windows.Controls.Button
        $b.Style = $win.FindResource($(if ($i -eq $primary) { 'BtnPri' } else { 'Btn' }))
        $b.Content = $buttons[$i]; $b.Tag = $i; $b.Margin = '8,0,0,0'; $b.MinWidth = 96
        $b.Add_Click({ $S.DlgResult = [int]$this.Tag; $S.DlgFrame.Continue = $false })
        $W.DlgButtons.Children.Add($b) | Out-Null
    }
    $S.DlgResult = -1; $S.DlgPrimary = $primary; $S.DlgCancel = $(if ($buttons.Count -gt 1) { 0 } else { $primary })
    $W.DialogHost.Visibility = 'Visible'
    Anim $W.DlgDim $DP.Opacity 1 200 0
    Anim $W.DlgCard $DP.Opacity 1 200 0
    Anim $W.DlgCard.RenderTransform ([System.Windows.Media.ScaleTransform]::ScaleXProperty) 1 260 0.94
    Anim $W.DlgCard.RenderTransform ([System.Windows.Media.ScaleTransform]::ScaleYProperty) 1 260 0.94
    $W.DlgButtons.Children[$primary].Focus() | Out-Null
    $S.DlgFrame = New-Object System.Windows.Threading.DispatcherFrame
    [System.Windows.Threading.Dispatcher]::PushFrame($S.DlgFrame)
    $W.DialogHost.Visibility = 'Collapsed'
    return $S.DlgResult
}
function Ask([string]$text, [string]$title = 'Onay', [string]$kind = 'Question', [string]$yes = 'Devam et', [string]$no = 'Vazgeç') {
    if ($S.Auto) { return $true }
    return ((Show-Dialog $title $text @($no, $yes) $kind 1) -eq 1)
}
function Info([string]$text, [string]$title = 'Bilgi', [string]$kind = 'Info') {
    if ($S.Auto) { Toast $text $kind; return }
    [void](Show-Dialog $title $text @('Tamam') $kind 0)
}

$S.ActionButtons = @('BtnTwApply', 'BtnTwUndo', 'BtnAppInstall', 'BtnAppUninstall', 'BtnAppUpgrade', 'BtnDbRemove', 'BtnClRun', 'BtnClScan', 'BtnUndoAll', 'BtnQuickRestore', 'BtnTwImport')
$S.RepairButtons = @(); $S.DnsButtons = @()
function Set-BusyUI([bool]$on) {
    foreach ($n in $S.ActionButtons) { if ($W[$n]) { $W[$n].IsEnabled = -not $on } }
    foreach ($b in @($S.RepairButtons + $S.DnsButtons)) { $b.IsEnabled = -not $on }
    if ($on) { Set-Progress $null; Set-Status 'Çalışıyor...' 'Warn' } else { Hide-Progress }
}
function Toggle-Log {
    $open = $W.LogDrawer.Height -lt 10
    Anim $W.LogDrawer $DP.Height $(if ($open) { 190 } else { 0 }) 280
    $W.LogChevron.Text = $(if ($open) { [string][char]0xE70D } else { [string][char]0xE70E })
}

$W.LogBox.Document = New-Object System.Windows.Documents.FlowDocument
$W.LogBox.Document.PagePadding = '0'
$W.TxtVer.Text = "v$HT_VERSION"
$W.TxtAboutVer.Text = "Sürüm $HT_VERSION  ·  PowerShell $($PSVersionTable.PSVersion)  ·  Windows $([Environment]::OSVersion.Version)"

# ─────────────────────────────────────────────────────────────── Sekmeler
$Tw = @($HT.Tweaks.tweaks); $Ap = @($HT.Apps.apps)
$PageDefs = @(
    @{ id = 'Panel';   t = 'Panel' },
    @{ id = 'Apps';    t = 'Uygulamalar' },
    @{ id = 'Tweaks';  t = 'Tweakler' },
    @{ id = 'Debloat'; t = 'Debloat' },
    @{ id = 'Startup'; t = 'Başlangıç' },
    @{ id = 'Clean';   t = 'Temizlik' },
    @{ id = 'Repair';  t = 'Onarım' }
)
$S.Tabs = @{}
foreach ($pd in $PageDefs) {
    $rb = New-Object System.Windows.Controls.RadioButton
    $rb.Style = $win.FindResource('Tab'); $rb.GroupName = 'tabs'; $rb.Tag = $pd.id; $rb.Content = $pd.t
    $rb.Add_Checked({ Show-Page $this.Tag })
    $W.TabPanel.Children.Add($rb) | Out-Null
    $S.Tabs[$pd.id] = $rb
}
function Show-Page([string]$id) {
    if ($S.Page -eq $id) { return }
    foreach ($n in @($PageDefs | ForEach-Object { $_.id }) + 'About') { if ($n -ne $id) { $W["Page$n"].Visibility = 'Collapsed' } }
    $pg = $W["Page$id"]; $pg.Visibility = 'Visible'
    $tt = New-Object System.Windows.Media.TranslateTransform 0, 12; $pg.RenderTransform = $tt
    Anim $pg $DP.Opacity 1 240 0; Anim $tt $DP.TY 0 340 12
    $S.Page = $id
    if ($S.Tabs[$id] -and -not $S.Tabs[$id].IsChecked) { $S.Tabs[$id].IsChecked = $true }
    if ($id -eq 'About') { foreach ($t in $S.Tabs.Values) { $t.IsChecked = $false } }
    $W.GlobalSearch.Text = ''
    $W.GlobalSearch.IsEnabled = $S.Filters.ContainsKey($id)
    if (-not $S.Visited[$id]) {
        $S.Visited[$id] = $true
        switch ($id) {
            'Apps'    { Start-WingetScan }
            'Debloat' { Start-AppxScan }
            'Startup' { Build-StartupList }
            'Clean'   { Start-CleanScan }
            'Tweaks'  { Update-DnsText }
        }
    }
    if ($id -eq 'About') { Update-BackupInfo }
}
$W.GlobalSearch.Add_TextChanged({
    $f = $S.Filters[$S.Page]
    if ($f) { & $f ($W.GlobalSearch.Text.Trim().ToLower([Globalization.CultureInfo]'tr-TR')) }
})
function Test-Match([string]$key, [string]$q) { return (-not $q) -or $key.Contains($q) }

# ─────────────────────────────────────────────────────────────── Panel (genel bakış)
$JobOverview = {
    $os = Get-CimInstance Win32_OperatingSystem
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $gpus = @(Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch 'Basic|Remote|Virtual|Parsec|Meta|Mirage' } | ForEach-Object { $_.Name.Trim() })
    $cs = Get-CimInstance Win32_ComputerSystem
    $bb = Get-CimInstance Win32_BaseBoard
    $mem = @(Get-CimInstance Win32_PhysicalMemory)
    $sysd = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'"
    $pdisk = @(Get-PhysicalDisk -ErrorAction SilentlyContinue | ForEach-Object { "{0} ({1}, {2} GB)" -f $_.FriendlyName.Trim(), $_.MediaType, [math]::Round($_.Size / 1GB) })
    $plan = [regex]::Match((powercfg /getactivescheme | Out-String), '\((.+)\)').Groups[1].Value
    $up = (Get-Date) - $os.LastBootUpTime
    $stOn = @(Get-HStartup | Where-Object { $_.Enabled }).Count
    $tot = [double]$cs.TotalPhysicalMemory
    $totGB = [math]::Round($tot / 1GB, 1)
    $usedPct = [int][math]::Round((1 - ($os.FreePhysicalMemory * 1KB) / $tot) * 100)
    $spd = ($mem | Measure-Object -Property ConfiguredClockSpeed -Maximum).Maximum
    $dFree = [math]::Round($sysd.FreeSpace / 1GB); $dTot = [math]::Round($sysd.Size / 1GB)
    $dPct = [int][math]::Round((1 - $sysd.FreeSpace / $sysd.Size) * 100)
    $laptop = @(@((Get-CimInstance Win32_SystemEnclosure).ChassisTypes) | Where-Object { $_ -in 8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32 }).Count -gt 0
    $osName = ($os.Caption -replace 'Microsoft ', '')

    $recs = @()
    if ($up.TotalDays -ge 3) { $recs += @{ l = 'Warn'; t = ("Bilgisayar {0} gündür yeniden başlatılmamış" -f [int]$up.TotalDays); d = 'Uzun süre açık kalan Windows; bellek sızıntıları ve takılan servisler yüzünden yavaşlar. Yeniden başlatmak en etkili tek adımdır. Hızlı başlatma açıksa "Kapat" bunu sıfırlamaz (Tweakler > Performans > Hızlı başlatmayı kapat).' } }
    if ($usedPct -ge 85) { $recs += @{ l = 'Err'; t = "RAM'in %$usedPct'i dolu"; d = 'Bellek dolunca Windows diske taşar ve her şey yavaşlar. Başlangıç sekmesinden gereksiz programları kapat, tarayıcı sekmelerini azalt.' } }
    if ($totGB -lt 12) { $recs += @{ l = 'Info'; t = "$totGB GB RAM günümüz için az"; d = 'Tarayıcı + Discord + oyun aynı anda 8 GB''ı rahatça aşar. Kalıcı çözüm 16 GB''a yükseltmek; hiçbir tweak eksik RAM''i telafi edemez.' } }
    if ($dPct -ge 85) { $recs += @{ l = 'Warn'; t = "$env:SystemDrive diski %$dPct dolu ($dFree GB boş)"; d = 'SSD doldukça yavaşlar, Windows güncellemeleri de yer ister. Temizlik sekmesini kullan; büyük klasörleri bulmak için Uygulamalar''dan WizTree''yi kur.' } }
    if ($stOn -gt 8) { $recs += @{ l = 'Warn'; t = "Açılışta $stOn program başlıyor"; d = 'Her biri açılışı uzatır ve arka planda RAM yer. Başlangıç sekmesinden ihtiyacın olmayanları kapat.' } }
    if ($plan -match 'saver|tasarruf') { $recs += @{ l = 'Warn'; t = 'Güç tasarrufu planı açık'; d = 'İşlemci bilerek yavaşlatılıyor. Prizdeysen Dengeli veya Yüksek Performans planına geç.' } }
    if ($recs.Count -eq 0) { $recs += @{ l = 'Ok'; t = 'Belirgin bir sorun görünmüyor'; d = 'Yine de Tweakler sekmesindeki "Önerilen" seçim gereksiz arka plan yükünü azaltır.' } }

    return @{
        meters = @(
            @{ k = 'Bellek (RAM)'; v = "%$usedPct"; s = "$totGB GB" + $(if ($spd) { "  ·  $spd MT/s" } else { '' }); p = $usedPct },
            @{ k = "Sistem diski ($env:SystemDrive)"; v = "%$dPct"; s = "$dFree GB boş / $dTot GB"; p = $dPct },
            @{ k = 'Açık kalma süresi'; v = ("{0} gün {1} sa" -f [int][math]::Floor($up.TotalDays), $up.Hours); s = "Açılışta başlayan: $stOn program"; p = [math]::Min(100, [int]($up.TotalDays / 7 * 100)) }
        )
        cards = @(
            @{ k = 'İşletim sistemi'; v = $osName; s = "$($cv.DisplayVersion)  ·  derleme $($cv.CurrentBuild).$($cv.UBR)" },
            @{ k = 'İşlemci'; v = ($cpu.Name -replace '\s+', ' ').Trim(); s = "$($cpu.NumberOfCores) çekirdek / $($cpu.NumberOfLogicalProcessors) iş parçacığı" },
            @{ k = 'Ekran kartı'; v = $(if ($gpus) { $gpus -join "`n" } else { '—' }); s = '' },
            @{ k = 'Depolama'; v = ($pdisk -join "`n"); s = '' },
            @{ k = 'Güç planı'; v = $plan; s = $(if ($laptop) { 'Dizüstü bilgisayar' } else { 'Masaüstü bilgisayar' }) },
            @{ k = 'Anakart'; v = ("{0} {1}" -f $bb.Manufacturer, $bb.Product).Trim(); s = $cs.Model }
        )
        recs = $recs
    }
}
$Handlers['overview'] = {
    param($r, $ok)
    if (-not $r) { return }
    $W.OvMeters.Children.Clear(); $i = 0
    foreach ($m in $r.meters) {
        $b = New-Card; $b.Width = 300; $b.Margin = '0,0,12,12'; $b.Padding = '18,15'
        $sp = New-Object System.Windows.Controls.StackPanel
        $k = New-Text ($m.k.ToUpper([Globalization.CultureInfo]'tr-TR')) 10.5 'Dim' 'SemiBold'; $k.FontFamily = $Mono
        $v = New-Text $m.v 26 'Txt' 'Bold'; $v.Margin = '0,4,0,0'
        $track = New-Object System.Windows.Controls.Border; $track.Height = 6; $track.CornerRadius = 3; $track.SetResourceReference($DP.BdBg, 'Surface3'); $track.Margin = '0,10,0,8'
        $fill = New-Object System.Windows.Controls.Border; $fill.CornerRadius = 3; $fill.HorizontalAlignment = 'Left'; $fill.Width = 0
        $fill.SetResourceReference($DP.BdBg, $(if ($m.p -ge 85) { 'Err' } elseif ($m.p -ge 70) { 'Warn' } else { 'Acc' }))
        $track.Child = $fill
        $s = New-Text $m.s 12 'Dim'
        foreach ($x in $k, $v, $track, $s) { $sp.Children.Add($x) | Out-Null }
        $b.Child = $sp; $W.OvMeters.Children.Add($b) | Out-Null
        Reveal $b $i
        Anim $fill $DP.Width ([math]::Max(4, 262 * $m.p / 100)) 900 0 (150 + $i * 120)
        $i++
    }
    $W.OvCards.Children.Clear()
    foreach ($cd in $r.cards) {
        $b = New-Card; $b.Width = 300; $b.Margin = '0,0,12,12'; $b.Padding = '18,14'; $b.MinHeight = 84
        $sp = New-Object System.Windows.Controls.StackPanel
        $k = New-Text ($cd.k.ToUpper([Globalization.CultureInfo]'tr-TR')) 10.5 'Dim' 'SemiBold'; $k.FontFamily = $Mono
        $v = New-Text $cd.v 13.5 'Txt' 'SemiBold' -Wrap; $v.Margin = '0,6,0,0'
        $sp.Children.Add($k) | Out-Null; $sp.Children.Add($v) | Out-Null
        if ($cd.s) { $sub = New-Text $cd.s 12 'Dim' -Wrap; $sub.Margin = '0,3,0,0'; $sp.Children.Add($sub) | Out-Null }
        $b.Child = $sp; $W.OvCards.Children.Add($b) | Out-Null
        Reveal $b $i; $i++
    }
    $W.OvRecs.Children.Clear()
    foreach ($x in $r.recs) {
        $b = New-Card; $b.Margin = '0,0,0,8'; $b.Padding = '16,13'; $b.Width = 936; $b.HorizontalAlignment = 'Left'
        $g = New-Object System.Windows.Controls.Grid
        foreach ($wd in 'Auto', '*') { $cdf = New-Object System.Windows.Controls.ColumnDefinition; $cdf.Width = $wd; $g.ColumnDefinitions.Add($cdf) }
        $bar = New-Object System.Windows.Controls.Border; $bar.Width = 3; $bar.CornerRadius = 2; $bar.SetResourceReference($DP.BdBg, $x.l); $bar.Margin = '0,0,14,0'
        $sp = New-Object System.Windows.Controls.StackPanel
        $sp.Children.Add((New-Text $x.t 13.5 'Txt' 'SemiBold')) | Out-Null
        $d = New-Text $x.d 12.5 'Mut' -Wrap; $d.Margin = '0,3,0,0'; $d.LineHeight = 19; $sp.Children.Add($d) | Out-Null
        [System.Windows.Controls.Grid]::SetColumn($sp, 1)
        $g.Children.Add($bar) | Out-Null; $g.Children.Add($sp) | Out-Null
        $b.Child = $g; $W.OvRecs.Children.Add($b) | Out-Null
        Reveal $b $i; $i++
    }
    Set-Status 'Sistem taraması tamamlandı.'
}
function Start-Overview { Set-Status 'Sistem taranıyor...' 'Warn'; Start-HJob 'overview' $JobOverview -Background }
$h = (Get-Date).Hour
$W.OvHello.Text = ("{0}, {1}" -f $(if ($h -ge 5 -and $h -lt 12) { 'Günaydın' } elseif ($h -lt 18 -and $h -ge 12) { 'İyi günler' } elseif ($h -ge 18 -and $h -lt 23) { 'İyi akşamlar' } else { 'İyi geceler' }), $env:USERNAME)

# ─────────────────────────────────────────────────────────────── Tweakler
$S.TwRows = [ordered]@{}; $S.PrefRows = [ordered]@{}
$RestartText = @{ explorer = 'Dosya Gezgini yenilenince etkinleşir'; oturum = 'Oturumu kapatıp açınca etkinleşir'; pc = 'Bilgisayar yeniden başlayınca etkinleşir' }
function New-TweakTip($t) {
    $sp = New-Object System.Windows.Controls.StackPanel; $sp.MaxWidth = 390
    $sp.Children.Add((New-Text $t.name 13.5 'Txt' 'Bold' -Wrap)) | Out-Null
    $d = New-Text $t.desc 12.5 'Mut' -Wrap; $d.Margin = '0,5,0,0'; $d.LineHeight = 18; $sp.Children.Add($d) | Out-Null
    $meta = @()
    if ($t.risk -eq 'orta') { $meta += 'Orta risk: açıklamayı dikkatle oku.' }
    if ($RestartText[$t.restart]) { $meta += $RestartText[$t.restart] + '.' }
    if ($meta) { $m = New-Text ($meta -join '  ') 12 'Warn' -Wrap; $m.Margin = '0,6,0,0'; $sp.Children.Add($m) | Out-Null }
    $l = New-Object System.Collections.ArrayList
    foreach ($e in @($t.registry)) { if ($e) { [void]$l.Add(("{0}\{1} = {2}" -f ($e.path -replace '^HK(LM|CU|U):\\', 'HK$1\'), $e.name, $e.value)) } }
    foreach ($s in @($t.services)) { if ($s) { [void]$l.Add(("Servis {0} → {1}" -f $s.name, $s.startup)) } }
    foreach ($k in @($t.tasks)) { if ($k) { [void]$l.Add(("Görev kapat: {0}" -f ($k -split '\\')[-1])) } }
    foreach ($x in @($t.script)) { if ($x) { [void]$l.Add("PS> $x") } }
    if ($l.Count) { $c = New-Text ($l -join "`n") 11 'Dim' -Wrap; $c.FontFamily = $Mono; $c.Margin = '0,8,0,0'; $sp.Children.Add($c) | Out-Null }
    return $sp
}
function Build-TweakList {
    $W.TweakList.Children.Clear(); $S.TwRows.Clear(); $i = 0
    foreach ($cat in @($HT.Tweaks.categories | Where-Object { $_.id -ne 'arayuz' })) {
        $items = @($Tw | Where-Object { $_.cat -eq $cat.id })
        if (-not $items) { continue }
        $hdr = New-Section $cat.name $cat.desc
        $card = New-Card; $card.Padding = '6,6'
        $wrap = New-Object System.Windows.Controls.WrapPanel
        $card.Child = $wrap
        $W.TweakList.Children.Add($hdr) | Out-Null; $W.TweakList.Children.Add($card) | Out-Null
        foreach ($t in $items) {
            $row = New-Object System.Windows.Controls.Border
            $row.Width = 404; $row.Padding = '10,8'; $row.CornerRadius = 7; $row.Background = [System.Windows.Media.Brushes]::Transparent
            $row.Add_MouseEnter({ $this.SetResourceReference($DP.BdBg, 'Hover') })
            $row.Add_MouseLeave({ $this.Background = [System.Windows.Media.Brushes]::Transparent })
            $g = New-Object System.Windows.Controls.Grid
            foreach ($wd in '*', 'Auto') { $cd = New-Object System.Windows.Controls.ColumnDefinition; $cd.Width = $wd; $g.ColumnDefinitions.Add($cd) }
            $cb = New-Object System.Windows.Controls.CheckBox; $cb.Style = $win.FindResource('Chk'); $cb.Tag = $t.id
            $line = New-Object System.Windows.Controls.WrapPanel
            $line.Children.Add((New-Text $t.name 13 'Txt')) | Out-Null
            if ($t.risk -eq 'orta') { $line.Children.Add((New-Badge 'ORTA RİSK' 'Warn')) | Out-Null }
            if ($t.restart -eq 'pc') { $line.Children.Add((New-Badge 'YENİDEN BAŞLAT' 'Dim')) | Out-Null }
            $q = New-Icon 0xE9CE 11 'Dim'; $q.Margin = '7,1,0,0'; $line.Children.Add($q) | Out-Null
            $cb.Content = $line
            $cb.ToolTip = New-TweakTip $t
            [System.Windows.Controls.ToolTipService]::SetShowDuration($cb, 60000); [System.Windows.Controls.ToolTipService]::SetInitialShowDelay($cb, 350)
            $cb.Add_Click({ Update-TwCount })
            $st = New-Object System.Windows.Shapes.Ellipse; $st.Width = 7; $st.Height = 7; $st.VerticalAlignment = 'Center'; $st.Margin = '10,0,2,0'
            [System.Windows.Controls.Grid]::SetColumn($st, 1)
            $g.Children.Add($cb) | Out-Null; $g.Children.Add($st) | Out-Null
            $row.Child = $g
            $wrap.Children.Add($row) | Out-Null
            $S.TwRows[$t.id] = @{ t = $t; cb = $cb; st = $st; row = $row; hdr = $hdr; card = $card; key = ("$($t.name) $($t.desc) $($cat.name)").ToLower([Globalization.CultureInfo]'tr-TR') }
            $i++
        }
    }
    # Sağ sütun: Tercihler (anında uygulanan anahtarlar)
    $W.PrefList.Children.Clear(); $S.PrefRows.Clear()
    foreach ($t in @($Tw | Where-Object { $_.cat -eq 'arayuz' })) {
        $sw = New-Object System.Windows.Controls.CheckBox; $sw.Style = $win.FindResource('Sw'); $sw.Tag = $t.id; $sw.Margin = '0,0,0,14'
        $sp = New-Object System.Windows.Controls.StackPanel
        $sp.Children.Add((New-Text $t.name 13 'Txt' 'SemiBold' -Wrap)) | Out-Null
        $d = New-Text $t.desc 11.5 'Dim' -Wrap; $d.Margin = '0,2,0,0'; $d.LineHeight = 16; $sp.Children.Add($d) | Out-Null
        $sw.Content = $sp
        $sw.Add_Click({ Invoke-Pref $this })
        $W.PrefList.Children.Add($sw) | Out-Null
        $S.PrefRows[$t.id] = @{ t = $t; sw = $sw; key = ("$($t.name) $($t.desc)").ToLower([Globalization.CultureInfo]'tr-TR') }
    }
}
function Update-TweakStatus {
    $applied = 0
    foreach ($r in $S.TwRows.Values) {
        $on = $false; try { $on = Test-HTweak $r.t } catch {}
        $r.applied = $on
        $r.st.SetResourceReference([System.Windows.Shapes.Shape]::FillProperty, $(if ($on) { 'Ok' } else { 'Surface3' }))
        $r.st.ToolTip = $(if ($on) { 'Bu bilgisayarda uygulanmış' } else { 'Uygulanmamış' })
        if ($on) { $applied++ }
    }
    foreach ($p in $S.PrefRows.Values) { $on = $false; try { $on = Test-HTweak $p.t } catch {}; $p.sw.IsChecked = $on }
    $S.TwApplied = $applied
    Update-TwCount
}
function Update-TwCount {
    $sel = @($S.TwRows.Values | Where-Object { $_.cb.IsChecked }).Count
    $W.TxtTwCount.Text = "$sel seçili  ·  $($S.TwApplied) / $($S.TwRows.Count) uygulanmış"
}
function Select-Tweaks([scriptblock]$pred) { foreach ($r in $S.TwRows.Values) { $r.cb.IsChecked = [bool](& $pred $r) }; Update-TwCount }
function Get-SelectedTweakIds { return @($S.TwRows.Values | Where-Object { $_.cb.IsChecked } | ForEach-Object { $_.t.id }) }
$S.Filters['Tweaks'] = {
    param($q)
    $vis = @{}
    foreach ($r in $S.TwRows.Values) {
        $show = Test-Match $r.key $q
        $r.row.Visibility = $(if ($show) { 'Visible' } else { 'Collapsed' })
        if ($show) { $vis[$r.card.GetHashCode()] = $true }
    }
    foreach ($r in $S.TwRows.Values) { $v = $(if ($vis[$r.card.GetHashCode()]) { 'Visible' } else { 'Collapsed' }); $r.card.Visibility = $v; $r.hdr.Visibility = $v }
    foreach ($p in $S.PrefRows.Values) { $p.sw.Visibility = $(if (Test-Match $p.key $q) { 'Visible' } else { 'Collapsed' }) }
}
function Invoke-Pref($sw) {
    $t = $S.PrefRows[$sw.Tag].t; $on = [bool]$sw.IsChecked
    try {
        Invoke-HTweak $t (-not $on) | Out-Null
        Write-HLog ("Tercih: {0} {1}" -f $t.name, $(if ($on) { 'açıldı' } else { 'kapatıldı' })) 'ok'
        if ($t.restart -eq 'explorer') { Toast "$($t.name) $(if ($on) { 'açıldı' } else { 'kapatıldı' }). Görmek için Gezgin yenilenmeli." 'Ok' 'Yenile' 'explorer' }
        elseif ($RestartText[$t.restart]) { Toast "$($t.name): $($RestartText[$t.restart])." 'Info' }
        else { Toast "$($t.name) $(if ($on) { 'açıldı' } else { 'kapatıldı' })." 'Ok' }
    } catch {
        $sw.IsChecked = -not $on
        Write-HLog ("Tercih uygulanamadı: " + $_.Exception.Message) 'err'; Toast 'Ayar uygulanamadı, ayrıntı günlükte.' 'Err' 'Günlük' 'log'
    }
}
$W.BtnPresetRec.Add_Click({ Select-Tweaks { param($r) @($r.t.preset) -contains 'onerilen' }; Toast 'Önerilen tweakler seçildi. Gözden geçirip "Tweakleri çalıştır"a bas.' 'Info' })
$W.BtnPresetGame.Add_Click({ Select-Tweaks { param($r) @($r.t.preset) -contains 'oyuncu' }; Toast 'Oyuncu tweakleri seçildi. Gözden geçirip "Tweakleri çalıştır"a bas.' 'Info' })
$W.BtnPresetApplied.Add_Click({ Select-Tweaks { param($r) $r.applied }; Toast 'Bu bilgisayarda uygulanmış tweakler seçildi.' 'Info' })
$W.BtnPresetNone.Add_Click({ Select-Tweaks { param($r) $false } })

$JobTweaks = {
    param($a)
    if ($a.restore) { New-HRestorePoint | Out-Null }
    $n = $a.ids.Count; $i = 0; $fail = 0; $restarts = @()
    foreach ($id in $a.ids) {
        $t = $HT.Tweaks.tweaks | Where-Object { $_.id -eq $id } | Select-Object -First 1
        if (-not $t) { continue }
        $i++
        Send-UI 'progress' @{ v = [int](($i - 1) / $n * 100); s = "$i / $n  ·  $($t.name)" }
        Write-HLog ('▸ ' + $t.name) 'head'
        try {
            Invoke-HTweak $t ([bool]$a.undo) | Out-Null
            Write-HLog $(if ($a.undo) { '  geri alındı' } else { '  uygulandı' }) 'ok'
            if ($t.restart -and $t.restart -ne 'yok') { $restarts += $t.restart }
        } catch { $fail++; Write-HLog ('  HATA: ' + $_.Exception.Message) 'err' }
    }
    Send-UI 'progress' @{ v = 100; s = '' }
    $lvl = 'ok'; if ($fail) { $lvl = 'warn' }
    Write-HLog ("Bitti: {0} başarılı, {1} hatalı." -f ($i - $fail), $fail) $lvl
    return @{ restarts = @($restarts | Select-Object -Unique); fail = $fail; n = $i; undo = [bool]$a.undo }
}
$Handlers['tweaks'] = {
    param($r, $ok)
    Update-TweakStatus
    if (-not $r) { return }
    $rs = @($r.restarts)
    if ($rs -contains 'explorer' -and -not $S.Auto) {
        if (Ask 'Bazı değişikliklerin görünmesi için Dosya Gezgini yeniden başlatılmalı. Görev çubuğu bir saniyeliğine kaybolup geri gelir.' 'Gezgin yenilensin mi?' 'Question' 'Şimdi yenile' 'Sonra') { Restart-HExplorer; Write-HLog 'Dosya Gezgini yeniden başlatıldı.' 'ok' }
    }
    $verb = 'uygulandı'; if ($r.undo) { $verb = 'geri alındı' }
    $msg = "$($r.n - $r.fail) tweak $verb."
    if ($r.fail) { $msg += " $($r.fail) tanesinde hata oluştu, ayrıntılar günlükte." }
    if ($rs -contains 'pc') { $msg += "`n`nBazı değişiklikler bilgisayarı yeniden başlatınca etkinleşir." }
    elseif ($rs -contains 'oturum') { $msg += "`n`nBazı değişiklikler oturumu kapatıp açınca etkinleşir." }
    Set-Status ($msg -split "`n")[0] $(if ($r.fail) { 'Warn' } else { 'Ok' })
    if ($S.AutoApps) { $apps = $S.AutoApps; $S.AutoApps = $null; Start-HJob 'winget' $JobWinget @{ mode = 'install'; apps = $apps }; return }
    Info $msg $(if ($r.fail) { 'Kısmen tamamlandı' } else { 'Tamamlandı' }) $(if ($r.fail) { 'Warn' } else { 'Ok' })
}
function Start-Tweaks([bool]$undo, [string[]]$ids) {
    if (-not $ids -or $ids.Count -eq 0) { Toast 'Önce listeden en az bir tweak seç.' 'Warn'; return }
    $all = @{}; foreach ($t in $Tw) { $all[$t.id] = $t }
    $names = @($ids | ForEach-Object { $all[$_].name })
    $risky = @($ids | Where-Object { $all[$_].risk -ne 'dusuk' } | ForEach-Object { $all[$_].name })
    $txt = "• " + (($names | Select-Object -First 14) -join "`n• ")
    if ($names.Count -gt 14) { $txt += "`n• ... ve $($names.Count - 14) tane daha" }
    if (-not $undo -and $risky) { $txt += "`n`nŞunlar orta risklidir, açıklamalarını okuduğundan emin ol:`n• " + ($risky -join "`n• ") }
    $title = $(if ($undo) { "$($ids.Count) tweak geri alınacak" } else { "$($ids.Count) tweak uygulanacak" })
    if (-not (Ask $txt $title $(if ($risky -and -not $undo) { 'Warn' } else { 'Question' }) $(if ($undo) { 'Geri al' } else { 'Uygula' }))) { return }
    $restore = [bool]$W.ChkRestore.IsChecked -and -not $undo
    Write-HLog $(if ($undo) { "── $($ids.Count) tweak geri alınıyor ──" } else { "── $($ids.Count) tweak uygulanıyor ──" }) 'head'
    Start-HJob 'tweaks' $JobTweaks @{ ids = $ids; undo = $undo; restore = $restore }
}
$W.BtnTwApply.Add_Click({ Start-Tweaks $false (Get-SelectedTweakIds) })
$W.BtnTwUndo.Add_Click({ Start-Tweaks $true (Get-SelectedTweakIds) })

function Import-HConfig([string]$path) {
    if ($path -match '^https?://') { $o = Invoke-RestMethod $path } else { $o = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json }
    $ids = @($o.tweaks)
    Select-Tweaks { param($r) $ids -contains $r.t.id }
    foreach ($r in $S.AppRows.Values) { $r.cb.IsChecked = (@($o.apps) -contains $r.app.id) }
    Update-AppCount
    return @{ tweaks = @($ids | Where-Object { $S.TwRows.Contains($_) }); prefs = @($ids | Where-Object { $S.PrefRows.Contains($_) }); apps = @($o.apps | Where-Object { $S.AppRows.Contains($_) }) }
}
$W.BtnTwExport.Add_Click({
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.FileName = 'henox-ayarlarim.json'; $dlg.Filter = 'Henox Tweak ayarları (*.json)|*.json'
    if ($dlg.ShowDialog($win)) {
        $prefs = @($S.PrefRows.Values | Where-Object { $_.sw.IsChecked } | ForEach-Object { $_.t.id })
        $obj = [ordered]@{ henoxTweak = $HT_VERSION; tweaks = @((Get-SelectedTweakIds) + $prefs); apps = @($S.AppRows.Values | Where-Object { $_.cb.IsChecked } | ForEach-Object { $_.app.id }) }
        $obj | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $dlg.FileName -Encoding UTF8
        Toast "Seçimin kaydedildi: $([IO.Path]::GetFileName($dlg.FileName))" 'Ok'
    }
})
$W.BtnTwImport.Add_Click({
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = 'Henox Tweak ayarları (*.json)|*.json'
    if (-not $dlg.ShowDialog($win)) { return }
    try { $res = Import-HConfig $dlg.FileName } catch { Info 'Bu dosya geçerli bir Henox Tweak ayar dosyası değil.' 'Okunamadı' 'Err'; return }
    Toast "İçe aktarıldı: $($res.tweaks.Count) tweak, $($res.apps.Count) uygulama seçildi." 'Ok'
    if ($res.prefs.Count -and (Ask ("Dosyada $($res.prefs.Count) tercih (anahtar) var. Şimdi açılsınlar mı?`n`n• " + (($res.prefs | ForEach-Object { $S.PrefRows[$_].t.name }) -join "`n• ")) 'Tercihler' 'Question' 'Aç')) {
        foreach ($id in $res.prefs) { $sw = $S.PrefRows[$id].sw; if (-not $sw.IsChecked) { $sw.IsChecked = $true; Invoke-Pref $sw } }
    }
})

# ---- DNS
$Dns = [ordered]@{
    cloudflare = @{ n = 'Cloudflare'; s = @('1.1.1.1', '1.0.0.1', '2606:4700:4700::1111', '2606:4700:4700::1001'); d = '1.1.1.1 · hızlı, gizlilik odaklı' }
    google     = @{ n = 'Google';     s = @('8.8.8.8', '8.8.4.4', '2001:4860:4860::8888', '2001:4860:4860::8844'); d = '8.8.8.8 · güvenilir ve yaygın' }
    quad9      = @{ n = 'Quad9';      s = @('9.9.9.9', '149.112.112.112', '2620:fe::fe', '2620:fe::9'); d = '9.9.9.9 · zararlı siteleri engeller' }
    adguard    = @{ n = 'AdGuard';    s = @('94.140.14.14', '94.140.15.15', '2a10:50c0::ad1:ff', '2a10:50c0::ad2:ff'); d = '94.140.14.14 · reklamları engeller' }
    auto       = @{ n = 'Otomatik';   s = $null; d = 'İnternet sağlayıcının DNS''i' }
}
foreach ($k in $Dns.Keys) {
    $b = New-Object System.Windows.Controls.Button; $b.Style = $win.FindResource('Btn'); $b.Content = $Dns[$k].n; $b.Tag = $k; $b.Padding = '12,6'; $b.Margin = '0,0,6,6'; $b.ToolTip = $Dns[$k].d
    $b.Add_Click({ $k = $this.Tag; Start-HJob 'repair' $JobRepair @{ id = "dns:$k"; servers = $Dns[$k].s; name = $Dns[$k].n } })
    $W.DnsButtons.Children.Add($b) | Out-Null; $S.DnsButtons += $b
}
function Update-DnsText { try { $W.DnsNow.Text = 'Şu an:  ' + (Get-HDnsText) } catch { $W.DnsNow.Text = '' } }

# ─────────────────────────────────────────────────────────────── Uygulamalar
$S.AppRows = [ordered]@{}
$S.HasWinget = [bool](Get-Command winget -ErrorAction SilentlyContinue)
function Build-AppList {
    $W.AppList.Children.Clear(); $S.AppRows.Clear(); $S.AppCats = @(); $i = 0
    foreach ($cat in $HT.Apps.categories) {
        $items = @($Ap | Where-Object { $_.cat -eq $cat })
        if (-not $items) { continue }
        $card = New-Card; $card.Width = 300; $card.Margin = '0,0,12,12'; $card.Padding = '8,10,8,8'; $card.VerticalAlignment = 'Top'
        $sp = New-Object System.Windows.Controls.StackPanel
        $hd = New-Object System.Windows.Controls.DockPanel; $hd.Margin = '8,2,8,8'
        $cnt = New-Text "$($items.Count)" 11 'Dim'; $cnt.FontFamily = $Mono; [System.Windows.Controls.DockPanel]::SetDock($cnt, 'Right'); $hd.Children.Add($cnt) | Out-Null
        $hn = New-Text ($cat.ToUpper([Globalization.CultureInfo]'tr-TR')) 11.5 'Acc' 'Bold'; $hn.FontFamily = $Mono; $hd.Children.Add($hn) | Out-Null
        $sp.Children.Add($hd) | Out-Null
        foreach ($a in $items) {
            $row = New-Object System.Windows.Controls.Border; $row.Padding = '8,6'; $row.CornerRadius = 6; $row.Background = [System.Windows.Media.Brushes]::Transparent
            $row.Add_MouseEnter({ $this.SetResourceReference($DP.BdBg, 'Hover') }); $row.Add_MouseLeave({ $this.Background = [System.Windows.Media.Brushes]::Transparent })
            $cb = New-Object System.Windows.Controls.CheckBox; $cb.Style = $win.FindResource('Chk'); $cb.Tag = $a.id
            $g = New-Object System.Windows.Controls.DockPanel
            $inst = New-Text 'kurulu' 10.5 'Ok' 'SemiBold'; $inst.Visibility = 'Collapsed'; $inst.VerticalAlignment = 'Center'; $inst.Margin = '8,0,0,0'
            [System.Windows.Controls.DockPanel]::SetDock($inst, 'Right'); $g.Children.Add($inst) | Out-Null
            $nm = New-Text $a.name 13 'Txt'; $nm.TextTrimming = 'CharacterEllipsis'; $g.Children.Add($nm) | Out-Null
            $cb.Content = $g
            $tip = New-Object System.Windows.Controls.StackPanel
            $tip.Children.Add((New-Text $a.name 13 'Txt' 'Bold')) | Out-Null
            $tip.Children.Add((New-Text $a.desc 12 'Mut' -Wrap)) | Out-Null
            $idt = New-Text ("winget: " + $a.id + $(if ($a.source) { "  ($($a.source))" } else { '' })) 11 'Dim'; $idt.FontFamily = $Mono; $idt.Margin = '0,5,0,0'; $tip.Children.Add($idt) | Out-Null
            $cb.ToolTip = $tip
            $cb.Add_Click({ Update-AppCount })
            $row.Child = $cb; $sp.Children.Add($row) | Out-Null
            $S.AppRows[$a.id] = @{ app = $a; cb = $cb; inst = $inst; row = $row; card = $card; key = ("$($a.name) $($a.desc) $($a.id) $cat").ToLower([Globalization.CultureInfo]'tr-TR') }
        }
        $card.Child = $sp; $W.AppList.Children.Add($card) | Out-Null
        $S.AppCats += $card
        Reveal $card $i; $i++
    }
}
function Update-AppCount { $W.TxtAppCount.Text = "$(@($S.AppRows.Values | Where-Object { $_.cb.IsChecked }).Count) seçili  ·  $($S.AppRows.Count) uygulama" }
$S.Filters['Apps'] = {
    param($q)
    $vis = @{}
    foreach ($r in $S.AppRows.Values) {
        $show = (Test-Match $r.key $q) -and (-not $S.AppShowSel -or $r.cb.IsChecked)
        $r.row.Visibility = $(if ($show) { 'Visible' } else { 'Collapsed' })
        if ($show) { $vis[$r.card.GetHashCode()] = $true }
    }
    foreach ($c in $S.AppCats) { $c.Visibility = $(if ($vis[$c.GetHashCode()]) { 'Visible' } else { 'Collapsed' }) }
}
function Update-AppFilter { & $S.Filters['Apps'] ($W.GlobalSearch.Text.Trim().ToLower([Globalization.CultureInfo]'tr-TR')) }
$W.BtnAppClear.Add_Click({ foreach ($r in $S.AppRows.Values) { $r.cb.IsChecked = $false }; Update-AppCount; if ($S.AppShowSel) { Update-AppFilter } })
$W.BtnAppShowSel.Add_Click({
    $S.AppShowSel = -not $S.AppShowSel
    $W.BtnAppShowSel.Content = $(if ($S.AppShowSel) { 'Tümünü göster' } else { 'Sadece seçilenleri göster' })
    Update-AppFilter
})
$W.BtnAppInstalled.Add_Click({
    if (-not $S.Installed.Count) { Toast 'Kurulu uygulamalar henüz okunmadı, birkaç saniye bekle.' 'Warn'; return }
    $c = 0; foreach ($r in $S.AppRows.Values) { $on = $S.Installed -contains $r.app.id; $r.cb.IsChecked = $on; if ($on) { $c++ } }
    Update-AppCount; Toast "Kurulu $c uygulama seçildi. 'Seçilenleri kur' bunları günceller." 'Info'
})
$W.BtnGetWinget.Add_Click({ Open-Url 'ms-windows-store://pdp/?productid=9NBLGGH4NNS1' })

$JobWingetScan = {
    $tmp = Join-Path $env:TEMP ("henox_wg_{0}.json" -f (Get-Random))
    & winget export -o $tmp --include-versions --accept-source-agreements --disable-interactivity 2>&1 | Out-Null
    $ids = @()
    if (Test-Path -LiteralPath $tmp) {
        try { $j = Get-Content -LiteralPath $tmp -Raw -Encoding UTF8 | ConvertFrom-Json; foreach ($s in $j.Sources) { foreach ($p in $s.Packages) { $ids += $p.PackageIdentifier } } } catch {}
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
    return @{ ids = $ids }
}
$Handlers['wingetscan'] = {
    param($r, $ok)
    if (-not $r) { return }
    $S.Installed = @($r.ids); $cnt = 0
    foreach ($row in $S.AppRows.Values) { $on = $S.Installed -contains $row.app.id; $row.inst.Visibility = $(if ($on) { 'Visible' } else { 'Collapsed' }); if ($on) { $cnt++ } }
    Set-Status "Uygulama listesi hazır  ·  listedekilerden $cnt tanesi zaten kurulu."
}
function Start-WingetScan {
    if (-not $S.HasWinget) { $W.WingetWarn.Visibility = 'Visible'; foreach ($n in 'BtnAppInstall', 'BtnAppUninstall', 'BtnAppUpgrade') { $W[$n].IsEnabled = $false }; return }
    Set-Status 'Kurulu uygulamalar kontrol ediliyor...' 'Warn'
    Start-HJob 'wingetscan' $JobWingetScan -Background
}
$JobWinget = {
    param($a)
    $fail = 0
    if ($a.mode -eq 'upgrade') {
        Write-HLog '▸ Kurulu tüm uygulamalar güncelleniyor (winget upgrade --all)' 'head'
        $null = Invoke-HWinget @('upgrade', '--all', '--include-unknown', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
        Write-HLog 'Güncelleme tamamlandı.' 'ok'
        return @{ mode = 'upgrade'; fail = 0; n = 0 }
    }
    $n = $a.apps.Count; $i = 0
    foreach ($app in $a.apps) {
        $i++
        Send-UI 'progress' @{ v = [int](($i - 1) / $n * 100); s = "$i / $n  ·  $($app.name)" }
        $src = 'winget'; if ($app.source) { $src = $app.source }
        if ($a.mode -eq 'install') {
            Write-HLog ("▸ {0} kuruluyor" -f $app.name) 'head'
            $code = Invoke-HWinget @('install', '--id', $app.id, '--exact', '--source', $src, '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
        } else {
            Write-HLog ("▸ {0} kaldırılıyor" -f $app.name) 'head'
            $code = Invoke-HWinget @('uninstall', '--id', $app.id, '--exact', '--silent', '--accept-source-agreements', '--disable-interactivity')
        }
        if ($code -eq 0) { Write-HLog '  tamam' 'ok' }
        elseif ($code -eq -1978335189 -or $code -eq -1978335135) { Write-HLog '  zaten kurulu ve güncel' 'ok' }
        else { $fail++; Write-HLog ("  başarısız (winget kodu {0})" -f $code) 'err' }
    }
    return @{ mode = $a.mode; fail = $fail; n = $n }
}
$Handlers['winget'] = {
    param($r, $ok)
    if ($r) {
        if ($r.mode -eq 'upgrade') { Toast 'Güncelleme bitti.' 'Ok'; Set-Status 'Güncelleme bitti.' }
        else {
            $v = 'kuruldu'; if ($r.mode -eq 'uninstall') { $v = 'kaldırıldı' }
            $m = "{0} uygulamadan {1} tanesi {2}." -f $r.n, ($r.n - $r.fail), $v
            if ($r.fail) { Toast "$m $($r.fail) hata var." 'Warn' 'Günlük' 'log'; Set-Status $m 'Warn' } else { Toast $m 'Ok'; Set-Status $m }
        }
    }
    Start-HJob 'wingetscan' $JobWingetScan -Background
}
function Start-Winget([string]$mode) {
    $apps = @($S.AppRows.Values | Where-Object { $_.cb.IsChecked } | ForEach-Object { $_.app })
    if ($mode -ne 'upgrade' -and -not $apps) { Toast 'Önce listeden en az bir uygulama seç.' 'Warn'; return }
    if ($mode -eq 'uninstall' -and -not (Ask ("• " + (($apps | ForEach-Object { $_.name }) -join "`n• ")) "$($apps.Count) uygulama kaldırılacak" 'Warn' 'Kaldır')) { return }
    if ($mode -eq 'upgrade' -and -not (Ask 'Bilgisayarındaki winget ile güncellenebilen tüm uygulamalar güncellenecek. Uzun sürebilir ve bazı programlar kapanabilir.' 'Her şey güncellensin mi?' 'Question' 'Güncelle')) { return }
    $sel = @($apps | ForEach-Object { @{ id = $_.id; name = $_.name; source = $_.source } })
    Start-HJob 'winget' $JobWinget @{ mode = $mode; apps = $sel }
}
$W.BtnAppInstall.Add_Click({ Start-Winget 'install' })
$W.BtnAppUninstall.Add_Click({ Start-Winget 'uninstall' })
$W.BtnAppUpgrade.Add_Click({ Start-Winget 'upgrade' })

# ─────────────────────────────────────────────────────────────── Debloat
$S.DbRows = [ordered]@{}
function Build-DebloatList {
    $W.DebloatList.Children.Clear(); $S.DbRows.Clear(); $i = 0
    foreach ($a in $HT.Debloat.apps) {
        $b = New-Card; $b.Width = 300; $b.Margin = '0,0,12,12'; $b.Padding = '14,12'
        $cb = New-Object System.Windows.Controls.CheckBox; $cb.Style = $win.FindResource('Chk'); $cb.Tag = $a.pkg
        $sp = New-Object System.Windows.Controls.StackPanel
        $l1 = New-Object System.Windows.Controls.WrapPanel
        $l1.Children.Add((New-Text $a.name 13 'Txt' 'SemiBold')) | Out-Null
        if ($a.safe) { $l1.Children.Add((New-Badge 'GÜVENLİ' 'Info')) | Out-Null }
        $sp.Children.Add($l1) | Out-Null
        $d = New-Text $a.desc 11.5 'Dim' -Wrap; $d.Margin = '0,2,0,0'; $sp.Children.Add($d) | Out-Null
        $cb.Content = $sp; $cb.ToolTip = $a.pkg
        $b.Child = $cb; $W.DebloatList.Children.Add($b) | Out-Null
        $S.DbRows[$a.pkg] = @{ a = $a; cb = $cb; card = $b; key = ("$($a.name) $($a.desc) $($a.pkg)").ToLower([Globalization.CultureInfo]'tr-TR') }
        Reveal $b $i; $i++
    }
}
$S.Filters['Debloat'] = { param($q); foreach ($r in $S.DbRows.Values) { $r.card.Visibility = $(if (Test-Match $r.key $q) { 'Visible' } else { 'Collapsed' }) } }
$JobAppxScan = {
    try { $pk = @(Get-AppxPackage -AllUsers -ErrorAction Stop) } catch { $pk = @(Get-AppxPackage -ErrorAction SilentlyContinue) }
    return @{ names = @($pk | Select-Object -ExpandProperty Name -Unique) }
}
$Handlers['appxscan'] = {
    param($r, $ok)
    if (-not $r) { return }
    $S.Appx = @($r.names); $cnt = 0
    foreach ($row in $S.DbRows.Values) {
        $has = $S.Appx -contains $row.a.pkg
        $row.cb.IsEnabled = $has
        if (-not $has) { $row.cb.IsChecked = $false; Anim $row.card $DP.Opacity 0.45 300 } else { Anim $row.card $DP.Opacity 1 300; $cnt++ }
    }
    Set-Status "Listedeki uygulamalardan $cnt tanesi bu bilgisayarda yüklü."
}
function Start-AppxScan { Set-Status 'Yüklü uygulamalar okunuyor...' 'Warn'; Start-HJob 'appxscan' $JobAppxScan -Background }
$W.BtnDbSafe.Add_Click({ foreach ($r in $S.DbRows.Values) { $r.cb.IsChecked = ($r.a.safe -and $r.cb.IsEnabled) } })
$JobDebloat = {
    param($a)
    $n = $a.pkgs.Count; $i = 0; $fail = 0
    foreach ($p in $a.pkgs) {
        $i++
        Send-UI 'progress' @{ v = [int](($i - 1) / $n * 100); s = "$i / $n  ·  $($p.name)" }
        Write-HLog ('▸ ' + $p.name + ' kaldırılıyor') 'head'
        foreach ($x in @(Get-AppxPackage -Name $p.pkg -AllUsers -ErrorAction SilentlyContinue)) {
            try { Remove-AppxPackage -Package $x.PackageFullName -AllUsers -ErrorAction Stop }
            catch { try { Remove-AppxPackage -Package $x.PackageFullName -ErrorAction Stop } catch { Write-HLog ('  ' + $_.Exception.Message) 'dim' } }
        }
        Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq $p.pkg } | ForEach-Object {
            Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue | Out-Null
        }
        if (@(Get-AppxPackage -Name $p.pkg -ErrorAction SilentlyContinue).Count -eq 0) { Write-HLog '  kaldırıldı' 'ok' } else { $fail++; Write-HLog '  tamamen kaldırılamadı (sistem bileşeni olabilir)' 'warn' }
    }
    return @{ n = $n; fail = $fail }
}
$Handlers['debloat'] = { param($r, $ok); if ($r) { Toast ("{0} uygulamadan {1} tanesi kaldırıldı." -f $r.n, ($r.n - $r.fail)) $(if ($r.fail) { 'Warn' } else { 'Ok' }) }; Start-AppxScan }
$W.BtnDbRemove.Add_Click({
    $sel = @($S.DbRows.Values | Where-Object { $_.cb.IsChecked } | ForEach-Object { @{ pkg = $_.a.pkg; name = $_.a.name } })
    if (-not $sel) { Toast 'Önce kaldırılacak uygulamaları seç.' 'Warn'; return }
    if (-not (Ask ("• " + (($sel | ForEach-Object { $_.name }) -join "`n• ") + "`n`nİstersen sonra Microsoft Store'dan geri kurabilirsin.") "$($sel.Count) uygulama kaldırılacak" 'Warn' 'Kaldır')) { return }
    Start-HJob 'debloat' $JobDebloat @{ pkgs = $sel }
})

# ─────────────────────────────────────────────────────────────── Başlangıç
$S.StRows = @()
function Build-StartupList {
    $W.StartupList.Children.Clear(); $S.StRows = @()
    $items = @(Get-HStartup | Sort-Object Scope, Name)
    $on = @($items | Where-Object Enabled).Count
    $W.StartupList.Children.Add((New-Section "$($items.Count) başlangıç öğesi  ·  $on tanesi açık" 'Windows güvenliği ve ses / dokunmatik yüzey sürücüleri gibi bilmediğin öğeleri açık bırakman önerilir.')) | Out-Null
    $card = New-Card; $sp = New-Object System.Windows.Controls.StackPanel; $card.Child = $sp
    $W.StartupList.Children.Add($card) | Out-Null
    $n = 0
    foreach ($it in $items) {
        $row = New-Object System.Windows.Controls.Border; $row.Padding = '16,12'; $row.SetResourceReference($DP.BdBr, 'Line')
        $row.BorderThickness = $(if ($n -lt $items.Count - 1) { '0,0,0,1' } else { '0' })
        $sw = New-Object System.Windows.Controls.CheckBox; $sw.Style = $win.FindResource('Sw'); $sw.IsChecked = $it.Enabled; $sw.Tag = $it
        $sw.Add_Click({
            $item = $this.Tag; $want = [bool]$this.IsChecked
            try { Set-HStartupEnabled $item $want; Write-HLog ("Başlangıç: {0} {1}" -f $item.Name, $(if ($want) { 'açıldı' } else { 'kapatıldı' })) 'ok'; Toast ("{0} açılışta {1}." -f $item.Name, $(if ($want) { 'başlayacak' } else { 'artık başlamayacak' })) 'Ok' }
            catch { $this.IsChecked = -not $want; Write-HLog ("Başlangıç ayarlanamadı: " + $_.Exception.Message) 'err'; Toast 'Değiştirilemedi, ayrıntı günlükte.' 'Err' }
        })
        $inf = New-Object System.Windows.Controls.StackPanel
        $l1 = New-Object System.Windows.Controls.WrapPanel
        $l1.Children.Add((New-Text $it.Name 13 'Txt' 'SemiBold')) | Out-Null
        $l1.Children.Add((New-Badge ($it.Scope.ToUpper([Globalization.CultureInfo]'tr-TR')) 'Dim')) | Out-Null
        $inf.Children.Add($l1) | Out-Null
        $cmd = New-Text $it.Command 11 'Dim'; $cmd.FontFamily = $Mono; $cmd.TextTrimming = 'CharacterEllipsis'; $cmd.Margin = '0,3,0,0'; $cmd.ToolTip = $it.Command
        $inf.Children.Add($cmd) | Out-Null
        $sw.Content = $inf
        $row.Child = $sw; $sp.Children.Add($row) | Out-Null
        $S.StRows += @{ row = $row; key = ("$($it.Name) $($it.Command)").ToLower([Globalization.CultureInfo]'tr-TR') }
        Reveal $row $n; $n++
    }
    if (-not $items) { $e = New-Text 'Başlangıçta çalışan program bulunamadı.' 13 'Dim'; $e.Margin = '16'; $sp.Children.Add($e) | Out-Null }
}
$S.Filters['Startup'] = { param($q); foreach ($r in $S.StRows) { $r.row.Visibility = $(if (Test-Match $r.key $q) { 'Visible' } else { 'Collapsed' }) } }
$W.BtnStRefresh.Add_Click({ Build-StartupList; Toast 'Başlangıç listesi yenilendi.' 'Ok' })
$W.BtnStTaskmgr.Add_Click({ Start-Process taskmgr.exe -ArgumentList '/0 /startup' })

# ─────────────────────────────────────────────────────────────── Temizlik
$S.ClRows = [ordered]@{}
function Build-CleanList {
    $W.CleanList.Children.Clear(); $S.ClRows.Clear()
    $W.CleanList.Children.Add((New-Section 'Temizlenebilecek alanlar' 'Kullanımdaki dosyalar otomatik atlanır. Belgeler, Masaüstü, İndirilenler gibi kişisel klasörlerine asla dokunulmaz.')) | Out-Null
    $card = New-Card; $sp = New-Object System.Windows.Controls.StackPanel; $card.Child = $sp
    $W.CleanList.Children.Add($card) | Out-Null
    $all = Get-HCleanTargets; $n = 0
    foreach ($t in $all) {
        $row = New-Object System.Windows.Controls.Border; $row.Padding = '16,13'; $row.SetResourceReference($DP.BdBr, 'Line')
        $row.BorderThickness = $(if ($n -lt $all.Count - 1) { '0,0,0,1' } else { '0' })
        $g = New-Object System.Windows.Controls.Grid
        foreach ($wd in '*', 'Auto') { $cd = New-Object System.Windows.Controls.ColumnDefinition; $cd.Width = $wd; $g.ColumnDefinitions.Add($cd) }
        $cb = New-Object System.Windows.Controls.CheckBox; $cb.Style = $win.FindResource('Chk'); $cb.IsChecked = $t.def; $cb.Tag = $t.id
        $inf = New-Object System.Windows.Controls.StackPanel
        $inf.Children.Add((New-Text $t.name 13.5 'Txt' 'SemiBold')) | Out-Null
        $d = New-Text $t.desc 12 'Dim' -Wrap; $d.Margin = '0,3,0,0'; $inf.Children.Add($d) | Out-Null
        $cb.Content = $inf
        if ($t.paths) { $cb.ToolTip = ($t.paths -join "`n") }
        $cb.Add_Click({ Update-CleanTotal })
        $sz = New-Text '—' 14 'Dim' 'SemiBold'; $sz.FontFamily = $Mono; $sz.VerticalAlignment = 'Center'; $sz.MinWidth = 110; $sz.TextAlignment = 'Right'
        [System.Windows.Controls.Grid]::SetColumn($sz, 1)
        $g.Children.Add($cb) | Out-Null; $g.Children.Add($sz) | Out-Null
        $row.Child = $g; $sp.Children.Add($row) | Out-Null
        $S.ClRows[$t.id] = @{ t = $t; cb = $cb; sz = $sz; row = $row; key = ("$($t.name) $($t.desc)").ToLower([Globalization.CultureInfo]'tr-TR') }
        $n++
    }
}
$S.Filters['Clean'] = { param($q); foreach ($r in $S.ClRows.Values) { $r.row.Visibility = $(if (Test-Match $r.key $q) { 'Visible' } else { 'Collapsed' }) } }
$S.ClShown = [int64]0
function Update-CleanTotal {
    [int64]$sum = 0
    foreach ($r in $S.ClRows.Values) { if ($r.cb.IsChecked -and $S.CleanSizes.ContainsKey($r.t.id)) { $sum += $S.CleanSizes[$r.t.id] } }
    # Sayaç animasyonu: eski değerden yeniye doğru sayar
    $S.ClTarget = $sum
    if (-not $S.ClTimer) {
        $S.ClTimer = New-Object System.Windows.Threading.DispatcherTimer; $S.ClTimer.Interval = [TimeSpan]::FromMilliseconds(16)
        $S.ClTimer.Add_Tick({
            $diff = $S.ClTarget - $S.ClShown
            if ([math]::Abs($diff) -lt 1MB) { $S.ClShown = $S.ClTarget; $this.Stop() } else { $S.ClShown += [int64]($diff * 0.18) }
            $W.TxtClTotal.Text = Format-HSize $S.ClShown
        })
    }
    $S.ClTimer.Start()
}
$JobCleanScan = {
    $res = @{}
    foreach ($t in (Get-HCleanTargets)) { $res[$t.id] = [int64](Get-HTargetSize $t); Send-UI 'cleansize' @{ id = $t.id; b = $res[$t.id] } }
    return @{ sizes = $res }
}
$Handlers['cleanscan'] = { param($r, $ok); Update-CleanTotal; Set-Status 'Tarama bitti.' }
function Start-CleanScan {
    foreach ($r in $S.ClRows.Values) { $r.sz.Text = '...'; $r.sz.SetResourceReference($DP.TbFg, 'Dim') }
    Set-Status 'Temizlenebilecek alan hesaplanıyor...' 'Warn'
    Start-HJob 'cleanscan' $JobCleanScan
}
$JobClean = {
    param($a)
    [int64]$freed = 0
    $all = Get-HCleanTargets
    $n = $a.ids.Count; $i = 0
    foreach ($id in $a.ids) {
        $t = $all | Where-Object { $_.id -eq $id } | Select-Object -First 1
        $i++
        Send-UI 'progress' @{ v = [int](($i - 1) / $n * 100); s = "$i / $n  ·  $($t.name)" }
        Write-HLog ('▸ ' + $t.name) 'head'
        $before = Get-HTargetSize $t
        Clear-HTarget $t
        $after = Get-HTargetSize $t
        $f = [math]::Max(0, $before - $after); $freed += $f
        Send-UI 'cleansize' @{ id = $t.id; b = [int64]$after }
        Write-HLog ('  ' + (Format-HSize $f) + ' temizlendi' + $(if ($after -gt 0) { ' (' + (Format-HSize $after) + ' kullanımda olduğu için atlandı)' } else { '' })) 'ok'
    }
    Write-HLog ("Toplam {0} alan açıldı." -f (Format-HSize $freed)) 'ok'
    return @{ freed = $freed }
}
$Handlers['clean'] = { param($r, $ok); Update-CleanTotal; if ($r) { Set-Status ("Temizlik bitti: {0} alan açıldı." -f (Format-HSize $r.freed)); Info ("{0} disk alanı açıldı." -f (Format-HSize $r.freed)) 'Temizlik tamamlandı' 'Ok' } }
$W.BtnClScan.Add_Click({ Start-CleanScan })
$W.BtnClRun.Add_Click({
    $ids = @($S.ClRows.Values | Where-Object { $_.cb.IsChecked } | ForEach-Object { $_.t.id })
    if (-not $ids) { Toast 'Önce temizlenecek alanları seç.' 'Warn'; return }
    if ($ids -contains 'recycle' -and -not (Ask 'Geri Dönüşüm Kutusu da boşaltılacak, içindekiler geri getirilemez.' 'Emin misin?' 'Warn' 'Boşalt ve temizle')) { return }
    Start-HJob 'clean' $JobClean @{ ids = $ids }
})

# ─────────────────────────────────────────────────────────────── Onarım
$Repair = @(
    @{ sec = 'Sistem onarımı'; id = 'sfc';       i = 0xE9D9; t = 'Sistem dosyalarını onar (SFC)';  d = 'Bozuk Windows dosyalarını tarar ve onarır. 10-20 dk sürer, ayrı pencerede çalışır.' },
    @{ sec = 'Sistem onarımı'; id = 'dism';      i = 0xE90F; t = 'Windows imajını onar (DISM)';    d = 'SFC onaramazsa önce bunu çalıştır. İnternet gerekir, ayrı pencerede çalışır.' },
    @{ sec = 'Sistem onarımı'; id = 'dismclean'; i = 0xE74D; t = 'Bileşen deposunu temizle';       d = 'Eski güncelleme kalıntılarını siler, birkaç GB açabilir. Ayrı pencerede çalışır.' },
    @{ sec = 'Sistem onarımı'; id = 'wureset';   i = 0xE895; t = 'Windows Update''i onar';          d = 'Takılan veya hata veren güncellemeler için Update önbelleğini sıfırlar.' },
    @{ sec = 'Sistem onarımı'; id = 'restore';   i = 0xE81C; t = 'Geri yükleme noktası oluştur';   d = 'Sistemin şu anki halini kaydeder; sorun çıkarsa geri dönebilirsin.' },
    @{ sec = 'Sistem onarımı'; id = 'rstrui';    i = 0xE777; t = 'Sistem Geri Yükleme''yi aç';      d = 'Daha önce oluşturulmuş bir geri yükleme noktasına dön.' },
    @{ sec = 'Ağ';             id = 'dnsflush';  i = 0xE72C; t = 'DNS önbelleğini temizle';        d = 'Açılmayan siteler ve DNS_PROBE hataları için.' },
    @{ sec = 'Ağ';             id = 'netreset';  i = 0xE968; t = 'Ağ ayarlarını sıfırla';          d = 'Winsock ve TCP/IP''yi sıfırlar. Bağlantı sorunlarında son çare; yeniden başlatma gerekir.' },
    @{ sec = 'Gezgin';         id = 'explorer';  i = 0xEC50; t = 'Dosya Gezgini''ni yeniden başlat'; d = 'Donan görev çubuğu, Başlat menüsü veya masaüstü için.' },
    @{ sec = 'Gezgin';         id = 'iconcache'; i = 0xE91B; t = 'Simge önbelleğini yenile';       d = 'Bozuk, boş veya yanlış görünen simgeler için.' }
)
$Tools = [ordered]@{ 'devmgmt.msc' = 'Aygıt Yöneticisi'; 'services.msc' = 'Hizmetler'; 'appwiz.cpl' = 'Programlar ve Özellikler'; 'powercfg.cpl' = 'Güç Seçenekleri'; 'ncpa.cpl' = 'Ağ Bağlantıları'; 'sysdm.cpl' = 'Sistem Özellikleri'; 'eventvwr.msc' = 'Olay Görüntüleyici'; 'msinfo32' = 'Sistem Bilgisi'; 'regedit' = 'Kayıt Defteri'; 'mmsys.cpl' = 'Ses Ayarları'; 'diskmgmt.msc' = 'Disk Yönetimi'; 'taskmgr' = 'Görev Yöneticisi' }
foreach ($k in $Tools.Keys) { $Repair += @{ sec = 'Windows araçları'; id = "tool:$k"; i = 0xE8A7; t = $Tools[$k]; d = $k; small = $true } }
$S.RpRows = @()
function Build-RepairList {
    $W.RepairList.Children.Clear(); $i = 0
    foreach ($sec in @($Repair | ForEach-Object { $_.sec } | Select-Object -Unique)) {
        $hdr = New-Section $sec ''
        $W.RepairList.Children.Add($hdr) | Out-Null
        $wrap = New-Object System.Windows.Controls.WrapPanel
        foreach ($a in @($Repair | Where-Object { $_.sec -eq $sec })) {
            $b = New-Object System.Windows.Controls.Button; $b.Style = $win.FindResource('Card'); $b.Tag = $a.id
            if ($a.small) { $b.Width = 200; $b.Padding = '14,11' }
            $g = New-Object System.Windows.Controls.Grid
            foreach ($wd in 'Auto', '*') { $cd = New-Object System.Windows.Controls.ColumnDefinition; $cd.Width = $wd; $g.ColumnDefinitions.Add($cd) }
            $ib = New-Object System.Windows.Controls.Border; $ib.Width = 32; $ib.Height = 32; $ib.CornerRadius = 8; $ib.SetResourceReference($DP.BdBg, 'AccSoft'); $ib.Margin = '0,0,12,0'; $ib.VerticalAlignment = 'Top'
            $ic = New-Icon $a.i 14 'Acc'; $ic.HorizontalAlignment = 'Center'; $ib.Child = $ic
            $sp = New-Object System.Windows.Controls.StackPanel
            $sp.Children.Add((New-Text $a.t 13 'Txt' 'SemiBold' -Wrap)) | Out-Null
            $d = New-Text $a.d 11.5 'Dim' -Wrap; $d.Margin = '0,3,0,0'; if ($a.small) { $d.FontFamily = $Mono; $d.FontSize = 10.5 }
            $sp.Children.Add($d) | Out-Null
            [System.Windows.Controls.Grid]::SetColumn($sp, 1)
            if (-not $a.small) { $g.Children.Add($ib) | Out-Null }
            $g.Children.Add($sp) | Out-Null
            $b.Content = $g
            $b.Add_Click({ Invoke-Repair $this.Tag })
            $wrap.Children.Add($b) | Out-Null
            if (-not $a.small) { $S.RepairButtons += $b }
            $S.RpRows += @{ b = $b; key = ("$($a.t) $($a.d)").ToLower([Globalization.CultureInfo]'tr-TR') }
            Reveal $b $i; $i++
        }
        $W.RepairList.Children.Add($wrap) | Out-Null
    }
}
$S.Filters['Repair'] = { param($q); foreach ($r in $S.RpRows) { $r.b.Visibility = $(if (Test-Match $r.key $q) { 'Visible' } else { 'Collapsed' }) } }
function Open-Console([string]$title, [string]$cmd) {
    Start-Process cmd.exe -ArgumentList "/k title $title & echo. & echo  Henox Tweak: $title & echo  Bitince bu pencereyi kapatabilirsin. & echo. & $cmd"
}
$JobRepair = {
    param($a)
    switch ($a.id) {
        'dnsflush' { Write-HLog '▸ DNS önbelleği temizleniyor' 'head'; Clear-DnsClientCache; ipconfig /flushdns | Out-Null; Write-HLog '  tamam' 'ok' }
        'netreset' { Write-HLog '▸ Ağ ayarları sıfırlanıyor' 'head'; netsh winsock reset | Out-Null; netsh int ip reset | Out-Null; ipconfig /flushdns | Out-Null; Write-HLog '  tamam. Etkili olması için bilgisayarı yeniden başlat.' 'ok' }
        'wureset' {
            Write-HLog '▸ Windows Update bileşenleri sıfırlanıyor' 'head'
            $svcs = 'wuauserv', 'bits', 'cryptsvc', 'msiserver'
            foreach ($s in $svcs) { Stop-Service -Name $s -Force -ErrorAction SilentlyContinue }
            foreach ($p in @("$env:windir\SoftwareDistribution", "$env:windir\System32\catroot2")) {
                if (Test-Path -LiteralPath "$p.bak") { Remove-Item -LiteralPath "$p.bak" -Recurse -Force -ErrorAction SilentlyContinue }
                if (Test-Path -LiteralPath $p) { Rename-Item -LiteralPath $p -NewName ((Split-Path $p -Leaf) + '.bak') -ErrorAction SilentlyContinue }
            }
            foreach ($s in $svcs) { Start-Service -Name $s -ErrorAction SilentlyContinue }
            Write-HLog '  tamam. Şimdi Ayarlar > Windows Update > Güncelleştirmeleri denetle.' 'ok'
        }
        'restore'   { New-HRestorePoint | Out-Null }
        'explorer'  { Write-HLog '▸ Dosya Gezgini yeniden başlatılıyor' 'head'; Restart-HExplorer; Write-HLog '  tamam' 'ok' }
        'iconcache' {
            Write-HLog '▸ Simge önbelleği yenileniyor' 'head'
            Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 800
            Remove-Item -LiteralPath "$env:LOCALAPPDATA\IconCache.db" -Force -ErrorAction SilentlyContinue
            Get-ChildItem -LiteralPath "$env:LOCALAPPDATA\Microsoft\Windows\Explorer" -Filter 'iconcache_*.db' -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 600
            if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
            Write-HLog '  tamam' 'ok'
        }
        default { if ($a.id -like 'dns:*') { Write-HLog ('▸ DNS ayarlanıyor: ' + $a.name) 'head'; Set-HDns $a.servers } }
    }
    return @{ id = $a.id; name = $a.name }
}
$Handlers['repair'] = {
    param($r, $ok)
    Update-DnsText
    if (-not $r) { return }
    $msg = switch -Wildcard ($r.id) { 'dns:*' { "DNS: $($r.name) ayarlandı." } 'restore' { 'Geri yükleme noktası işlemi bitti (sonuç günlükte).' } 'netreset' { 'Ağ sıfırlandı. Bilgisayarı yeniden başlat.' } default { 'İşlem tamamlandı.' } }
    if ($ok) { Toast $msg 'Ok' } else { Toast 'İşlem başarısız, ayrıntı günlükte.' 'Err' 'Günlük' 'log' }
    Set-Status $msg
}
function Invoke-Repair([string]$id) {
    if ($id -like 'tool:*') { try { Start-Process ($id.Substring(5)) } catch { Write-HLog "Açılamadı: $id" 'err' }; return }
    switch ($id) {
        'sfc'       { Open-Console 'SFC' 'sfc /scannow'; Toast 'SFC ayrı pencerede başlatıldı.' 'Info'; return }
        'dism'      { Open-Console 'DISM' 'DISM /Online /Cleanup-Image /RestoreHealth'; Toast 'DISM ayrı pencerede başlatıldı.' 'Info'; return }
        'dismclean' { Open-Console 'Bilesen temizligi' 'DISM /Online /Cleanup-Image /StartComponentCleanup'; Toast 'Bileşen temizliği ayrı pencerede başlatıldı.' 'Info'; return }
        'rstrui'    { Start-Process rstrui.exe; return }
        'netreset'  { if (-not (Ask 'Winsock ve TCP/IP sıfırlanacak. VPN ve elle girilmiş IP ayarların silinebilir; sonrasında yeniden başlatman gerekir.' 'Ağ ayarları sıfırlansın mı?' 'Warn' 'Sıfırla')) { return } }
        'wureset'   { if (-not (Ask 'Windows Update servisleri durdurulup önbelleği sıfırlanacak.' 'Windows Update onarılsın mı?' 'Question' 'Onar')) { return } }
    }
    Start-HJob 'repair' $JobRepair @{ id = $id }
}

# ─────────────────────────────────────────────────────────────── Hakkında
function Update-BackupInfo {
    $b = Read-HBackup
    $W.TxtBackupInfo.Text = "Yedek dosyası     $($sync.BackupFile)`nYedeği tutulan    $($b.Keys.Count) tweak`nBu oturumun günlüğü $($sync.LogFile)"
}
$W.BtnOpenData.Add_Click({ Start-Process explorer.exe -ArgumentList "`"$DataDir`"" })
$W.BtnUndoAll.Add_Click({
    $ids = @((Read-HBackup).Keys | Where-Object { $S.TwRows.Contains($_) -or $S.PrefRows.Contains($_) })
    if (-not $ids) { Info 'Henox Tweak ile uygulanmış ve yedeği tutulan bir tweak yok.' 'Geri alınacak bir şey yok' 'Info'; return }
    Start-Tweaks $true $ids
})
$W.BtnSite.Add_Click({ Open-Url 'https://tweak.henox.dev' })
$W.BtnGithub.Add_Click({ Open-Url 'https://github.com/Henox77/henox-tweak' })
$W.BtnAbout.Add_Click({ Show-Page 'About' })
$W.BtnTheme.Add_Click({ Set-Theme $(if ($S.Theme -eq 'dark') { 'light' } else { 'dark' }); Save-Settings })
$W.BtnLog.Add_Click({ Toggle-Log })

# Panel hızlı işlemleri
$W.BtnQuickRec.Add_Click({ Show-Page 'Tweaks'; Select-Tweaks { param($r) @($r.t.preset) -contains 'onerilen' }; Toast 'Önerilen tweakler seçildi. Gözden geçirip "Tweakleri çalıştır"a bas.' 'Info' })
$W.BtnQuickGame.Add_Click({ Show-Page 'Tweaks'; Select-Tweaks { param($r) @($r.t.preset) -contains 'oyuncu' }; Toast 'Oyuncu tweakleri seçildi. Gözden geçirip "Tweakleri çalıştır"a bas.' 'Info' })
$W.BtnQuickClean.Add_Click({ Show-Page 'Clean' })
$W.BtnQuickRestore.Add_Click({ Start-HJob 'repair' $JobRepair @{ id = 'restore' } })
$W.BtnQuickRefresh.Add_Click({ Start-Overview })

# ─────────────────────────────────────────────────────────────── Pencere çerçevesi ve klavye
$W.BtnMin.Add_Click({ $win.WindowState = 'Minimized' })
$W.BtnMax.Add_Click({ $win.WindowState = $(if ($win.WindowState -eq 'Maximized') { 'Normal' } else { 'Maximized' }) })
$W.BtnClose.Add_Click({ $win.Close() })
$win.Add_StateChanged({
    if ($win.WindowState -eq 'Maximized') { $W.Root.Margin = '7'; $W.BtnMax.Content = [string][char]0xE923 }
    else { $W.Root.Margin = '0'; $W.BtnMax.Content = [string][char]0xE922 }
})
$win.Add_PreviewKeyDown({
    param($sender, $e)
    if ($W.DialogHost.Visibility -eq 'Visible') {
        if ($e.Key -eq 'Escape') { $S.DlgResult = $S.DlgCancel; $S.DlgFrame.Continue = $false; $e.Handled = $true }
        return
    }
    if ($e.Key -eq 'F' -and [System.Windows.Input.Keyboard]::Modifiers -eq 'Control') { $W.GlobalSearch.Focus() | Out-Null; $W.GlobalSearch.SelectAll(); $e.Handled = $true }
    elseif ($e.Key -eq 'Escape' -and $W.GlobalSearch.IsKeyboardFocused) { $W.GlobalSearch.Text = '' }
})

# ─────────────────────────────────────────────────────────────── Kuyruk işleyici
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(90)
$timer.Add_Tick({
    $item = $null; $k = 0
    while ($k -lt 200 -and $sync.Queue.TryDequeue([ref]$item)) {
        $k++
        switch ($item.t) {
            'log'       { Add-LogLine $item.d.m $item.d.l }
            'progress'  { Set-Progress $item.d.v; if ($item.d.s) { Set-Status $item.d.s 'Warn' } }
            'cleansize' {
                $S.CleanSizes[$item.d.id] = [int64]$item.d.b
                $r = $S.ClRows[$item.d.id]
                if ($r) { $r.sz.Text = Format-HSize $item.d.b; $r.sz.SetResourceReference($DP.TbFg, $(if ($item.d.b -gt 100MB) { 'Acc' } elseif ($item.d.b -gt 0) { 'Txt' } else { 'Dim' })) }
                Update-CleanTotal
            }
            'done'      { Complete-HJob $item.d }
        }
    }
})

# ─────────────────────────────────────────────────────────────── Başlat
$win.Add_SourceInitialized({ Set-DwmAttr 33 2; Set-DwmAttr 20 $(if ($S.Theme -eq 'dark') { 1 } else { 0 }) })
$win.Add_Closing({
    param($sender, $e)
    if ($S.Busy -and ([System.Windows.MessageBox]::Show($win, 'Bir işlem hâlâ sürüyor. Yine de kapatılsın mı? Yarım kalan işlem sorun çıkarabilir.', 'Henox Tweak', 'YesNo', 'Warning') -ne 'Yes')) { $e.Cancel = $true; return }
    $timer.Stop()
    foreach ($j in @($S.Jobs.Values)) { try { $j.ps.Stop(); $j.ps.Dispose(); $j.rs.Close() } catch {} }
})
$win.Add_ContentRendered({
    if (-not $Config) { return }
    try {
        $res = Import-HConfig $Config
        Toast "Ayar dosyası yüklendi: $($res.tweaks.Count + $res.prefs.Count) tweak, $($res.apps.Count) uygulama." 'Info'
        if ($Run) {
            $S.Auto = $true
            Write-HLog "── Otomatik mod: $Config ──" 'head'
            $apps = @($res.apps | ForEach-Object { $a = $S.AppRows[$_].app; @{ id = $a.id; name = $a.name; source = $a.source } })
            $ids = @($res.tweaks + $res.prefs)
            if ($ids.Count) { if ($apps.Count) { $S.AutoApps = $apps }; Show-Page 'Tweaks'; Start-HJob 'tweaks' $JobTweaks @{ ids = $ids; undo = $false; restore = $true } }
            elseif ($apps.Count) { Show-Page 'Apps'; Start-HJob 'winget' $JobWinget @{ mode = 'install'; apps = $apps } }
        }
    } catch { Info ("Ayar dosyası okunamadı:`n" + $_.Exception.Message) 'Otomasyon' 'Err' }
})

# Tema: kayıtlı tercih > Windows teması
$st = Read-Settings
$theme = 'dark'
if ($st -and $st.theme) { $theme = $st.theme }
else { try { if ((Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop).AppsUseLightTheme -eq 1) { $theme = 'light' } } catch {} }
if ($env:HENOX_THEME) { $theme = $env:HENOX_THEME }
Set-Theme $theme -Instant

Build-TweakList; Update-TweakStatus
Build-AppList; Update-AppCount
Build-DebloatList
Build-CleanList
Build-RepairList
$timer.Start()
$start = 'Panel'; if ($env:HENOX_PAGE) { $start = $env:HENOX_PAGE }   # HENOX_PAGE: geliştirme için belirli sekmeyle aç
Show-Page $start
if (-not $isAdmin -and -not $env:HENOX_SHOT) { Toast 'Geliştirici modu: yönetici değilsin, sistem ayarları değiştirilemez.' 'Warn' }
Write-HLog "Henox Tweak $HT_VERSION başlatıldı. Günlük: $($sync.LogFile)" 'dim'
Start-Overview

[void]$win.ShowDialog()
Write-Host '  Henox Tweak kapatıldı. İyi oyunlar!' -ForegroundColor DarkGray
}
