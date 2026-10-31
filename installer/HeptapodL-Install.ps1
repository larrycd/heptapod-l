# =====================================================================
#  HEPTAPOD L STUDIO - INSTALLER 1.1.1 (orthography HL-1.1) - Heptapod L by Larry Dalton
#  Paste the whole script into Windows PowerShell 5.1 (or save as .ps1
#  and run). Everything runs inside one script block, so nothing executes
#  until the full paste has been received.
#
#  What it does:
#   1. Backs up %LOCALAPPDATA%\HeptapodStudio and the Startup shortcut.
#   2. Frees port 8765 ONLY if it is held by a previous Heptapod Studio
#      server. Any other process on 8765 = stop with a clear error.
#      The port is never silently changed.
#   3. Writes server.ps1, hsraster.cs (image decoder, compiled locally by
#      PowerShell) and index.html, recreates HeptapodStudio.lnk.
#   4. Starts the server hidden and verifies: health, image decoder compiled,
#      encode, SVG decode, image decode, engine self-test.
#   5. On any failure: stops the new server, restores the backup and the
#      old shortcut, restarts the previous version, and reports why.
# =====================================================================
& {
$ErrorActionPreference = 'Stop'
$Port = 8765
$AppDir = Join-Path $env:LOCALAPPDATA 'HeptapodStudio'
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$BackupDir = Join-Path $env:LOCALAPPDATA ('HeptapodStudio-backup-' + $Stamp)
$StartupDir = [Environment]::GetFolderPath('Startup')
if (-not $StartupDir) { $StartupDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup' }
$Lnk = Join-Path $StartupDir 'HeptapodStudio.lnk'
$LnkBackup = $null
$PsExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$Log = New-Object System.Collections.Generic.List[string]
$State = @{ StoppedOld = $false }
function Say([string]$m, [string]$c = 'Gray') { Write-Host $m -ForegroundColor $c; $Log.Add($m) }
# Result file for the Windows setup program (ignored when the script is pasted)
$ResultFile = Join-Path $env:TEMP 'HeptapodL-install-result.txt'
function Write-Result([string]$r) { try { Set-Content -Path $ResultFile -Value $r -Encoding ASCII } catch {} }
Write-Result 'RUNNING'

function Get-PortOwner {
    try { $c = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop | Select-Object -First 1; if ($c) { return [int]$c.OwningProcess } } catch {}
    $line = netstat -ano -p TCP | Select-String (':' + $Port + '\s+\S+\s+LISTENING\s+(\d+)')
    if ($line) { return [int]$line[0].Matches[0].Groups[1].Value }
    return $null
}
function Stop-OldStudio {
    $owner = Get-PortOwner
    if ($null -eq $owner) { return $true }
    if ($owner -eq 4) {
        # http.sys (PID 4) holds the port for HttpListener; identify the real process by command line
        $procs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" | Where-Object { $_.CommandLine -match '\\HeptapodStudio\\server\.ps1' -and $_.ProcessId -ne $PID })
        if ($procs.Count -eq 0) {
            Say "Port $Port is reserved by http.sys but no Heptapod Studio process was found." 'Red'; return $false
        }
        foreach ($p in $procs) { Say ('Stopping previous Heptapod Studio server (PID ' + $p.ProcessId + ')'); Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
        $State.StoppedOld = $true
    } else {
        $proc = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $owner)
        if ($null -eq $proc -or $proc.CommandLine -notmatch '\\HeptapodStudio\\server\.ps1') {
            $nm = '?'; if ($proc) { $nm = $proc.Name + ' : ' + $proc.CommandLine }
            Say "Port $Port is in use by another program (PID $owner, $nm)." 'Red'
            Say 'The installer will not stop unrelated software or change the port. Close that program and run again.' 'Red'
            return $false
        }
        Say ('Stopping previous Heptapod Studio server (PID ' + $owner + ')'); Stop-Process -Id $owner -Force; $State.StoppedOld = $true
    }
    for ($i = 0; $i -lt 20; $i++) { Start-Sleep -Milliseconds 500; if ($null -eq (Get-PortOwner)) { return $true } }
    Say "Port $Port did not become free." 'Red'; return $false
}
function Start-Studio([string]$dir) {
    $argStr = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $dir 'server.ps1') + '" -Port ' + $Port + ' -Root "' + $dir + '"'
    Start-Process -FilePath $PsExe -ArgumentList $argStr -WindowStyle Hidden | Out-Null
}
function New-Shortcut([string]$dir) {
    $sh = New-Object -ComObject WScript.Shell
    $s = $sh.CreateShortcut($Lnk)
    $s.TargetPath = $PsExe
    $s.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $dir 'server.ps1') + '" -Port ' + $Port + ' -Root "' + $dir + '"'
    $s.WorkingDirectory = $dir; $s.WindowStyle = 7; $s.Description = 'Heptapod L Studio local server'
    $s.Save()
}
function Invoke-Api([string]$path, $body, [int]$timeout = 60) {
    # Direct HTTP to localhost with no proxy (corporate proxy settings must not intercept the check)
    $req = [System.Net.WebRequest]::Create("http://localhost:$Port$path")
    $req.Proxy = $null; $req.Timeout = $timeout * 1000; $req.ReadWriteTimeout = $timeout * 1000
    if ($null -ne $body) {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Compress -Depth 5))
        $req.Method = 'POST'; $req.ContentType = 'application/json; charset=utf-8'; $req.ContentLength = $bytes.Length
        $st = $req.GetRequestStream(); $st.Write($bytes, 0, $bytes.Length); $st.Close()
    }
    $resp = $req.GetResponse()
    try { $sr = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8); $txt = $sr.ReadToEnd() } finally { $resp.Close() }
    return ($txt | ConvertFrom-Json)
}

$ServerSource = @'
# =====================================================================
#  HEPTAPOD L STUDIO  -  server.ps1   (Heptapod L, a circular script by Larry Dalton)
#  Engine version 1.1.1   |   Orthography HL-1.1
#  Windows PowerShell 5.1 compatible. Local only. No AI, no internet.
# =====================================================================
#  ORTHOGRAPHY HL-1.1 (summary - full rules in /api/spec)
#  * A GLYPH is one algorithmic tendril grown from the sentence ring.
#    Its identity is 4 independent geometric features:
#       D  direction  : outward / inward            (2)
#       C  curl       : clockwise / anticlockwise   (2)
#       B  barbs      : 0 / 1 / 2 side branches     (3)
#       L  length     : short / medium / long       (3)
#    giving 36 glyph values. 26 are letters; 2 are shift codes
#    (SPECIAL, ESCAPE); 8 are reserved.
#  * A UNIT is a fused cluster of glyphs sharing one ink mass:
#       letter = 1 glyph, dicast = 2, tricast = 3 (fixed reading order
#       clockwise), special = SHIFT + index, escape = ESC + 4 base-36
#       digits of the Unicode code point.
#    Unit identity = glyph count + ordered glyph values, so every one of
#    the 18,278 letter units has a distinct morphology. Angle is NOT
#    used for identity (the theta formulas collide: theta2(a,A)=theta1(a)).
#  * SENTENCE = one logogram. Origin = canonical start angle of the first
#    unit (theta1/theta2/theta3 or the special register) and is marked by
#    a long two-sided START BAR. Units run clockwise from it.
#  * WORD BOUNDARY = a short two-sided BOUNDARY BAR plus a break in the ring.
#  * Long sentences continue on further concentric bands (outward),
#    each band read clockwise from the same origin angle.
#  * Structural layer = <path> elements. Pigment (ink masses, splatter,
#    hairlines, droplets, bleed) = circle/ellipse/polyline/use and SVG
#    filters; it never carries meaning and the decoder ignores it.
#  * Segmentation per letter run: tricasts left to right, remainder as a
#    dicast (2) or letter (1). Segmentation is recoverable from glyph count.
#  * Normalisation: upper case; runs of spaces/tabs = one boundary;
#    line breaks are encoded as a special; sentences split after . ? ! ...
# =====================================================================
param(
    [int]$Port = 8765,
    [string]$Root = $PSScriptRoot,
    [switch]$SelfTest,
    [switch]$FullInventory
)

$ErrorActionPreference = 'Stop'
$script:Version = '1.1.1'
$script:Ortho = 'HL-1.1'; $script:LangName = 'Heptapod L'
$script:Inv = [System.Globalization.CultureInfo]::InvariantCulture

# ------------------------------- constants ---------------------------
$script:C = @{
    R0 = 240.0; BandStep = 220.0; Margin = 150.0
    NPri = 18; NBarb = 8
    Len = @(40.0, 64.0, 92.0)
    PriW = 13.0; BarbLen = 27.0; BarbW = 7.0
    InClusterPx = 32.0; ClusterGapPx = 60.0; WordGapPx = 84.0
    PadStart = 40.0; PadEnd = 40.0
    StartBar = 34.0; BoundBar = 20.0
    GroupPx = 53.0; ConvergePx = 46.0
}
$script:Alpha = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
$script:LetterV = New-Object int[] 26
$script:VLetter = @{}
for ($a = 0; $a -lt 26; $a++) { $v = (7 * $a + 3) % 36; $script:LetterV[$a] = $v; $script:VLetter[$v] = $a }
$script:Unused = @(); for ($v = 0; $v -lt 36; $v++) { if (-not $script:VLetter.ContainsKey($v)) { $script:Unused += $v } }
$script:VShift = $script:Unused[0]; $script:VEsc = $script:Unused[1]

$script:Specials = @('0','1','2','3','4','5','6','7','8','9','.',',','?','!',';',':','"',"'",'(',')','@','-','/','&',
    [string][char]0x2026, [string][char]0x2013, [string][char]0x2014, "`n", '#','$','%','*','+','=','_','~')
$script:SpecialNames = @('digit 0','digit 1','digit 2','digit 3','digit 4','digit 5','digit 6','digit 7','digit 8','digit 9',
    'full stop','comma','question mark','exclamation mark','semicolon','colon','double quote','apostrophe','open parenthesis','close parenthesis',
    'at sign','hyphen','slash','ampersand','ellipsis','en dash','em dash','line break','hash','dollar','percent','asterisk','plus','equals','underscore','tilde')
$script:SpecialAngle = New-Object double[] 36
for ($i = 0; $i -lt 10; $i++) { $script:SpecialAngle[$i] = 347.0 + 0.25 * $i }
$fixed = @{ 10 = 358.0; 11 = 359.0; 12 = 359.5; 13 = 359.75; 14 = 359.1; 15 = 359.3; 16 = 359.2; 17 = 359.4; 18 = 350.0; 19 = 352.0; 20 = 354.0 }
foreach ($k in $fixed.Keys) { $script:SpecialAngle[$k] = $fixed[$k] }
for ($i = 21; $i -lt 36; $i++) { $script:SpecialAngle[$i] = 355.0 + 0.2 * ($i - 21) }
$script:EscAngle = 357.95
$script:SpecialIdx = @{}
for ($i = 0; $i -lt 36; $i++) { $script:SpecialIdx[$script:Specials[$i]] = $i }

# ------------------------------- helpers -----------------------------
function F([double]$x) { return $x.ToString('0.0', $script:Inv) }
function F2([double]$x) { return $x.ToString('0.00', $script:Inv) }
function Rad([double]$d) { return $d * [math]::PI / 180.0 }
function Norm360([double]$d) { $r = $d % 360.0; if ($r -lt 0) { $r += 360.0 }; return $r }

function Get-Features([int]$v) {
    $d = [math]::Floor($v / 18); $r = $v % 18
    $c = [math]::Floor($r / 9); $r = $r % 9
    $b = [math]::Floor($r / 3); $l = $r % 3
    return @{ D = [int]$d; C = [int]$c; B = [int]$b; L = [int]$l }
}
function Get-ValueFromFeatures($d, $c, $b, $l) { return [int](18 * $d + 9 * $c + 3 * $b + $l) }

function Get-Hash([string]$s) {
    [long]$h = 2166136261
    foreach ($ch in $s.ToCharArray()) { $h = $h -bxor [long][int]$ch; $h = ($h * 16777619) % 4294967296 }
    return $h
}
function New-Rng([long]$seed) { return @{ S = ($seed % 2147483647) + 1 } }
function Next-Rnd($rng) { $rng.S = ($rng.S * 48271) % 2147483647; return $rng.S / 2147483647.0 }

function Get-UnitAngle([string]$kind, [int[]]$vals, [string]$text) {
    switch ($kind) {
        'L' { return 360.0 * ($script:Alpha.IndexOf($text[0])) / 26.0 }
        'D' { $a = $script:Alpha.IndexOf($text[0]); $b = $script:Alpha.IndexOf($text[1]); return 360.0 * (26 * $a + $b) / 676.0 }
        'T' { $a = $script:Alpha.IndexOf($text[0]); $b = $script:Alpha.IndexOf($text[1]); $c = $script:Alpha.IndexOf($text[2]); return 360.0 * (676 * $a + 26 * $b + $c) / 17576.0 }
        'S' { return $script:SpecialAngle[$vals[1]] }
        default { return $script:EscAngle }
    }
}

# ------------------------------- orthographic encoder ----------------
function New-LetterUnit([string]$run) {
    $vals = @(); foreach ($ch in $run.ToCharArray()) { $vals += $script:LetterV[$script:Alpha.IndexOf($ch)] }
    $kind = @('L', 'D', 'T')[$run.Length - 1]
    return @{ Kind = $kind; Text = $run; Values = [int[]]$vals; Angle = (Get-UnitAngle $kind $vals $run) }
}
function New-CharUnit([int]$cp) {
    $s = [char]::ConvertFromUtf32($cp)
    if ($script:SpecialIdx.ContainsKey($s)) {
        $idx = $script:SpecialIdx[$s]; $vals = [int[]]@($script:VShift, $idx)
        return @{ Kind = 'S'; Text = $s; Values = $vals; Angle = $script:SpecialAngle[$idx] }
    }
    $d = @(); $n = $cp; for ($i = 0; $i -lt 4; $i++) { $d = @($n % 36) + $d; $n = [math]::Floor($n / 36) }
    $vals = [int[]](@($script:VEsc) + $d)
    return @{ Kind = 'E'; Text = $s; Values = $vals; Angle = $script:EscAngle }
}
function Split-LetterRun([string]$run) {
    $out = @(); $i = 0
    while ($run.Length - $i -ge 3) { $out += $run.Substring($i, 3); $i += 3 }
    if ($i -lt $run.Length) { $out += $run.Substring($i) }
    return , $out
}
function ConvertTo-NormalText([string]$text) {
    if ($null -eq $text) { $text = '' }
    $t = $text -replace "`r`n", "`n" -replace "`r", "`n" -replace "`t", ' '
    $t = $t.ToUpperInvariant()
    $t = [regex]::Replace($t, ' +', ' ')
    $t = [regex]::Replace($t, ' *\n *', "`n")
    return $t.Trim()
}
function Split-Sentences([string]$norm) {
    if ($norm.Length -eq 0) { return , @() }
    $parts = [regex]::Split($norm, '(?<=[\.\?\!' + [char]0x2026 + '])[ \n]+')
    $out = @(); foreach ($p in $parts) { if ($p.Trim().Length -gt 0) { $out += $p.Trim() } }
    return , $out
}
function Get-SentenceUnits([string]$sentence) {
    # returns list of words; each word = list of units
    $words = @()
    foreach ($w in ($sentence -split ' ')) {
        if ($w.Length -eq 0) { continue }
        $units = @(); $run = ''
        $i = 0
        while ($i -lt $w.Length) {
            $ch = $w[$i]
            if ($ch -ge 'A' -and $ch -le 'Z') { $run += $ch; $i++; continue }
            if ($run.Length -gt 0) { foreach ($chunk in (Split-LetterRun $run)) { $units += , (New-LetterUnit $chunk) }; $run = '' }
            if ([char]::IsHighSurrogate($ch) -and ($i + 1) -lt $w.Length) { $cp = [char]::ConvertToUtf32($ch, $w[$i + 1]); $i += 2 }
            else { $cp = [int]$ch; $i++ }
            $units += , (New-CharUnit $cp)
        }
        if ($run.Length -gt 0) { foreach ($chunk in (Split-LetterRun $run)) { $units += , (New-LetterUnit $chunk) } }
        $words += , $units
    }
    return , $words
}

# ------------------------------- glyph geometry ----------------------
function Get-Frame([double]$thDeg) {
    $t = Rad $thDeg
    return @{ ux = [math]::Sin($t); uy = - [math]::Cos($t); vx = [math]::Cos($t); vy = [math]::Sin($t) }
}
function Get-PolarPt([double]$cx, [double]$cy, [double]$r, [double]$thDeg) {
    $t = Rad $thDeg; return @(($cx + $r * [math]::Sin($t)), ($cy - $r * [math]::Cos($t)))
}
function Get-PrimaryCenterline([double]$x0, [double]$y0, [double]$thDeg, $f) {
    $n = $script:C.NPri; $len = $script:C.Len[$f.L]
    $d = 1.0; if ($f.D -eq 1) { $d = -1.0 }
    $c = 1.0; if ($f.C -eq 1) { $c = -1.0 }
    $fr = Get-Frame $thDeg
    $xs = New-Object double[] $n; $ys = New-Object double[] $n
    for ($i = 0; $i -lt $n; $i++) {
        $t = $i / ($n - 1.0)
        $a = $t - 0.25 * $t * $t
        $b = 0.5 * [math]::Pow($t, 2.2)
        $xs[$i] = $x0 + $fr.ux * $d * $len * $a + $fr.vx * $c * $len * $b
        $ys[$i] = $y0 + $fr.uy * $d * $len * $a + $fr.vy * $c * $len * $b
    }
    return @{ X = $xs; Y = $ys }
}
function Get-TaperPolygon($cl, [double]$w0, [double]$swell) {
    $xs = $cl.X; $ys = $cl.Y; $n = $xs.Length
    $L = New-Object 'System.Collections.Generic.List[double[]]'
    $Rr = New-Object 'System.Collections.Generic.List[double[]]'
    for ($i = 0; $i -lt $n; $i++) {
        $i0 = [math]::Max(0, $i - 1); $i1 = [math]::Min($n - 1, $i + 1)
        $dx = $xs[$i1] - $xs[$i0]; $dy = $ys[$i1] - $ys[$i0]; $m = [math]::Sqrt($dx * $dx + $dy * $dy); if ($m -eq 0) { $m = 1 }
        $nx = - $dy / $m; $ny = $dx / $m
        $t = $i / ($n - 1.0)
        $w = $w0 * [math]::Pow(1 - $t, 0.9) * (1 + $swell * [math]::Sin([math]::PI * $t))
        $L.Add(@(($xs[$i] + $nx * $w / 2), ($ys[$i] + $ny * $w / 2)))
        $Rr.Add(@(($xs[$i] - $nx * $w / 2), ($ys[$i] - $ny * $w / 2)))
    }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('M' + (F $L[0][0]) + ' ' + (F $L[0][1]))
    for ($i = 1; $i -lt $n; $i++) { [void]$sb.Append(' L' + (F $L[$i][0]) + ' ' + (F $L[$i][1])) }
    for ($i = $n - 1; $i -ge 0; $i--) { [void]$sb.Append(' L' + (F $Rr[$i][0]) + ' ' + (F $Rr[$i][1])) }
    [void]$sb.Append(' Z')
    return $sb.ToString()
}
function Get-BarbCenterline($pcl, [int]$k, [int]$side) {
    $xs = $pcl.X; $ys = $pcl.Y
    $dx = $xs[$k + 1] - $xs[$k - 1]; $dy = $ys[$k + 1] - $ys[$k - 1]; $m = [math]::Sqrt($dx * $dx + $dy * $dy)
    $tx = $dx / $m; $ty = $dy / $m
    $ang = 50.0 * [math]::PI / 180.0 * $side
    $bx = $tx * [math]::Cos($ang) - $ty * [math]::Sin($ang); $by = $tx * [math]::Sin($ang) + $ty * [math]::Cos($ang)
    $px = - $by * $side; $py = $bx * $side
    $n = $script:C.NBarb
    $X = New-Object double[] $n; $Y = New-Object double[] $n
    for ($i = 0; $i -lt $n; $i++) {
        $t = $i / ($n - 1.0)
        $X[$i] = $xs[$k] + $bx * $script:C.BarbLen * $t + $px * 4.0 * $t * $t
        $Y[$i] = $ys[$k] + $by * $script:C.BarbLen * $t + $py * 4.0 * $t * $t
    }
    return @{ X = $X; Y = $Y }
}
function Get-GlyphPaths([double]$cx, [double]$cy, [double]$R, [double]$thDeg, [int]$v) {
    $f = Get-Features $v
    $p0 = Get-PolarPt $cx $cy $R $thDeg
    $cl = Get-PrimaryCenterline $p0[0] $p0[1] $thDeg $f
    $paths = @((Get-TaperPolygon $cl $script:C.PriW 0.35))
    $side = 1; if ($f.C -eq 0) { $side = -1 }
    $ks = @(); if ($f.B -eq 1) { $ks = @(11) } elseif ($f.B -eq 2) { $ks = @(7, 14) }
    foreach ($k in $ks) { $paths += (Get-TaperPolygon (Get-BarbCenterline $cl $k $side) $script:C.BarbW 0.1) }
    return @{ Paths = $paths; Tip = @($cl.X[$cl.X.Length - 1], $cl.Y[$cl.Y.Length - 1]); Feat = $f }
}
function Get-BarPath([double]$cx, [double]$cy, [double]$R, [double]$thDeg, [double]$half, [double]$w) {
    $n = 10; $fr = Get-Frame $thDeg
    $L = @(); $Rr = @()
    for ($i = 0; $i -lt $n; $i++) {
        $t = $i / ($n - 1.0); $rad = $R - $half + 2 * $half * $t
        $ww = 2.0 + ($w - 2.0) * [math]::Sin([math]::PI * $t)
        $p = Get-PolarPt $cx $cy $rad $thDeg
        $L += , @(($p[0] + $fr.vx * $ww / 2), ($p[1] + $fr.vy * $ww / 2))
        $Rr += , @(($p[0] - $fr.vx * $ww / 2), ($p[1] - $fr.vy * $ww / 2))
    }
    $s = 'M' + (F $L[0][0]) + ' ' + (F $L[0][1])
    for ($i = 1; $i -lt $n; $i++) { $s += ' L' + (F $L[$i][0]) + ' ' + (F $L[$i][1]) }
    for ($i = $n - 1; $i -ge 0; $i--) { $s += ' L' + (F $Rr[$i][0]) + ' ' + (F $Rr[$i][1]) }
    return $s + ' Z'
}
function Get-RingPath([double]$cx, [double]$cy, [double]$R, [double]$a0, [double]$a1, [double[]]$bumps, [long]$seed) {
    $arc = (Rad ($a1 - $a0)) * $R
    $n = [math]::Max(8, [int]($arc / 4.0))
    $outer = New-Object System.Text.StringBuilder; $inner = @()
    for ($i = 0; $i -le $n; $i++) {
        $t = $i / [double]$n; $th = $a0 + ($a1 - $a0) * $t
        $sPx = $arc * $t; $ePx = $arc - $sPx
        $taper = [math]::Min(1.0, [math]::Min($sPx / 22.0, $ePx / 30.0)); $taper = [math]::Max(0.18, $taper)
        $w = 7.0 + 1.5 * [math]::Sin($th * 0.11 + $seed % 7) + 1.0 * [math]::Sin($th * 0.37 + $seed % 5)
        foreach ($bt in $bumps) { $dd = (Rad ([math]::Abs($th - $bt))) * $R; $w += 6.0 * [math]::Exp( - ($dd * $dd) / 900.0) }
        $w = [math]::Min(15.0, $w) * $taper
        $po = Get-PolarPt $cx $cy ($R + $w / 2) $th; $pi_ = Get-PolarPt $cx $cy ($R - $w / 2) $th
        if ($i -eq 0) { [void]$outer.Append('M' + (F $po[0]) + ' ' + (F $po[1])) } else { [void]$outer.Append(' L' + (F $po[0]) + ' ' + (F $po[1])) }
        $inner += , $pi_
    }
    for ($i = $inner.Count - 1; $i -ge 0; $i--) { [void]$outer.Append(' L' + (F $inner[$i][0]) + ' ' + (F $inner[$i][1])) }
    [void]$outer.Append(' Z')
    return $outer.ToString()
}

# ------------------------------- sentence composer -------------------
# Glyph offsets inside a unit: 32 px apart, 46 px when two neighbours on the same side
# of the ring curl towards each other (prevents crossings that would hide barbs).
function Get-GlyphOffsets([int[]]$vals) {
    $o = New-Object double[] $vals.Length; $acc = 0.0
    for ($g = 1; $g -lt $vals.Length; $g++) {
        $a = Get-Features $vals[$g - 1]; $b = Get-Features $vals[$g]
        $sp = $script:C.InClusterPx
        if ($a.D -eq $b.D -and $a.C -eq 0 -and $b.C -eq 1) { $sp = $script:C.ConvergePx }
        $acc += $sp; $o[$g] = $acc
    }
    return , $o
}

function Build-Layout($words) {
    $C = $script:C
    $items = @(); $wi = 0
    foreach ($w in $words) { $first = $true; foreach ($u in $w) { $items += , @{ Unit = $u; Word = $wi; NewWord = ($first -and $wi -gt 0) }; $first = $false }; $wi++ }
    $bands = @(); $cur = @(); $used = 0.0; $k = 0
    foreach ($it in $items) {
        $R = $C.R0 + $C.BandStep * $k
        $cap = 2 * [math]::PI * $R - $C.PadStart - $C.PadEnd
        $offs = Get-GlyphOffsets $it.Unit.Values; $wpx = $offs[$offs.Length - 1]
        $gap = 0.0; if ($cur.Count -gt 0) { if ($it.NewWord) { $gap = $C.WordGapPx } else { $gap = $C.ClusterGapPx } }
        if ($cur.Count -gt 0 -and ($used + $gap + $wpx) -gt $cap) {
            $bands += , @{ Items = $cur; R = $R; Used = $used }; $cur = @(); $used = 0.0; $k++; $gap = 0.0
        }
        $it.Gap = $gap; $it.W = $wpx; $cur += , $it; $used += $gap + $wpx
    }
    if ($cur.Count -gt 0) { $bands += , @{ Items = $cur; R = ($C.R0 + $C.BandStep * $k); Used = $used } }
    # spread units around each band
    foreach ($b in $bands) {
        $cap = 2 * [math]::PI * $b.R - $C.PadStart - $C.PadEnd
        $closing = $C.ClusterGapPx
        $gapSum = $closing; foreach ($it in $b.Items) { $gapSum += $it.Gap }
        $extra = $cap - $b.Used - $closing
        $scale = 1.0; if ($gapSum -gt 0) { $scale = 1.0 + $extra / $gapSum }
        $pos = $C.PadStart
        foreach ($it in $b.Items) { $pos += $it.Gap * $scale; $it.Pos = $pos; $pos += $it.W }
    }
    return , $bands
}

function Get-InkSvg($sentenceText, $words, [string]$theme) {
    $C = $script:C
    $bands = Build-Layout $words
    $first = $words[0][0]
    $th0 = $first.Angle
    $Rmax = $bands[$bands.Count - 1].R
    $size = 2 * ($Rmax + $C.Margin); $cx = $size / 2; $cy = $size / 2
    $rng = New-Rng (Get-Hash $sentenceText)
    $ink = '#f3f1ea'; $bg = '#07090c'
    if ($theme -eq 'paper') { $ink = '#121212'; $bg = '#efe9dc' }
    $struct = New-Object System.Text.StringBuilder
    $pig = New-Object System.Text.StringBuilder
    $unitsOut = @()
    # start bar
    [void]$struct.Append('<path d="' + (Get-BarPath $cx $cy $C.R0 $th0 $C.StartBar 11.0) + '"/>')
    $wash = New-Object System.Text.StringBuilder
    $ps0 = Get-PolarPt $cx $cy $C.R0 $th0
    [void]$pig.Append('<ellipse cx="' + (F $ps0[0]) + '" cy="' + (F $ps0[1]) + '" rx="20" ry="11" transform="rotate(' + (F2 $th0) + ' ' + (F $ps0[0]) + ' ' + (F $ps0[1]) + ')" fill="url(#mass)"/>')
    $bi = 0
    foreach ($b in $bands) {
        $R = $b.R; $its = $b.Items
        $deg = 180.0 / ([math]::PI * $R)   # degrees per px
        $bounds = @(); $bumps = @()
        for ($j = 0; $j -lt $its.Count; $j++) {
            $it = $its[$j]; $u = $it.Unit; $n = $u.Values.Length
            $cAng = @(); $goffs = Get-GlyphOffsets $u.Values
            for ($g = 0; $g -lt $n; $g++) {
                $th = $th0 + ($it.Pos + $goffs[$g]) * $deg
                $cAng += $th
                $gp = Get-GlyphPaths $cx $cy $R $th $u.Values[$g]
                foreach ($p in $gp.Paths) { [void]$struct.Append('<path d="' + $p + '"/>') }
                $tr = 1.6 + 1.6 * (Next-Rnd $rng)
                [void]$pig.Append('<circle cx="' + (F $gp.Tip[0]) + '" cy="' + (F $gp.Tip[1]) + '" r="' + (F $tr) + '"/>')
            }
            $mid = ($cAng[0] + $cAng[$n - 1]) / 2.0; $bumps += $mid
            # ink masses (fusion body): asymmetric overlapping pools, skewed clockwise
            $rx = $goffs[$n - 1] / 2 + 16
            $nm = 2 + $n
            for ($m = 0; $m -lt $nm; $m++) {
                $off = ((Next-Rnd $rng) - 0.3) * $rx * 1.3
                $pm = Get-PolarPt $cx $cy ($R + ((Next-Rnd $rng) - 0.5) * 8) ($mid + $off * $deg)
                $erx = $rx * (0.45 + 0.6 * (Next-Rnd $rng)); $ery = 7 + 3 * $n * (0.5 + (Next-Rnd $rng))
                [void]$pig.Append('<ellipse cx="' + (F $pm[0]) + '" cy="' + (F $pm[1]) + '" rx="' + (F $erx) + '" ry="' + (F $ery) + '" transform="rotate(' + (F2 ($mid + $off * $deg + ((Next-Rnd $rng) - 0.5) * 14)) + ' ' + (F $pm[0]) + ' ' + (F $pm[1]) + ')" fill="url(#mass)" stroke="none" opacity="' + (F2 (0.55 + 0.45 * (Next-Rnd $rng))) + '"/>')
            }
            # wash: broad blurred brush sweep through the unit
            $pts = @(); $wa = $mid - ($rx + 30) * $deg; $wb = $mid + ($rx + 70 + 40 * (Next-Rnd $rng)) * $deg
            for ($q = 0; $q -le 16; $q++) { $t = $q / 16.0; $pp = Get-PolarPt $cx $cy ($R + 4 * [math]::Sin($t * 3.1 + $n)) ($wa + ($wb - $wa) * $t); $pts += ((F $pp[0]) + ',' + (F $pp[1])) }
            [void]$wash.Append('<polyline points="' + ($pts -join ' ') + '" fill="none" stroke-width="' + (F (12 + 6 * $n)) + '" stroke-linecap="round" opacity="0.4"/>')
            # splatter
            $ns = 8 + 6 * $n
            for ($s = 0; $s -lt $ns; $s++) {
                $a = $mid + ((Next-Rnd $rng) - 0.5) * ($rx * 3.0) * $deg
                $rr = $R + ((Next-Rnd $rng) - 0.5) * (40 + 22 * $n)
                $ps = Get-PolarPt $cx $cy $rr $a
                [void]$pig.Append('<circle cx="' + (F $ps[0]) + '" cy="' + (F $ps[1]) + '" r="' + (F (0.5 + 2.2 * [math]::Pow((Next-Rnd $rng), 2.5))) + '" stroke="none" opacity="' + (F2 (0.35 + 0.6 * (Next-Rnd $rng))) + '"/>')
            }
            # hairline tendrils with droplets
            $nh = 5 + 3 * $n
            for ($h = 0; $h -lt $nh; $h++) {
                $a = $mid + ((Next-Rnd $rng) - 0.5) * $rx * 1.8 * $deg
                $dir = 1; if ((Next-Rnd $rng) -lt 0.5) { $dir = -1 }
                $hl = 25 + 75 * [math]::Pow((Next-Rnd $rng), 1.5); $sw = ((Next-Rnd $rng) - 0.5) * 110
                $pts = @(); $pp = $null
                for ($q = 0; $q -le 8; $q++) { $t = $q / 8.0; $pp = Get-PolarPt $cx $cy ($R + $dir * $hl * $t) ($a + $sw * $t * $t * $deg); $pts += ((F $pp[0]) + ',' + (F $pp[1])) }
                [void]$pig.Append('<polyline points="' + ($pts -join ' ') + '" fill="none" stroke-width="' + (F2 (0.4 + 0.9 * (Next-Rnd $rng))) + '" opacity="' + (F2 (0.35 + 0.4 * (Next-Rnd $rng))) + '"/>')
                if ((Next-Rnd $rng) -lt 0.6) { [void]$pig.Append('<circle cx="' + (F $pp[0]) + '" cy="' + (F $pp[1]) + '" r="' + (F (1 + 2.2 * (Next-Rnd $rng))) + '" stroke="none"/>') }
            }
            $unitsOut += , [ordered]@{ text = $u.Text; type = (Get-KindName $u.Kind); band = $bi; angle = [math]::Round((Norm360 $cAng[0]), 3); canonicalStart = [math]::Round($u.Angle, 4); glyphs = @($u.Values) }
            # boundary to next unit
            $nextNew = $false; $nextPos = $null
            if ($j + 1 -lt $its.Count) { $nextNew = $its[$j + 1].NewWord; $nextPos = $its[$j + 1].Pos }
            elseif ($bi + 1 -lt $bands.Count) { $nextNew = $bands[$bi + 1].Items[0].NewWord; $nextPos = 2 * [math]::PI * $R }
            if ($nextNew) {
                $endPx = $it.Pos + $it.W
                $bp = ($endPx + $nextPos) / 2.0; $bounds += $bp
                [void]$struct.Append('<path d="' + (Get-BarPath $cx $cy $R ($th0 + $bp * $deg) $C.BoundBar 7.0) + '"/>')
            }
        }
        # ring segments
        $delims = @(8.0); foreach ($bp in $bounds) { $delims += ($bp - 10.0); $delims += ($bp + 10.0) }
        $delims += (2 * [math]::PI * $R - 14.0)
        for ($q = 0; $q -lt $delims.Count; $q += 2) {
            $s0 = $delims[$q]; $s1 = $delims[$q + 1]
            if (($s1 - $s0) -lt 44) { continue }
            [void]$struct.Append('<path d="' + (Get-RingPath $cx $cy $R ($th0 + $s0 * $deg) ($th0 + $s1 * $deg) $bumps (Get-Hash $sentenceText)) + '"/>')
        }
        # tangential hair strands circling the band (calligraphic overlap)
        $nst = 10 + 2 * $its.Count
        for ($q = 0; $q -lt $nst; $q++) {
            $a0 = $th0 + 360 * (Next-Rnd $rng); $span = 25 + 110 * (Next-Rnd $rng); $dr = ((Next-Rnd $rng) - 0.5) * 22; $dr2 = ((Next-Rnd $rng) - 0.5) * 30
            $pts = @(); for ($z = 0; $z -le 24; $z++) { $t = $z / 24.0; $pp = Get-PolarPt $cx $cy ($R + $dr + $dr2 * $t * $t) ($a0 + $span * $t); $pts += ((F $pp[0]) + ',' + (F $pp[1])) }
            [void]$pig.Append('<polyline points="' + ($pts -join ' ') + '" fill="none" stroke-width="' + (F2 (0.4 + 1.3 * (Next-Rnd $rng))) + '" opacity="' + (F2 (0.25 + 0.45 * (Next-Rnd $rng))) + '"/>')
        }
        $bi++
    }
    $meta = '{"engine":"' + $script:Version + '","orthography":"' + $script:Ortho + '","text":"' + ($sentenceText -replace '\\', '\\' -replace '"', '\"' -replace "`n", '\n' -replace '&', '&amp;' -replace '<', '&lt;') + '"}'
    $seed = (Get-Hash $sentenceText) % 999
    $sz = F $size
    $svg = '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 ' + $sz + ' ' + $sz + '" width="' + $sz + '" height="' + $sz + '">' +
    '<metadata id="hs-provenance">' + $meta + '</metadata>' +
    '<defs><radialGradient id="mass"><stop offset="0" stop-color="' + $ink + '" stop-opacity="0.95"/><stop offset="0.55" stop-color="' + $ink + '" stop-opacity="0.55"/><stop offset="1" stop-color="' + $ink + '" stop-opacity="0"/></radialGradient>' +
    '<filter id="rough" x="-10%" y="-10%" width="120%" height="120%"><feTurbulence type="fractalNoise" baseFrequency="0.045" numOctaves="3" seed="' + $seed + '"/><feDisplacementMap in="SourceGraphic" scale="4.5"/></filter>' +
    '<filter id="bleed" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="5"/></filter>' +
    '<filter id="mist" x="-20%" y="-20%" width="140%" height="140%"><feTurbulence type="fractalNoise" baseFrequency="0.09" numOctaves="2" seed="' + $seed + '" result="n"/><feDisplacementMap in="SourceGraphic" in2="n" scale="9"/><feGaussianBlur stdDeviation="0.6"/></filter></defs>' +
    '<rect width="100%" height="100%" fill="' + $bg + '"/>' +
    '<g id="hs-pigment-layer" opacity="0.55">' +
    '<use xlink:href="#hs-structure" filter="url(#bleed)" opacity="0.7"/>' +
    '<g id="hs-wash" fill="none" stroke="' + $ink + '" filter="url(#bleed)" >' + $wash.ToString() + '</g>' +
    '<g id="hs-pigment" fill="' + $ink + '" stroke="' + $ink + '" filter="url(#mist)">' + $pig.ToString() + '</g></g>' +
    '<g id="hs-structure" fill="' + $ink + '" filter="url(#rough)">' + $struct.ToString() + '</g></svg>'
    return @{ Svg = $svg; Units = $unitsOut; Bands = $bands.Count; Start = $th0 }
}
function Get-KindName([string]$k) {
    switch ($k) { 'L' { 'letter' } 'D' { 'dicast' } 'T' { 'tricast' } 'S' { 'special' } default { 'escape' } }
}

# ------------------------------- semantic interpreter ----------------
function Get-Semantics([string]$s) {
    $ws = @(); foreach ($m in [regex]::Matches($s, "[A-Z']+")) { $ws += $m.Value }
    $res = [ordered]@{ mood = 'statement'; intent = 'unresolved'; roles = [ordered]@{}; features = @() }
    if ($s.EndsWith('?')) { $res.mood = 'question' } elseif ($s.EndsWith('!')) { $res.mood = 'exclamation' }
    elseif ($ws.Count -gt 0 -and @('WHAT','WHO','WHERE','WHEN','WHY','HOW','WHICH','IS','ARE','DO','DOES','CAN','WILL') -contains $ws[0]) { $res.mood = 'question' }
    $j = ' ' + ($ws -join ' ') + ' '
    if ($j -match ' WHAT IS YOUR NAME ') { $res.intent = 'request identity'; $res.roles.subject = 'addressee'; $res.roles.attribute = 'name' }
    elseif ($j -match ' WHO ARE YOU ') { $res.intent = 'request identity'; $res.roles.subject = 'addressee' }
    elseif ($j -match " MY NAME IS ([A-Z']+) ") { $res.intent = 'declare identity'; $res.roles.subject = 'speaker'; $res.roles.attribute = 'name'; $res.roles.value = $Matches[1] }
    elseif ($j -match " I AM ([A-Z']+) ") { $res.intent = 'declare identity'; $res.roles.subject = 'speaker'; $res.roles.value = $Matches[1] }
    else {
        $verbs = @('IS','ARE','AM','WAS','WERE','HAS','HAVE','KNOW','KNOWS','SEEK','SEEKS','WANT','WANTS','SEE','SEES','GIVE','GIVES','LOVE','LOVES','NEED','NEEDS','MAKE','MAKES','OFFER','OFFERS','USE','USES','COME','COMES','SPEAK','SPEAKS')
        $vi = -1; for ($i = 0; $i -lt $ws.Count; $i++) { if ($verbs -contains $ws[$i]) { $vi = $i; break } }
        if ($vi -lt 0 -and $ws.Count -eq 3 -and $ws[1].EndsWith('S')) { $vi = 1 }
        if ($vi -gt 0) {
            $res.intent = 'predication'
            $res.roles.agent = ($ws[0..($vi - 1)] -join ' ')
            $res.roles.predicate = $ws[$vi]
            if ($vi + 1 -lt $ws.Count) { $res.roles.patient = ($ws[($vi + 1)..($ws.Count - 1)] -join ' ') }
            if (@('IS','ARE','AM','WAS','WERE') -contains $ws[$vi]) { $res.intent = 'classification / attribution' }
        }
    }
    foreach ($w in $ws) {
        if (@('NOT','NO','NEVER',"DON'T","DOESN'T","ISN'T","CAN'T","WON'T") -contains $w) { $res.features += 'negation' }
        if (@('MY','YOUR','HIS','HER','THEIR','OUR','ITS') -contains $w -or $w.EndsWith("'S")) { $res.features += 'possession' }
        if (@('YESTERDAY','TODAY','TOMORROW','NOW','THEN','BEFORE','AFTER','WILL','WAS','WERE') -contains $w) { $res.features += 'temporal' }
        if (@('AND','BUT','OR','BECAUSE','WHILE') -contains $w) { $res.features += 'compound clause' }
    }
    $res.features = @($res.features | Select-Object -Unique)
    return $res
}

# ------------------------------- encode API --------------------------
function Invoke-Encode([string]$text, [string]$theme) {
    $norm = ConvertTo-NormalText $text
    $sentences = Split-Sentences $norm
    $out = @()
    foreach ($s in $sentences) {
        $words = Get-SentenceUnits $s
        $r = Get-InkSvg $s $words $theme
        $ortho = @(); foreach ($w in $words) { $t = @(); foreach ($u in $w) { $t += $u.Text }; $ortho += ($t -join '|') }
        $out += , [ordered]@{
            text = $s; startAngle = [math]::Round($r.Start, 4); firstUnit = $words[0][0].Text; firstUnitType = (Get-KindName $words[0][0].Kind)
            bands = $r.Bands; wordCount = $words.Count; unitCount = $r.Units.Count
            orthographic = ($ortho -join ' / '); units = $r.Units; semantic = (Get-Semantics $s); svg = $r.Svg
        }
    }
    return [ordered]@{ status = 'ok'; engine = $script:Version; orthography = $script:Ortho; normalised = $norm; sentences = $out }
}

# ------------------------------- geometric decoder -------------------
function Get-ExpectedLengths {
    $res = @()
    foreach ($L in 0, 1, 2) {
        $cl = Get-PrimaryCenterline 0 0 0 @{ D = 0; C = 0; B = 0; L = $L }
        $res += (Get-PolyLength $cl.X $cl.Y)
    }
    return , $res
}
function Get-PolyLength($X, $Y) { $s = 0.0; for ($i = 1; $i -lt $X.Count; $i++) { $dx = $X[$i] - $X[$i - 1]; $dy = $Y[$i] - $Y[$i - 1]; $s += [math]::Sqrt($dx * $dx + $dy * $dy) }; return $s }
function Get-SegDist($px, $py, $X, $Y) {
    $best = 1e9
    for ($i = 1; $i -lt $X.Count; $i++) {
        $ax = $X[$i - 1]; $ay = $Y[$i - 1]; $bx = $X[$i]; $by = $Y[$i]
        $dx = $bx - $ax; $dy = $by - $ay; $l2 = $dx * $dx + $dy * $dy
        $t = 0.0; if ($l2 -gt 0) { $t = (($px - $ax) * $dx + ($py - $ay) * $dy) / $l2; $t = [math]::Max(0, [math]::Min(1, $t)) }
        $qx = $ax + $t * $dx - $px; $qy = $ay + $t * $dy - $py; $d = [math]::Sqrt($qx * $qx + $qy * $qy)
        if ($d -lt $best) { $best = $d }
    }
    return $best
}
function New-DecodeResult([string]$status, [string]$reason) {
    return [ordered]@{ status = $status; method = 'geometric'; reason = $reason; text = $null; confidence = 0; units = @(); boundaries = @(); unresolved = @(); checks = [ordered]@{} }
}
function Invoke-Decode([string]$svgText) {
    $C = $script:C
    try { $xml = New-Object System.Xml.XmlDocument; $xml.XmlResolver = $null; $xml.LoadXml($svgText) } catch { return (New-DecodeResult 'failed' 'Not a readable SVG/XML document.') }
    $rootEl = $xml.DocumentElement
    if ($rootEl.LocalName -ne 'svg') { return (New-DecodeResult 'failed' 'Document is not SVG.') }
    $vb = $rootEl.GetAttribute('viewBox')
    $nums = @(); foreach ($m in [regex]::Matches($vb, '-?[0-9]*\.?[0-9]+')) { $nums += [double]::Parse($m.Value, $script:Inv) }
    if ($nums.Count -ne 4) { return (New-DecodeResult 'unresolved' 'SVG has no usable viewBox; centre cannot be established.') }
    $cx = $nums[0] + $nums[2] / 2; $cy = $nums[1] + $nums[3] / 2
    $pathNodes = $xml.SelectNodes("//*[local-name()='path']")
    $polys = @(); $foreign = 0
    foreach ($pn in $pathNodes) {
        $d = $pn.GetAttribute('d')
        if ($d -match '[^MLZmlz0-9\.\-\s,eE]') { $foreign++; continue }
        $vals = @(); foreach ($m in [regex]::Matches($d, '-?[0-9]*\.?[0-9]+(?:[eE]-?[0-9]+)?')) { $vals += [double]::Parse($m.Value, $script:Inv) }
        if ($vals.Count -lt 6 -or ($vals.Count % 2) -ne 0) { $foreign++; continue }
        $n = $vals.Count / 2; $X = New-Object double[] $n; $Y = New-Object double[] $n
        $Rr = New-Object double[] $n; $Th = New-Object double[] $n
        for ($i = 0; $i -lt $n; $i++) {
            $X[$i] = $vals[2 * $i]; $Y[$i] = $vals[2 * $i + 1]
            $dx = $X[$i] - $cx; $dy = $Y[$i] - $cy
            $Rr[$i] = [math]::Sqrt($dx * $dx + $dy * $dy); $Th[$i] = Norm360 ([math]::Atan2($dx, - $dy) * 180 / [math]::PI)
        }
        $polys += , @{ X = $X; Y = $Y; R = $Rr; T = $Th; N = $n }
    }
    if ($polys.Count -eq 0) { return (New-DecodeResult 'unresolved' ('No native Heptapod L structural paths found (' + $foreign + ' foreign path(s)). This SVG is not in the native format.')) }
    # angular span helper (handles wrap)
    function Get-Span($T) { $s = @($T | Sort-Object); $maxGap = 0.0; for ($i = 1; $i -lt $s.Count; $i++) { $g = $s[$i] - $s[$i - 1]; if ($g -gt $maxGap) { $maxGap = $g } }; $wrap = 360 - $s[$s.Count - 1] + $s[0]; if ($wrap -gt $maxGap) { $maxGap = $wrap }; return 360 - $maxGap }
    # 1. rings -> band radii
    $rings = @(); $other = @()
    foreach ($p in $polys) {
        $rmin = ($p.R | Measure-Object -Minimum).Minimum; $rmax = ($p.R | Measure-Object -Maximum).Maximum
        $p.Rmin = $rmin; $p.Rmax = $rmax; $p.Span = Get-Span $p.T
        $rmean = ($p.R | Measure-Object -Average).Average; $p.Rmean = $rmean
        if (($rmax - $rmin) -lt 22 -and (Rad $p.Span) * $rmean -gt 40) { $rings += $p } else { $other += $p }
    }
    if ($rings.Count -eq 0) { return (New-DecodeResult 'unresolved' 'No sentence ring detected.') }
    $bandR = @()
    foreach ($rg in ($rings | Sort-Object { $_.Rmean })) { $hit = $false; for ($i = 0; $i -lt $bandR.Count; $i++) { if ([math]::Abs($bandR[$i] - $rg.Rmean) -lt 20) { $hit = $true } }; if (-not $hit) { $bandR += $rg.Rmean } }
    function Get-Band($r) { $bi = -1; $bd = 1e9; for ($i = 0; $i -lt $bandR.Count; $i++) { $dd = [math]::Abs($r - $bandR[$i]); if ($dd -lt $bd) { $bd = $dd; $bi = $i } }; return @($bi, $bd) }
    # 2. bars, primaries, barbs
    $bars = @(); $tend = @()
    foreach ($p in $other) {
        $bb = Get-Band (($p.Rmin + $p.Rmax) / 2); $Rb = $bandR[$bb[0]]
        if ($p.Rmin -lt ($Rb - 12) -and $p.Rmax -gt ($Rb + 12) -and (Rad $p.Span) * $Rb -lt 15) {
            $len = $p.Rmax - $p.Rmin
            $kind = 'boundary'; if ($len -gt 54) { $kind = 'start' }
            $mx = ($p.X | Measure-Object -Average).Average - $cx; $my = ($p.Y | Measure-Object -Average).Average - $cy
            $bars += @{ Kind = $kind; Band = $bb[0]; Angle = (Norm360 ([math]::Atan2($mx, - $my) * 180 / [math]::PI)); Len = $len }
            continue
        }
        if (($p.N % 2) -ne 0) { continue }
        $h = $p.N / 2; $X = New-Object double[] $h; $Y = New-Object double[] $h
        for ($i = 0; $i -lt $h; $i++) { $X[$i] = ($p.X[$i] + $p.X[$p.N - 1 - $i]) / 2; $Y[$i] = ($p.Y[$i] + $p.Y[$p.N - 1 - $i]) / 2 }
        $tend += @{ X = $X; Y = $Y; Len = (Get-PolyLength $X $Y) }
    }
    $starts = @($bars | Where-Object { $_.Kind -eq 'start' })
    if ($starts.Count -ne 1) { return (New-DecodeResult 'unresolved' ('Expected exactly one start bar, found ' + $starts.Count + '.')) }
    $th0 = $starts[0].Angle
    $exp = Get-ExpectedLengths
    $t1 = ($exp[0] + $exp[1]) / 2; $t2 = ($exp[1] + $exp[2]) / 2
    $prims = @(); $barbs = @()
    foreach ($t in $tend) {
        $dx = $t.X[0] - $cx; $dy = $t.Y[0] - $cy; $r0 = [math]::Sqrt($dx * $dx + $dy * $dy)
        $bb = Get-Band $r0
        if ($bb[1] -lt 6 -and $t.Len -gt 30) { $t.Band = $bb[0]; $t.R0 = $r0; $t.Theta = Norm360 ([math]::Atan2($dx, - $dy) * 180 / [math]::PI); $prims += $t } else { $barbs += $t }
    }
    foreach ($pr in $prims) { $pr.Barbs = 0 }
    $orphan = 0
    foreach ($bt in $barbs) {
        $best = $null; $bd = 1e9
        foreach ($pr in $prims) { $dd = Get-SegDist $bt.X[0] $bt.Y[0] $pr.X $pr.Y; if ($dd -lt $bd) { $bd = $dd; $best = $pr } }
        if ($bd -lt 3 -and $null -ne $best) { $best.Barbs++ } else { $orphan++ }
    }
    # 3. glyph features
    $minConf = 1.0
    foreach ($pr in $prims) {
        $n = $pr.X.Length; $fr = Get-Frame $pr.Theta
        $ex = $pr.X[$n - 1] - $pr.X[0]; $ey = $pr.Y[$n - 1] - $pr.Y[0]
        $radial = $ex * $fr.ux + $ey * $fr.uy; $lat = $ex * $fr.vx + $ey * $fr.vy
        $fD = 0; if ($radial -lt 0) { $fD = 1 }
        $fC = 0; if ($lat -lt 0) { $fC = 1 }
        $fL = 0; if ($pr.Len -gt $t2) { $fL = 2 } elseif ($pr.Len -gt $t1) { $fL = 1 }
        $fB = [math]::Min(2, $pr.Barbs)
        $pr.V = Get-ValueFromFeatures $fD $fC $fB $fL
        $marg = [math]::Min([math]::Abs($pr.Len - $t1), [math]::Abs($pr.Len - $t2)) / (($t2 - $t1) / 2)
        $conf = [math]::Min(1.0, $marg) * [math]::Min(1.0, [math]::Abs($lat) / 6.0) * [math]::Max(0.0, 1 - $pr.R0 / 1e4)
        if ($pr.Barbs -gt 2) { $conf = $conf * 0.3 }
        if ($conf -lt $minConf) { $minConf = $conf }
        $pr.Off = Norm360 ($pr.Theta - $th0)
    }
    $prov = $null; $hasProv = $false
    $mnode = $xml.SelectSingleNode("//*[local-name()='metadata']")
    if ($null -ne $mnode) { try { $mj = $mnode.InnerText | ConvertFrom-Json; $prov = $mj.text; $hasProv = $true } catch {} }
    $res = Complete-Decode $prims $bars $bandR $th0 $minConf 'geometric' $hasProv $prov
    $res.checks.orphanBarbs = $orphan; $res.checks.foreignPaths = $foreign
    if ($orphan -gt 0 -and $res.status -eq 'ok') { $res.status = 'partial'; $res.reason = 'Some structure could not be resolved; see unresolved/checks.' }
    return $res
}

function Complete-Decode($prims, $bars, $bandR, [double]$th0, [double]$minConf, [string]$method, [bool]$hasProv, $prov) {
    $C = $script:C
    # 4. sequence by band then clockwise offset; group clusters and boundaries
    $events = @()
    foreach ($pr in $prims) { $events += @{ Type = 'g'; Band = $pr.Band; Off = $pr.Off; P = $pr } }
    foreach ($br in ($bars | Where-Object { $_.Kind -eq 'boundary' })) { $events += @{ Type = 'b'; Band = $br.Band; Off = (Norm360 ($br.Angle - $th0)) } }
    $events = @($events | Sort-Object @{ Expression = { $_.Band } }, @{ Expression = { $_.Off } })
    $clusters = @(); $cur = $null; $wordIdx = 0; $prevBand = -1; $prevOff = 0.0
    foreach ($e in $events) {
        if ($e.Type -eq 'b') { if ($null -ne $cur) { $clusters += , $cur; $cur = $null }; $wordIdx++; continue }
        $R = $C.R0 + $C.BandStep * $e.Band   # nominal radius: gap test is scale-independent
        $gapPx = 1e9; if ($e.Band -eq $prevBand) { $gapPx = (Rad ($e.Off - $prevOff)) * $R }
        if ($null -eq $cur -or $gapPx -gt $C.GroupPx) { if ($null -ne $cur) { $clusters += , $cur }; $cur = @{ Word = $wordIdx; Vals = @(); Off = $e.Off; Band = $e.Band } }
        $cur.Vals += $e.P.V; $prevBand = $e.Band; $prevOff = $e.Off
    }
    if ($null -ne $cur) { $clusters += , $cur }
    # 5. clusters -> units
    $res = New-DecodeResult 'ok' ''
    $res.method = $method
    $words = @{}; $unitsOut = @(); $unres = @()
    foreach ($cl in $clusters) {
        $v = $cl.Vals; $txt = $null; $kind = $null
        $allLetters = $true; foreach ($x in $v) { if (-not $script:VLetter.ContainsKey($x)) { $allLetters = $false } }
        if ($allLetters -and $v.Count -le 3) { $txt = ''; foreach ($x in $v) { $txt += $script:Alpha[$script:VLetter[$x]] }; $kind = @('L', 'D', 'T')[$v.Count - 1] }
        elseif ($v[0] -eq $script:VShift -and $v.Count -eq 2) { $txt = $script:Specials[$v[1]]; $kind = 'S' }
        elseif ($v[0] -eq $script:VEsc -and $v.Count -eq 5) { $cp = 0; for ($i = 1; $i -lt 5; $i++) { $cp = $cp * 36 + $v[$i] }; if ($cp -le 0x10FFFF) { $txt = [char]::ConvertFromUtf32($cp); $kind = 'E' } }
        if ($null -eq $txt) { $unres += [ordered]@{ band = $cl.Band; offset = [math]::Round($cl.Off, 2); glyphs = @($v); reason = 'glyph sequence does not form a valid unit' }; $txt = [string][char]0xFFFD; $kind = '?' }
        if (-not $words.ContainsKey($cl.Word)) { $words[$cl.Word] = '' }
        $words[$cl.Word] += $txt
        $unitsOut += , [ordered]@{ text = $txt; type = (Get-KindName $kind); band = $cl.Band; offset = [math]::Round($cl.Off, 3); glyphs = @($v); word = $cl.Word }
    }
    $wt = @(); foreach ($k in ($words.Keys | Sort-Object)) { $wt += $words[$k] }
    $res.text = ($wt -join ' ')
    $res.units = $unitsOut; $res.unresolved = $unres
    $res.startAngle = [math]::Round($th0, 3)
    $res.bands = $bandR.Count; $res.wordCount = $wt.Count
    $res.boundaries = @($bars | Where-Object { $_.Kind -eq 'boundary' }).Count
    $res.confidence = [math]::Round($minConf, 3)
    # checks
    if ($unitsOut.Count -gt 0 -and $unitsOut[0].type -ne '?') {
        $u0 = $unitsOut[0]; $k0 = @{ letter = 'L'; dicast = 'D'; tricast = 'T'; special = 'S'; escape = 'E' }[$u0.type]
        $expA = Get-UnitAngle $k0 ([int[]]$u0.glyphs) $u0.text
        $dev = [math]::Abs((Norm360 ($th0 - $expA + 180)) - 180)
        $res.checks.startAngleExpected = [math]::Round($expA, 4)
        $res.checks.startAngleDeviation = [math]::Round($dev, 4)
        $tol = 0.5; if ($method -eq 'raster') { $tol = 1.5 }
        $res.checks.startAngleConsistent = ($dev -lt $tol)
    }
    if ($hasProv) { $res.checks.provenanceText = $prov; $res.checks.provenanceMatch = ($prov -eq $res.text) } else { $res.checks.provenanceMatch = $null }
    if ($unres.Count -gt 0 -or -not $res.checks.startAngleConsistent) { $res.status = 'partial'; $res.reason = 'Some structure could not be resolved; see unresolved/checks.' }
    return $res
}

# ------------------------------- raster decoder ----------------------
$script:RasterReady = $false; $script:RasterError = 'not loaded'
function Initialize-Raster {
    if ($script:RasterReady) { return }
    try {
        if (-not ('HsRaster' -as [type])) {
            $src = [System.IO.File]::ReadAllText((Join-Path $Root 'hsraster.cs'))
            Add-Type -TypeDefinition $src -Language CSharp
        }
        $script:RasterReady = $true; $script:RasterError = $null
    } catch { $script:RasterError = $_.Exception.Message }
}
function Invoke-RasterDecode([byte[]]$gray, [int]$w, [int]$h) {
    Initialize-Raster
    if (-not $script:RasterReady) { $d = New-DecodeResult 'failed' ('Raster engine could not be compiled: ' + $script:RasterError); $d.method = 'raster'; return $d }
    if ($null -eq $gray -or $gray.Length -ne ($w * $h)) { $d = New-DecodeResult 'failed' 'Pixel data does not match the stated width and height.'; $d.method = 'raster'; return $d }
    $r = [HsRaster]::Analyze($gray, $w, $h)
    $info = [ordered]@{ width = $r.Width; height = $r.Height; darkBackground = $r.DarkBackground; centreX = [math]::Round($r.Cx, 1); centreY = [math]::Round($r.Cy, 1); scale = [math]::Round($r.Scale, 4); bandRadii = @($r.BandR | ForEach-Object { [math]::Round($_, 1) }); glyphsDetected = $r.Glyphs.Count; barsDetected = $r.Bars.Count }
    if (-not $r.Ok) { $d = New-DecodeResult 'unresolved' $r.Reason; $d.method = 'raster'; $d.checks.raster = $info; return $d }
    $starts = @($r.Bars | Where-Object { $_.IsStart } | Sort-Object Strength -Descending)
    if ($starts.Count -eq 0 -or $r.Glyphs.Count -eq 0) {
        $d = New-DecodeResult 'unresolved' ('A ring was found but no Heptapod L start bar' + $(if ($r.Glyphs.Count -eq 0) { ' or glyphs' } else { '' }) + ' could be identified. The image is not a native Heptapod L logogram, or it is too degraded. No translation is attempted.')
        $d.method = 'raster'; $d.checks.raster = $info; return $d
    }
    $fits = @($r.Glyphs | ForEach-Object { $_.PrimaryScore } | Sort-Object)
    $medFit = $fits[[int][math]::Floor($fits.Count / 2)]
    $info.medianShapeFit = [math]::Round($medFit, 3)
    if ($medFit -lt 0.55) {
        $d = New-DecodeResult 'unresolved' ('Strokes were found but they do not match Heptapod L glyph shapes (median shape fit ' + [math]::Round($medFit, 2) + '; native logograms score about 0.8-0.9). The image is not a native Heptapod L logogram, or it is too degraded. No translation is attempted.')
        $d.method = 'raster'; $d.checks.raster = $info; return $d
    }
    $th0 = $starts[0].Angle
    $prims = @(); $minConf = 1.0; $low = @()
    foreach ($g in $r.Glyphs) {
        $prims += , @{ Band = $g.Band; Off = (Norm360 ($g.Angle - $th0)); V = $g.Value }
        if ($g.Confidence -lt $minConf) { $minConf = $g.Confidence }
        if ($g.Confidence -lt 0.3) { $low += , [ordered]@{ band = $g.Band; offset = [math]::Round((Norm360 ($g.Angle - $th0)), 2); bestValue = $g.Value; confidence = [math]::Round($g.Confidence, 3); reason = 'glyph shape fits more than one reading' } }
    }
    $bars = @(); foreach ($b in $r.Bars) { if (-not $b.IsStart) { $bars += , @{ Kind = 'boundary'; Band = $b.Band; Angle = $b.Angle } } }
    if ($starts.Count -gt 1) { foreach ($b in $starts[1..($starts.Count - 1)]) { $low += , [ordered]@{ band = $b.Band; offset = [math]::Round((Norm360 ($b.Angle - $th0)), 2); reason = 'second start-like bar ignored' } } }
    $res = Complete-Decode $prims $bars $r.BandR $th0 $minConf 'raster' $false $null
    $res.checks.raster = $info
    $notes = @(); foreach ($u in $r.Unresolved) { if ($u -match 'ignored stroke fragment') { $notes += $u } else { $low += , [ordered]@{ reason = $u } } }
    $res.notes = $notes
    if ($low.Count -gt 0) { $res.unresolved = @($res.unresolved) + $low; if ($res.status -eq 'ok') { $res.status = 'partial'; $res.reason = 'Text recovered, but some glyphs are uncertain; see unresolved.' } }
    return $res
}
function Get-GrayFromImageBytes([byte[]]$bytes) {
    Initialize-Raster
    Add-Type -AssemblyName System.Drawing
    $ms = New-Object System.IO.MemoryStream(, $bytes)
    $bmp = New-Object System.Drawing.Bitmap($ms)
    try {
        $rect = New-Object System.Drawing.Rectangle(0, 0, $bmp.Width, $bmp.Height)
        $bd = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
        $buf = New-Object byte[] ($bd.Stride * $bmp.Height)
        [System.Runtime.InteropServices.Marshal]::Copy($bd.Scan0, $buf, 0, $buf.Length)
        $bmp.UnlockBits($bd)
        return @{ Gray = [HsRaster]::BgrToGray($buf, $bmp.Width, $bmp.Height, $bd.Stride, 3); W = $bmp.Width; H = $bmp.Height }
    } finally { $bmp.Dispose(); $ms.Dispose() }
}
function Invoke-ImageBytesDecode([byte[]]$bytes) {
    try { $g = Get-GrayFromImageBytes $bytes } catch { $d = New-DecodeResult 'failed' ('The image could not be opened on the server (' + $_.Exception.Message + '). Use the web interface, which reads PNG/JPEG in the browser.'); $d.method = 'raster'; return $d }
    return (Invoke-RasterDecode $g.Gray $g.W $g.H)
}
function Invoke-DecodeRequest($body) {
    if ($body.svg) { return (Invoke-Decode ([string]$body.svg)) }
    if ($body.image) {
        $b64 = [string]$body.image; $k = $b64.IndexOf(','); if ($k -ge 0) { $b64 = $b64.Substring($k + 1) }
        return (Invoke-ImageBytesDecode ([Convert]::FromBase64String($b64)))
    }
    return (New-DecodeResult 'failed' 'No svg or image supplied.')
}
function Get-SvgPolygons([string]$svgText) {
    $xml = New-Object System.Xml.XmlDocument; $xml.XmlResolver = $null; $xml.LoadXml($svgText)
    $list = New-Object 'System.Collections.Generic.List[double[]]'
    foreach ($pn in $xml.SelectNodes("//*[local-name()='path']")) {
        $vals = New-Object 'System.Collections.Generic.List[double]'
        foreach ($m in [regex]::Matches($pn.GetAttribute('d'), '-?[0-9]*\.?[0-9]+')) { $vals.Add([double]::Parse($m.Value, $script:Inv)) }
        $list.Add($vals.ToArray())
    }
    $vb = $xml.DocumentElement.GetAttribute('viewBox').Split(' ')
    return @{ Polys = $list; Size = [double]::Parse($vb[2], $script:Inv) }
}
function Test-RasterRoundTrip([string]$text, [double]$scale, [bool]$dark, [int]$seed) {
    Initialize-Raster
    $enc = Invoke-Encode $text 'dark'; $s = $enc.sentences[0]
    $g = Get-SvgPolygons $s.svg
    $w = [int][math]::Round($g.Size * $scale)
    $gray = [HsRaster]::RenderPolygons($g.Polys, $w, $w, $scale, $dark, $seed)
    $d = Invoke-RasterDecode $gray $w $w
    return [ordered]@{ input = $s.text; scale = $scale; dark = $dark; decoded = $d.text; status = $d.status; confidence = $d.confidence; pass = ($d.text -ceq $s.text) }
}

# ------------------------------- registry & glyph API ----------------
function Get-UnitDefinition([string]$id) {
    $id = [uri]::UnescapeDataString($id)
    $u = $null
    if ($id -match '^[A-Za-z]{1,3}$') { $u = New-LetterUnit $id.ToUpperInvariant() }
    elseif ($id -match '^U\+([0-9A-Fa-f]{1,6})$') { $u = New-CharUnit ([Convert]::ToInt32($Matches[1], 16)) }
    elseif ($id.Length -ge 1) { $cp = [char]::ConvertToUtf32($id, 0); $u = New-CharUnit $cp }
    if ($null -eq $u) { return [ordered]@{ status = 'failed'; reason = 'Unknown unit id.' } }
    $glyphs = @()
    foreach ($v in $u.Values) {
        $f = Get-Features $v
        $role = 'letter'; if ($v -eq $script:VShift) { $role = 'shift:special' } elseif ($v -eq $script:VEsc) { $role = 'shift:escape' } elseif (-not $script:VLetter.ContainsKey($v)) { $role = 'index digit' }
        if ($script:VLetter.ContainsKey($v) -and $u.Kind -match '[LDT]') { $role = 'letter ' + $script:Alpha[$script:VLetter[$v]] }
        $glyphs += , [ordered]@{ value = $v; role = $role; direction = @('outward', 'inward')[$f.D]; curl = @('clockwise', 'anticlockwise')[$f.C]; barbs = $f.B; length = @('short', 'medium', 'long')[$f.L]; lengthPx = $script:C.Len[$f.L] }
    }
    $words = , @(, $u)
    $svg = (Get-InkSvg ($u.Text) $words 'dark').Svg
    return [ordered]@{ status = 'ok'; id = $id; type = (Get-KindName $u.Kind); text = $u.Text; canonicalStart = [math]::Round($u.Angle, 4); glyphCount = $u.Values.Length
        entryAnchor = 'ring centreline at unit start angle'; exitAnchor = 'ring centreline after last glyph (+26px per glyph)'; terminalTaper = 'primary width 10px -> 0 at tip'
        glyphs = $glyphs; orthography = $script:Ortho; svg = $svg }
}
function Get-Registry {
    $letters = @(); for ($a = 0; $a -lt 26; $a++) { $f = Get-Features $script:LetterV[$a]; $letters += , [ordered]@{ letter = [string]$script:Alpha[$a]; value = $script:LetterV[$a]; start = [math]::Round(360.0 * $a / 26, 4); D = $f.D; C = $f.C; B = $f.B; L = $f.L } }
    $sp = @(); for ($i = 0; $i -lt 36; $i++) { $sp += , [ordered]@{ index = $i; char = $script:Specials[$i]; name = $script:SpecialNames[$i]; start = $script:SpecialAngle[$i] } }
    return [ordered]@{ status = 'ok'; engine = $script:Version; orthography = $script:Ortho; counts = [ordered]@{ letters = 26; dicasts = 676; tricasts = 17576; lexicalUnits = 18278; specials = 36; escape = 'any Unicode code point' }
        glyphValues = 36; shiftSpecial = $script:VShift; shiftEscape = $script:VEsc; reserved = @($script:Unused[2..($script:Unused.Count - 1)]); letters = $letters; specials = $sp }
}

# ------------------------------- validation --------------------------
$script:MandatorySentences = @('LARRY', 'HUMAN', 'HUMANITY', 'LARRY KNOWS IAN', 'IAN KNOWS LARRY', 'MY NAME IS LARRY', 'WHAT IS YOUR NAME?', 'HUMANITY SEEKS PEACE.',
    "Larry's e-mail: larry@jjswaste.com.au (test #42) - done!", ([string][char]0x00C9 + 'COLE ' + [char]::ConvertFromUtf32(0x1F600) + ' CAF' + [char]0x00C9),
    'THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG WHILE THE HEPTAPODS WATCH FROM THE SHELL AND WRITE ONE LONG CIRCULAR SENTENCE ABOUT TIME LANGUAGE AND MEMORY WITHOUT END')
function Test-RoundTrip([string]$text) {
    $enc = Invoke-Encode $text 'dark'
    $dec = @(); $ok = $true; $detail = @()
    foreach ($s in $enc.sentences) {
        $d = Invoke-Decode $s.svg
        $pass = ($d.status -eq 'ok' -and $d.text -ceq $s.text -and $d.checks.startAngleConsistent)
        if (-not $pass) { $ok = $false }
        $dec += $d.text
        $detail += , [ordered]@{ expected = $s.text; decoded = $d.text; status = $d.status; startAngle = $s.startAngle; decodedStart = $d.startAngle; bands = $s.bands; confidence = $d.confidence; pass = $pass }
    }
    return [ordered]@{ input = $text; normalised = $enc.normalised; decoded = ($dec -join ' '); pass = ($ok -and (($dec -join ' ') -ceq ($enc.normalised -replace "(?<=[\.\?\!" + [char]0x2026 + "])[ \n]+", ' '))); sentences = $detail }
}
function Invoke-Validate([bool]$full, [bool]$smoke = $false, $prog = $null) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    if ($null -ne $prog) { $prog.phase = 'sentences'; $prog.done = 0; $prog.total = $script:MandatorySentences.Count }
    $results = @(); foreach ($t in $script:MandatorySentences) { if ($null -ne $prog -and $prog.cancel) { break }; $results += , (Test-RoundTrip $t); if ($null -ne $prog) { $prog.done++ } }
    # letter-register uniqueness
    $sig = @{}; $collide = 0
    foreach ($a in 0..25) { $k = [string]$script:LetterV[$a]; if ($sig.ContainsKey($k)) { $collide++ }; $sig[$k] = 1 }
    # unit inventory: every unit as its own word, batched 12 per sentence
    $inv = [ordered]@{ tested = 0; failed = 0; failures = @() }
    $ids = New-Object System.Collections.Generic.List[string]
    foreach ($a in $script:Alpha.ToCharArray()) { $ids.Add([string]$a) }
    foreach ($a in $script:Alpha.ToCharArray()) { foreach ($b in $script:Alpha.ToCharArray()) { $ids.Add([string]$a + $b) } }
    if ($full) { foreach ($a in $script:Alpha.ToCharArray()) { foreach ($b in $script:Alpha.ToCharArray()) { foreach ($c in $script:Alpha.ToCharArray()) { $ids.Add([string]$a + $b + $c) } } } }
    else { $rng = New-Rng 12345; for ($i = 0; $i -lt 300; $i++) { $s = ''; for ($j = 0; $j -lt 3; $j++) { $s += $script:Alpha[[int][math]::Floor((Next-Rnd $rng) * 26)] }; $ids.Add($s) } }
    foreach ($ch in $script:Specials) { if ($ch -ne "`n") { $ids.Add('A' + $ch) } }
    if ($smoke) { $ids.Clear() }
    $batch = 12
    if ($null -ne $prog) { $prog.phase = 'units'; $prog.done = 0; $prog.total = $ids.Count }
    for ($i = 0; $i -lt $ids.Count; $i += $batch) {
        if ($null -ne $prog -and $prog.cancel) { break }
        $chunk = @(); for ($j = $i; $j -lt [math]::Min($ids.Count, $i + $batch); $j++) { $chunk += $ids[$j] }
        $s = $chunk -join ' '
        $words = Get-SentenceUnits $s
        $svg = (Get-InkSvg $s $words 'dark').Svg
        $d = Invoke-Decode $svg
        $inv.tested += $chunk.Count
        if ($null -ne $prog) { $prog.done = $inv.tested; if ($prog.cancel) { break } }
        if ($d.text -cne $s -or $d.status -ne 'ok') { $inv.failed += $chunk.Count; if ($inv.failures.Count -lt 10) { $inv.failures += , [ordered]@{ expected = $s; decoded = $d.text; status = $d.status } } }
    }
    # raster round trips (synthetic rasters of the structural layer, two scales/themes)
    $raster = @()
    if (-not ($null -ne $prog -and $prog.cancel)) {
        Initialize-Raster
        $rs = @($script:MandatorySentences[0..8]); if ($smoke) { $rs = @('LARRY', 'WHAT IS YOUR NAME?') }
        if ($null -ne $prog) { $prog.phase = 'images'; $prog.done = 0; $prog.total = $rs.Count * 2 }
        foreach ($t in $rs) {
            foreach ($cfg in @(@(1.0, $true), @(0.7, $false))) {
                if ($null -ne $prog -and $prog.cancel) { break }
                if ($script:RasterReady) { $raster += , (Test-RasterRoundTrip $t $cfg[0] $cfg[1] 11) } else { $raster += , [ordered]@{ input = $t; pass = $false; status = 'failed'; decoded = $script:RasterError } }
                if ($null -ne $prog) { $prog.done++ }
            }
        }
    }
    $sw.Stop()
    $rasterFail = @($raster | Where-Object { -not $_.pass }).Count
    $allPass = (@($results | Where-Object { -not $_.pass }).Count -eq 0) -and $inv.failed -eq 0 -and $collide -eq 0 -and $rasterFail -eq 0
    return [ordered]@{ status = @('failed', 'ok')[[int]$allPass]; engine = $script:Version; scope = $(if ($smoke) { 'smoke (mandatory sentences only)' } elseif ($full) { 'full inventory (18,278 units + specials)' } else { 'quick (26 letters, 676 dicasts, 300 sampled tricasts, specials)' })
        letterValueCollisions = $collide; sentences = $results; inventory = $inv; images = $raster; rasterEngine = $(if ($script:RasterReady) { 'ready' } else { $script:RasterError }); seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1) }
}

function Get-SpecText {
    return @"
HEPTAPOD L - a circular script by Larry Dalton`nORTHOGRAPHY $($script:Ortho) - engine $($script:Version)
GLYPH = one tendril grown from the sentence ring. Four features: direction (out/in), curl (clockwise/anticlockwise),
  barbs (0, 1 at stem point 11/17, 2 at points 7/17 and 14/17; 27 px long), length (40/64/92 px). 36 values = 18D + 9C + 3B + L.
LETTER a (A=0..Z=25) -> value (7a+3) mod 36. Shift SPECIAL = $($script:VShift), ESCAPE = $($script:VEsc); 8 values reserved.
UNIT = glyphs fused on one ink mass, read clockwise: letter 1, dicast 2, tricast 3; special = [SHIFT, index]; escape = [ESC, 4 base-36 digits].
  Glyphs in a unit are 32 px apart, or 46 px when two neighbours on the same side curl towards each other (prevents crossings).
  Units are >= 60 px apart. Decoders group glyphs closer than 53 px.
WORD BOUNDARY = 40 px two-sided boundary bar and a break in the ring.
SENTENCE ORIGIN = canonical start of the first unit, marked by a 68 px two-sided start bar. Reading is clockwise.
CANONICAL STARTS: letter 360a/26; dicast 360(26a+b)/676; tricast 360(676a+26b+c)/17576; specials per registry.
  Angles are orientation only. Identity comes from shape, so angle collisions (e.g. A, AA, AAA all at 0 deg) are harmless.
BANDS: radius 240 + 220k px; overflow continues on the next band outward from the same origin.
LAYERS: structural strokes are <path> elements drawn at full ink. All pigment (masses, wash, splatter, hairlines, bleed)
  sits in one group capped at 55% opacity, so a raster threshold at 68% ink separates structure from pigment.
SEGMENTATION: letter runs split into tricasts left to right; remainder dicast or letter. Recoverable from glyph counts.
NORMALISATION: upper case; space/tab runs collapse; CR/LF -> line-break special; sentences split after . ? ! and ellipsis.
DECODING: native SVG - exact geometry of the structural paths.
  PNG/JPEG - ring and centre fit, base detection on rows at 13 px either side of the ring, bars by symmetric stubs,
  then every glyph is matched against all 18 shapes for its side (overlap scoring), refined so neighbours do not share ink.
  Images whose strokes do not match the glyph shapes are reported unresolved; no translation is invented.
"@
}


# ------------------------------- self-test mode ----------------------
if ($env:HS_NOMAIN) { return }
if ($SelfTest) {
    $v = Invoke-Validate ([bool]$FullInventory)
    $v | ConvertTo-Json -Depth 8
    if ($v.status -eq 'ok') { exit 0 } else { exit 1 }
}

# ------------------------------- background self-test ---------------
# Runs in its own runspace so encoding/decoding stay responsive.
$script:ST = [hashtable]::Synchronized(@{ state = 'idle'; phase = ''; done = 0; total = 0; scope = ''; result = $null; error = $null; started = $null; cancel = $false })
$script:STPs = $null
function Start-SelfTest([string]$scope) {
    if ($script:ST.state -eq 'running') { return [ordered]@{ status = 'busy'; reason = 'A self-test is already running.' } }
    if ($null -ne $script:STPs) { try { $script:STPs.Dispose() } catch {} }
    $script:ST.state = 'running'; $script:ST.scope = $scope; $script:ST.done = 0; $script:ST.total = 0; $script:ST.phase = 'starting'
    $script:ST.result = $null; $script:ST.error = $null; $script:ST.cancel = $false; $script:ST.started = (Get-Date).ToString('s')
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript({
        param($path, $scope, $st)
        try {
            $env:HS_NOMAIN = '1'
            . $path
            $r = Invoke-Validate ($scope -eq 'full') $false $st
            if ($st.cancel) { $r.status = 'cancelled' }
            $st.result = ($r | ConvertTo-Json -Depth 10 -Compress); $st.state = 'done'
        } catch { $st.error = $_.Exception.Message; $st.state = 'error' }
    })
    [void]$ps.AddArgument($script:ServerPath); [void]$ps.AddArgument($scope); [void]$ps.AddArgument($script:ST)
    [void]$ps.BeginInvoke(); $script:STPs = $ps
    return [ordered]@{ status = 'started'; scope = $scope }
}
function Get-SelfTestStatus {
    $o = [ordered]@{ state = $script:ST.state; scope = $script:ST.scope; phase = $script:ST.phase; done = $script:ST.done; total = $script:ST.total; started = $script:ST.started; error = $script:ST.error; result = $null }
    if ($script:ST.result) { $o.result = ($script:ST.result | ConvertFrom-Json) }
    return $o
}

# ------------------------------- HTTP server -------------------------
$script:ServerPath = $PSCommandPath
$logFile = Join-Path $Root 'server-error.log'
function Write-Log([string]$m) { try { Add-Content -Path $logFile -Value ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  ' + $m) -Encoding UTF8 } catch {} }
function Send-Response($ctx, [int]$code, [string]$type, [string]$body) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    $ctx.Response.StatusCode = $code; $ctx.Response.ContentType = $type
    $ctx.Response.Headers.Add('Cache-Control', 'no-store')
    $ctx.Response.ContentLength64 = $bytes.Length
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length); $ctx.Response.OutputStream.Close()
}
function Send-Json($ctx, $obj, [int]$code = 200) { Send-Response $ctx $code 'application/json; charset=utf-8' ($obj | ConvertTo-Json -Depth 10 -Compress) }

Initialize-Raster
if (-not $script:RasterReady) { Write-Log ('Raster engine failed to compile: ' + $script:RasterError) }
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
try { $listener.Start() } catch { Write-Log ("Listener failed on port $Port : " + $_.Exception.Message); throw }
Write-Log "Heptapod L Studio $($script:Version) listening on http://localhost:$Port/"
$script:Started = Get-Date
while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    try {
        $path = $ctx.Request.Url.AbsolutePath; $method = $ctx.Request.HttpMethod
        $body = $null
        $bytes = $null
        if ($method -eq 'POST') {
            $msIn = New-Object System.IO.MemoryStream
            $ctx.Request.InputStream.CopyTo($msIn); $bytes = $msIn.ToArray(); $msIn.Dispose()
            $ctype = [string]$ctx.Request.ContentType
            if ($bytes.Length -gt 0 -and $ctype -match 'json') { $body = [System.Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json }
        }
        if ($path -eq '/' -or $path -eq '/index.html') {
            $f = Join-Path $Root 'index.html'
            Send-Response $ctx 200 'text/html; charset=utf-8' ([System.IO.File]::ReadAllText($f, [System.Text.Encoding]::UTF8))
        }
        elseif ($path -eq '/api/health') { Send-Json $ctx ([ordered]@{ status = 'ok'; app = 'Heptapod L Studio'; language = 'Heptapod L'; author = 'Larry Dalton'; engine = $script:Version; orthography = $script:Ortho; port = $Port; started = $script:Started.ToString('s'); registry = 'generated (18,278 units)'; selfTest = $script:ST.state; decoder = 'native SVG geometric + raster (PNG/JPEG) model fitting'; rasterEngine = $(if ($script:RasterReady) { 'ready' } else { 'error: ' + $script:RasterError }) }) }
        elseif ($path -eq '/api/encode' -and $method -eq 'POST') { $theme = 'dark'; if ($body.theme) { $theme = [string]$body.theme }; Send-Json $ctx (Invoke-Encode ([string]$body.text) $theme) }
        elseif ($path -eq '/api/decode' -and $method -eq 'POST') { Send-Json $ctx (Invoke-DecodeRequest $body) }
        elseif ($path -eq '/api/decode/svg' -and $method -eq 'POST') { Send-Json $ctx (Invoke-Decode ([System.Text.Encoding]::UTF8.GetString($bytes))) }
        elseif ($path -eq '/api/decode/gray' -and $method -eq 'POST') { $gw = [int]$ctx.Request.QueryString['w']; $gh = [int]$ctx.Request.QueryString['h']; Send-Json $ctx (Invoke-RasterDecode $bytes $gw $gh) }
        elseif ($path -eq '/api/decode/image' -and $method -eq 'POST') { Send-Json $ctx (Invoke-ImageBytesDecode $bytes) }
        elseif ($path -eq '/api/registry') { Send-Json $ctx (Get-Registry) }
        elseif ($path -like '/api/glyph/*') { Send-Json $ctx (Get-UnitDefinition ($ctx.Request.Url.AbsolutePath.Substring(11))) }
        elseif ($path -eq '/api/validate') { $full = ($ctx.Request.QueryString['full'] -eq '1'); $smoke = ($ctx.Request.QueryString['scope'] -eq 'smoke'); Send-Json $ctx (Invoke-Validate $full $smoke) }
        elseif ($path -eq '/api/selftest' -and $method -eq 'POST') { $sc = 'quick'; if ($body.scope -eq 'full') { $sc = 'full' }; Send-Json $ctx (Start-SelfTest $sc) }
        elseif ($path -eq '/api/selftest' -and $method -eq 'GET') { Send-Json $ctx (Get-SelfTestStatus) }
        elseif ($path -eq '/api/selftest/cancel' -and $method -eq 'POST') { $script:ST.cancel = $true; Send-Json $ctx @{ status = 'cancelling' } }
        elseif ($path -eq '/api/spec') { Send-Response $ctx 200 'text/plain; charset=utf-8' (Get-SpecText) }
        elseif ($path -eq '/api/shutdown' -and $method -eq 'POST' -and $ctx.Request.IsLocal) { Send-Json $ctx @{ status = 'stopping' }; $listener.Stop(); break }
        else { Send-Json $ctx @{ status = 'failed'; reason = 'Not found' } 404 }
    } catch {
        Write-Log ("Request error " + $ctx.Request.Url.AbsolutePath + ' : ' + $_.Exception.Message + ' @ ' + $_.InvocationInfo.ScriptLineNumber)
        try { Send-Json $ctx ([ordered]@{ status = 'failed'; reason = $_.Exception.Message }) 500 } catch {}
    }
}
'@

$IndexHtml = @'
<!doctype html>
<html lang="en-AU"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Heptapod L Studio</title>
<style>
:root{--bg:#0b0d10;--panel:#12161b;--line:#22303a;--ink:#e9ece8;--dim:#8b98a2;--acc:#3fd0e0;--ok:#55d68a;--bad:#ff6b6b;--warn:#f0c050}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.45 "Segoe UI",system-ui,sans-serif}
header{display:flex;align-items:baseline;gap:16px;padding:14px 20px;border-bottom:1px solid var(--line)}
header h1{font-size:18px;margin:0;font-weight:600}header span{color:var(--dim);font-size:12px}
main{display:grid;grid-template-columns:minmax(280px,1fr) minmax(360px,1.5fr) minmax(300px,1fr);gap:14px;padding:14px}
@media(max-width:1100px){main{grid-template-columns:1fr}}
section{background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:14px;min-width:0}
h2{font-size:13px;letter-spacing:.06em;text-transform:uppercase;color:var(--acc);margin:0 0 10px}
textarea{width:100%;min-height:110px;background:#0a0d10;color:var(--ink);border:1px solid var(--line);border-radius:6px;padding:10px;font:15px/1.4 Consolas,monospace;resize:vertical}
button,select{background:#1b242c;color:var(--ink);border:1px solid var(--line);border-radius:6px;padding:6px 10px;cursor:pointer;font:inherit}
button:hover{border-color:var(--acc)}.row{display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin:8px 0}
.kv{display:grid;grid-template-columns:120px 1fr;gap:3px 10px;font-size:13px}.kv b{color:var(--dim);font-weight:500}
table{width:100%;border-collapse:collapse;font-size:12px}td,th{border-bottom:1px solid var(--line);padding:3px 5px;text-align:left}th{color:var(--dim);font-weight:500}
.logo{background:#05070a;border-radius:6px;margin-bottom:10px}.logo svg{width:100%;height:auto;display:block}
.pass{color:var(--ok)}.fail{color:var(--bad)}.warn{color:var(--warn)}.mono{font-family:Consolas,monospace}
#drop{border:1px dashed var(--line);border-radius:6px;padding:18px;text-align:center;color:var(--dim)}#drop.over{border-color:var(--acc)}
#preview img,#preview svg{max-width:100%;height:auto;display:block;margin:8px auto;border-radius:6px}
.small{font-size:12px;color:var(--dim)}pre{white-space:pre-wrap;font-size:12px;color:var(--dim)}
</style></head><body>
<header><h1>Heptapod L <span style="font-weight:400;color:var(--dim)">Studio</span></h1><span style="color:var(--acc)">a circular script by Larry Dalton</span><span id="ver">connecting…</span></header>
<main>
<section><h2>Language input</h2>
<textarea id="txt" spellcheck="false">What is your name?</textarea>
<div class="row"><label class="small">Ink <select id="theme"><option value="dark">White on night</option><option value="paper">Black on paper</option></select></label>
<button id="go">Encode</button></div>
<div id="norm" class="small"></div>
<h2 style="margin-top:14px">Interpretation</h2><div id="sem"></div>
</section>
<section><h2>Logogram output</h2><div id="out"><p class="small">Type to encode. Each sentence becomes one logogram.</p></div></section>
<section><h2>Interpreter / decoder</h2>
<div id="drop">Drop an SVG, PNG or JPEG here<br><input type="file" id="file" accept=".svg,image/svg+xml,image/png,image/jpeg"></div>
<div id="preview"></div><div id="dec"></div>
<h2 style="margin-top:14px">Engine self-test</h2>
<p class="small" style="margin:0 0 6px">Checks the engine itself: draws test sentences and units, then reads them back from the drawing. Runs in the background — encoding and decoding keep working.</p>
<div class="row"><button id="val">Self-test (quick)</button><button id="valf">Self-test (all 18,278 units)</button><button id="stop">Stop</button><button id="spec">Orthography spec</button></div>
<div class="row"><button id="vali">Image self-test (browser renderer)</button></div>
<div class="row"><input id="gid" placeholder="Glyph lookup: L, LA, LAR, ?, U+00E9" style="flex:1;background:#0a0d10;color:var(--ink);border:1px solid var(--line);border-radius:6px;padding:6px"><button id="gl">Show</button></div>
<div id="diag" class="small"></div>
</section>
</main>
<script>
const $=id=>document.getElementById(id);let timer=null,last=[];
const esc=s=>String(s==null?'':s).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
async function api(p,b){const r=await fetch(p,b?{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(b)}:{});return r.json()}
api('/api/health').then(h=>$('ver').textContent=h.language+' · orthography '+h.orthography+' · engine '+h.engine+' · port '+h.port).catch(()=>$('ver').textContent='server not reachable');
function sched(){clearTimeout(timer);timer=setTimeout(encode,450)}
$('txt').addEventListener('input',sched);$('theme').addEventListener('change',encode);$('go').onclick=encode;
async function encode(){
 const t=$('txt').value;if(!t.trim()){$('out').innerHTML='';$('sem').innerHTML='';return}
 const r=await api('/api/encode',{text:t,theme:$('theme').value});last=r.sentences||[];
 $('norm').textContent='Normalised: '+r.normalised.replace(/\n/g,'⏎');
 let o='',s='';
 last.forEach((x,i)=>{
  o+=`<div class="logo">${x.svg}</div><div class="kv"><b>Sentence</b><span class="mono">${esc(x.text)}</span><b>Origin</b><span>${x.startAngle}° from first unit “${esc(x.firstUnit)}” (${x.firstUnitType})</span><b>Units</b><span class="mono">${esc(x.orthographic)}</span><b>Bands</b><span>${x.bands}</span><b>Round trip</b><span id="rt${i}">checking…</span><b>Image round trip</b><span id="ri${i}">checking…</span></div>
  <div class="row"><button onclick="dl(${i},'svg')">Export SVG</button><button onclick="dl(${i},'png')">Export PNG</button></div>
  <table><tr><th>#</th><th>Unit</th><th>Type</th><th>Canonical start</th><th>Placed</th><th>Glyph values</th></tr>${x.units.map((u,j)=>`<tr><td>${j+1}</td><td class="mono">${esc(u.text==='\n'?'⏎':u.text)}</td><td>${u.type}</td><td>${u.canonicalStart}°</td><td>${u.angle}°${u.band?' b'+u.band:''}</td><td class="mono">${u.glyphs.join(' ')}</td></tr>`).join('')}</table><hr style="border-color:var(--line)">`;
  const m=x.semantic;s+=`<div class="kv"><b>Sentence</b><span class="mono">${esc(x.text)}</span><b>Mood</b><span>${m.mood}</span><b>Intent</b><span>${m.intent}</span>${Object.entries(m.roles||{}).map(([k,v])=>`<b>${k}</b><span>${esc(v)}</span>`).join('')}<b>Features</b><span>${(m.features||[]).join(', ')||'—'}</span><b>Orthographic</b><span class="mono">${esc(x.orthographic)}</span></div><br>`;
 });
 $('out').innerHTML=o;$('sem').innerHTML=s;
 last.forEach(async(x,i)=>{const d=await decodeSvgText(x.svg);const ok=d.status==='ok'&&d.text===x.text;$('rt'+i).innerHTML=(ok?`<span class="pass">PASS</span> SVG geometry “${esc(d.text)}” · confidence ${d.confidence}`:`<span class="fail">FAIL</span> SVG ${esc(d.status)} “${esc(d.text)}” ${esc(d.reason)}`);
  try{const im=await svgToImg(x.svg,1);const r=await decodeGray(toGray(im,2200));const ok2=r.text===x.text;$('ri'+i).innerHTML=ok2?`<span class="${r.status==='ok'?'pass':'warn'}">PASS</span> image pixels “${esc(r.text)}” · confidence ${r.confidence}`:`<span class="fail">FAIL</span> image ${esc(r.status)} “${esc(r.text)}” ${esc(r.reason||'')}`}catch(e){$('ri'+i).textContent='image check failed: '+e.message}});
}
function dl(i,kind){const x=last[i];const name='heptapod-L-'+x.text.replace(/[^A-Z0-9]+/g,'_').slice(0,40);
 if(kind==='svg'){save(new Blob([x.svg],{type:'image/svg+xml'}),name+'.svg');return}
 const img=new Image();img.onload=()=>{const c=document.createElement('canvas');c.width=img.width*2;c.height=img.height*2;const g=c.getContext('2d');g.drawImage(img,0,0,c.width,c.height);c.toBlob(b=>save(b,name+'.png'))};
 img.src='data:image/svg+xml;charset=utf-8,'+encodeURIComponent(x.svg)}
function save(b,n){const a=document.createElement('a');a.href=URL.createObjectURL(b);a.download=n;a.click();setTimeout(()=>URL.revokeObjectURL(a.href),2000)}
const drop=$('drop');['dragover','dragenter'].forEach(e=>drop.addEventListener(e,ev=>{ev.preventDefault();drop.classList.add('over')}));
['dragleave','drop'].forEach(e=>drop.addEventListener(e,()=>drop.classList.remove('over')));
drop.addEventListener('drop',ev=>{ev.preventDefault();if(ev.dataTransfer.files[0])load(ev.dataTransfer.files[0])});$('file').onchange=e=>e.target.files[0]&&load(e.target.files[0]);
function load(f){const isSvg=/svg/i.test(f.type)||/\.svg$/i.test(f.name);const rd=new FileReader();
 $('dec').innerHTML='<p class="small">Decoding…</p>';
 rd.onload=async()=>{let d;
  if(isSvg){$('preview').innerHTML=`<img src="data:image/svg+xml;charset=utf-8,${encodeURIComponent(rd.result)}">`;d=await decodeSvgText(rd.result)}
  else{const img=await loadImg(rd.result);const g=toGray(img,2200);d=await decodeGray(g);drawOverlay(img,d)}
  showDec(d)};
 isSvg?rd.readAsText(f):rd.readAsDataURL(f)}
function loadImg(src){return new Promise((ok,bad)=>{const i=new Image();i.onload=()=>ok(i);i.onerror=()=>bad(new Error('image could not be read'));i.src=src})}
function toGray(img,max){let w=img.naturalWidth||img.width,h=img.naturalHeight||img.height;const k=Math.min(1,max/Math.max(w,h));w=Math.round(w*k);h=Math.round(h*k);
 const c=document.createElement('canvas');c.width=w;c.height=h;const x=c.getContext('2d');x.fillStyle='#fff';x.fillRect(0,0,w,h);x.drawImage(img,0,0,w,h);
 const p=x.getImageData(0,0,w,h).data;const g=new Uint8Array(w*h);for(let i=0;i<w*h;i++)g[i]=(p[4*i]*77+p[4*i+1]*150+p[4*i+2]*29)>>8;return{w,h,g,k}}
async function decodeGray(o){const r=await fetch(`/api/decode/gray?w=${o.w}&h=${o.h}`,{method:'POST',headers:{'Content-Type':'application/octet-stream'},body:o.g});const d=await r.json();d._k=o.k;return d}
async function decodeSvgText(t){const r=await fetch('/api/decode/svg',{method:'POST',headers:{'Content-Type':'image/svg+xml'},body:t});return r.json()}
function svgToImg(svg,scale){return new Promise((ok,bad)=>{const i=new Image();i.onload=()=>{if(scale===1)return ok(i);const c=document.createElement('canvas');c.width=Math.round(i.width*scale);c.height=Math.round(i.height*scale);c.getContext('2d').drawImage(i,0,0,c.width,c.height);const j=new Image();j.onload=()=>ok(j);j.src=c.toDataURL('image/png')};i.onerror=bad;i.src='data:image/svg+xml;charset=utf-8,'+encodeURIComponent(svg)})}
function drawOverlay(img,d){const r=d.checks&&d.checks.raster;const w=img.naturalWidth,h=img.naturalHeight;const c=document.createElement('canvas');c.width=w;c.height=h;c.style.width='100%';const x=c.getContext('2d');x.drawImage(img,0,0);
 if(r&&r.bandRadii&&r.bandRadii.length){const k=1/(d._k||1),cx=r.centreX*k,cy=r.centreY*k;x.lineWidth=Math.max(1,w/500);x.strokeStyle='rgba(63,208,224,.8)';x.fillStyle='rgba(63,208,224,1)';x.font=`600 ${Math.max(14,w/28)}px Segoe UI,sans-serif`;
  r.bandRadii.forEach(R=>{x.beginPath();x.arc(cx,cy,R*k,0,2*Math.PI);x.stroke()});
  if(d.startAngle!=null){const R=r.bandRadii[r.bandRadii.length-1]*k,a=d.startAngle*Math.PI/180;x.beginPath();x.moveTo(cx,cy);x.lineTo(cx+R*1.15*Math.sin(a),cy-R*1.15*Math.cos(a));x.stroke();x.fillText('start',cx+R*1.2*Math.sin(a),cy-R*1.2*Math.cos(a))}
  (d.units||[]).forEach(u=>{const R=r.bandRadii[u.band]*k,a=(d.startAngle+u.offset)*Math.PI/180,rr=R+(r.scale*k)*112;x.fillText(u.text==='\n'?'⏎':u.text,cx+rr*Math.sin(a)-8,cy-rr*Math.cos(a)+5)})}
 $('preview').innerHTML='';$('preview').appendChild(c)}
function showDec(d){const cls=d.status==='ok'?'pass':d.status==='partial'?'warn':'fail';
 let h=`<div class="kv"><b>Status</b><span class="${cls}">${d.status}</span><b>Method</b><span>${d.method}</span>${d.reason?`<b>Reason</b><span>${esc(d.reason)}</span>`:''}`;
 if(d.text!=null)h+=`<b>Recovered text</b><span class="mono">${esc(d.text)}</span><b>Origin</b><span>${d.startAngle}° (expected ${d.checks.startAngleExpected}°, ${d.checks.startAngleConsistent?'<span class=pass>consistent</span>':'<span class=fail>inconsistent</span>'})</span><b>Words / bands</b><span>${d.wordCount} / ${d.bands}</span><b>Confidence</b><span>${d.confidence}</span><b>Provenance</b><span>${d.checks.provenanceMatch===true?'metadata agrees':d.checks.provenanceMatch===false?'<span class=warn>metadata differs: '+esc(d.checks.provenanceText)+'</span>':'none'} (not used for decoding)</span>`;
 h+='</div>';if(d.units&&d.units.length)h+=`<table><tr><th>Unit</th><th>Type</th><th>Word</th><th>Offset</th><th>Glyphs</th></tr>${d.units.map(u=>`<tr><td class="mono">${esc(u.text==='\n'?'⏎':u.text)}</td><td>${u.type}</td><td>${u.word+1}</td><td>${u.offset}°</td><td class="mono">${u.glyphs.join(' ')}</td></tr>`).join('')}</table>`;
 if(d.unresolved&&d.unresolved.length)h+=`<pre>Unresolved: ${esc(JSON.stringify(d.unresolved,null,1))}</pre>`;$('dec').innerHTML=h}
let poll=null;
async function runVal(full){const r=await api('/api/selftest',{scope:full?'full':'quick'});if(r.status==='busy'){$('diag').innerHTML='<span class="warn">A self-test is already running.</span>'}watch()}
function watch(){clearInterval(poll);poll=setInterval(showSt,1500);showSt()}
async function showSt(){const s=await api('/api/selftest');
 if(s.state==='running'){$('diag').innerHTML=`Running ${s.scope} self-test… ${s.phase} ${s.done} / ${s.total||'?'}`;return}
 clearInterval(poll);if(s.state==='idle'){$('diag').textContent='';return}
 if(s.state==='error'){$('diag').innerHTML='<span class="fail">Self-test error:</span> '+esc(s.error);return}
 const v=s.result;$('diag').innerHTML=`<span class="${v.status==='ok'?'pass':v.status==='cancelled'?'warn':'fail'}">${v.status.toUpperCase()}</span> · ${v.scope} · ${v.seconds}s<br>Units: ${v.inventory.tested} drawn and read back, ${v.inventory.failed} failed${v.inventory.failures.length?'<pre>'+esc(JSON.stringify(v.inventory.failures,null,1))+'</pre>':''}<br>Images: ${(v.images||[]).filter(x=>x.pass).length}/${(v.images||[]).length} synthetic rasters decoded${(v.images||[]).filter(x=>!x.pass).map(x=>'<br><span class=fail>✗</span> '+esc(x.input)+' ×'+x.scale+' → '+esc(x.decoded)).join('')}<br>${v.sentences.map(t=>`<span class="${t.pass?'pass':'fail'}">${t.pass?'✓':'✗'}</span> <span class="mono">${esc(t.input)}</span>`).join('<br>')}`}
$('gl').onclick=async()=>{const id=$('gid').value.trim();if(!id)return;const g=await api('/api/glyph/'+encodeURIComponent(id));if(g.status!=='ok'){$('diag').innerHTML='<span class="fail">'+esc(g.reason)+'</span>';return}
 $('diag').innerHTML=`<div class="logo">${g.svg}</div><div class="kv"><b>Unit</b><span class="mono">${esc(g.text)} (${g.type})</span><b>Canonical start</b><span>${g.canonicalStart}°</span></div><table><tr><th>Value</th><th>Role</th><th>Dir</th><th>Curl</th><th>Barbs</th><th>Length</th></tr>${g.glyphs.map(x=>`<tr><td>${x.value}</td><td>${esc(x.role)}</td><td>${x.direction}</td><td>${x.curl}</td><td>${x.barbs}</td><td>${x.length}</td></tr>`).join('')}</table>`};
$('vali').onclick=async()=>{const S=['LARRY','HUMANITY','LARRY KNOWS IAN','MY NAME IS LARRY','WHAT IS YOUR NAME?','HUMANITY SEEKS PEACE.',"Larry's e-mail: larry@jjswaste.com.au (test #42) - done!"];
 const cfgs=[['dark',1,'png'],['paper',2,'png'],['dark',0.7,'jpeg'],['paper',1,'jpeg']];let out=[],pass=0,tot=0;
 for(const t of S)for(const [th,sc,fmt] of cfgs){$('diag').textContent=`Image self-test ${tot+1}/${S.length*cfgs.length}…`;
  const e=await api('/api/encode',{text:t,theme:th});const x=e.sentences[0];let im=await svgToImg(x.svg,sc);
  if(fmt==='jpeg'){const c=document.createElement('canvas');c.width=im.width;c.height=im.height;c.getContext('2d').drawImage(im,0,0);im=await loadImg(c.toDataURL('image/jpeg',0.75))}
  const r=await decodeGray(toGray(im,2200));const ok=r.text===x.text;tot++;if(ok)pass++;out.push(`<span class="${ok?'pass':'fail'}">${ok?'✓':'✗'}</span> ${th} ×${sc} ${fmt} <span class="mono">${esc(x.text)}</span>${ok?'':' → '+esc(r.text||r.reason)}`)}
 $('diag').innerHTML=`<span class="${pass===tot?'pass':'fail'}">${pass}/${tot} images decoded exactly</span><br>`+out.join('<br>')};
$('val').onclick=()=>runVal(false);$('valf').onclick=()=>runVal(true);$('stop').onclick=()=>api('/api/selftest/cancel',{});
api('/api/selftest').then(s=>{if(s.state!=='idle')watch()});
$('spec').onclick=async()=>{const t=await (await fetch('/api/spec')).text();$('diag').innerHTML='<pre>'+esc(t)+'</pre>'};
encode();
</script></body></html>
'@

$RasterSource = @'
// Heptapod L Studio raster decoder (orthography HL-1.1). C# 5 / .NET Framework 4.x compatible.
// Reads a grayscale image of a native logogram and recovers its glyph primitives
// by fitting the Heptapod L glyph model (direction, curl, length, barbs) to the ink.
using System;
using System.Collections.Generic;

public class HsGlyphHit
{
    public double[] Base; public List<int> Pixels; public double OwnFraction;
    public int Band; public double Angle; public int D; public int C; public int B; public int L; public int Value;
    public double[] BarbCov; public double PrimaryScore; public double PrimaryMargin; public double BarbScore; public double BarbMargin; public double Confidence;
}
public class HsBar { public int Band; public double Angle; public bool IsStart; public double Strength; }
public class HsRasterResult
{
    public bool Ok; public string Reason; public int Width; public int Height; public bool DarkBackground;
    public double Cx; public double Cy; public double Scale; public double[] BandR;
    public List<HsGlyphHit> Glyphs = new List<HsGlyphHit>();
    public List<HsBar> Bars = new List<HsBar>();
    public List<string> Unresolved = new List<string>();
    public int InkPixels;
}

public static class HsRaster
{
    // geometry (must match server.ps1)
    public static double R0 = 240, BandStep = 220, PriW = 13, BarbLen = 27, BarbW = 7, InClusterPx = 32;
    public static double[] Len = new double[] { 40, 64, 92 };
    public static int NPri = 18, NBarb = 8;
    public static double Threshold = 0.68;

    static int W, H; static bool[] M;

    public static byte[] BgrToGray(byte[] bgr, int w, int h, int stride, int bpp)
    {
        byte[] g = new byte[w * h];
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++)
            {
                int i = y * stride + x * bpp;
                g[y * w + x] = (byte)((bgr[i] * 29 + bgr[i + 1] * 150 + bgr[i + 2] * 77) >> 8);
            }
        return g;
    }

    static byte[] Downscale(byte[] g, int w, int h, int f, out int nw, out int nh)
    {
        nw = w / f; nh = h / f; byte[] o = new byte[nw * nh];
        for (int y = 0; y < nh; y++) for (int x = 0; x < nw; x++)
            {
                int s = 0; for (int dy = 0; dy < f; dy++) for (int dx = 0; dx < f; dx++) s += g[(y * f + dy) * w + x * f + dx];
                o[y * nw + x] = (byte)(s / (f * f));
            }
        return o;
    }

    static bool At(bool[] m, double x, double y)
    {
        int ix = (int)Math.Round(x), iy = (int)Math.Round(y);
        if (ix < 0 || iy < 0 || ix >= W || iy >= H) return false;
        return m[iy * W + ix];
    }

    static bool[] Dilate(bool[] m, int r)
    {
        if (r <= 0) return m;
        bool[] t = new bool[W * H]; bool[] o = new bool[W * H];
        for (int y = 0; y < H; y++)
        {
            int cnt = 0;
            for (int x = -r; x < W; x++)
            {
                int add = x + r; if (add < W && m[y * W + add]) cnt++;
                int rem = x - r - 1; if (rem >= 0 && m[y * W + rem]) cnt--;
                if (x >= 0) t[y * W + x] = cnt > 0;
            }
        }
        for (int x = 0; x < W; x++)
        {
            int cnt = 0;
            for (int y = -r; y < H; y++)
            {
                int add = y + r; if (add < H && t[add * W + x]) cnt++;
                int rem = y - r - 1; if (rem >= 0 && t[rem * W + x]) cnt--;
                if (y >= 0) o[y * W + x] = cnt > 0;
            }
        }
        return o;
    }

    static void Pt(double cx, double cy, double r, double th, out double x, out double y)
    {
        double t = th * Math.PI / 180.0; x = cx + r * Math.Sin(t); y = cy - r * Math.Cos(t);
    }

    static void Centerline(double x0, double y0, double th, int d, int c, double len, double[] X, double[] Y)
    {
        double t0 = th * Math.PI / 180.0;
        double ux = Math.Sin(t0), uy = -Math.Cos(t0), vx = Math.Cos(t0), vy = Math.Sin(t0);
        double dd = d == 1 ? -1.0 : 1.0, cc = c == 1 ? -1.0 : 1.0;
        for (int i = 0; i < NPri; i++)
        {
            double t = i / (NPri - 1.0);
            double a = t - 0.25 * t * t, b = 0.5 * Math.Pow(t, 2.2);
            X[i] = x0 + ux * dd * len * a + vx * cc * len * b;
            Y[i] = y0 + uy * dd * len * a + vy * cc * len * b;
        }
    }

    static double CoverCurve(bool[] m, double[] X, double[] Y, double t0, double t1, int samples)
    {
        int n = X.Length, hit = 0, tot = 0;
        for (int s = 0; s < samples; s++)
        {
            double t = t0 + (t1 - t0) * s / (samples - 1.0);
            double fi = t * (n - 1); int i = (int)Math.Floor(fi); if (i >= n - 1) i = n - 2; double f = fi - i;
            double x = X[i] + (X[i + 1] - X[i]) * f, y = Y[i] + (Y[i + 1] - Y[i]) * f;
            tot++; if (At(m, x, y)) hit++;
        }
        return tot == 0 ? 0 : (double)hit / tot;
    }

    // checks that the stroke has primary-like thickness along t = 0.25..0.6 (barbs are much thinner)
    static double CoverWidth(double[] X, double[] Y, double s)
    {
        int n = X.Length, hit = 0, tot = 0;
        for (int q = 0; q < 12; q++)
        {
            double t = 0.25 + 0.35 * q / 11.0;
            double fi = t * (n - 1); int i = (int)Math.Floor(fi); double f = fi - i;
            double x = X[i] + (X[i + 1] - X[i]) * f, y = Y[i] + (Y[i + 1] - Y[i]) * f;
            double dx = X[i + 1] - X[i], dy = Y[i + 1] - Y[i], m = Math.Sqrt(dx * dx + dy * dy); if (m == 0) m = 1;
            double nx = -dy / m, ny = dx / m;
            double hw = PriW * s * Math.Pow(1 - t, 0.9) * (1 + 0.35 * Math.Sin(Math.PI * t)) / 2.0 * 0.55;
            tot += 2; if (At(M, x + nx * hw, y + ny * hw)) hit++; if (At(M, x - nx * hw, y - ny * hw)) hit++;
        }
        return (double)hit / tot;
    }

    static void Barb(double[] PX, double[] PY, int k, int side, double s, double[] X, double[] Y)
    {
        double dx = PX[k + 1] - PX[k - 1], dy = PY[k + 1] - PY[k - 1], m = Math.Sqrt(dx * dx + dy * dy);
        double tx = dx / m, ty = dy / m, ang = 50.0 * Math.PI / 180.0 * side;
        double bx = tx * Math.Cos(ang) - ty * Math.Sin(ang), by = tx * Math.Sin(ang) + ty * Math.Cos(ang);
        double px = -by * side, py = bx * side;
        for (int i = 0; i < NBarb; i++)
        {
            double t = i / (NBarb - 1.0);
            X[i] = PX[k] + bx * BarbLen * s * t + px * 4.0 * s * t * t;
            Y[i] = PY[k] + by * BarbLen * s * t + py * 4.0 * s * t * t;
        }
    }

    public static HsRasterResult Analyze(byte[] gray, int w, int h)
    {
        // try the dominant background first, then the second most common tone (e.g. a paper logogram inside a dark screenshot)
        int[] gh = new int[256]; for (int i = 0; i < gray.Length; i++) gh[gray[i]]++;
        double[] sm = new double[256];
        for (int v = 0; v < 256; v++) for (int q = -3; q <= 3; q++) { int vv = v + q; if (vv >= 0 && vv < 256) sm[v] += gh[vv]; }
        int m1 = 0; for (int v = 1; v < 256; v++) if (sm[v] > sm[m1]) m1 = v;
        int m2 = -1; for (int v = 0; v < 256; v++) if (Math.Abs(v - m1) >= 80 && (m2 < 0 || sm[v] > sm[m2])) m2 = v;
        BgOverride = m1; HsRasterResult r1 = Core(gray, w, h, 0);
        if (Usable(r1) || m2 < 0 || sm[m2] < 0.03 * gray.Length) { BgOverride = -1; return r1; }
        // crop to the block where the second tone dominates (a logogram panel inside a screenshot)
        int x0 = 0, x1 = w - 1, y0 = 0, y1 = h - 1;
        {
            int[] rc = new int[h], cc = new int[w];
            for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) if (Math.Abs(gray[y * w + x] - m2) <= 25) { rc[y]++; cc[x]++; }
            LongestRun(rc, 0.25 * w, out y0, out y1); LongestRun(cc, 0.25 * h, out x0, out x1);
        }
        int cw = x1 - x0 + 1, ch = y1 - y0 + 1;
        if (cw < 120 || ch < 120) { cw = w; ch = h; x0 = 0; y0 = 0; }
        byte[] crop = new byte[cw * ch];
        for (int y = 0; y < ch; y++) Array.Copy(gray, (y + y0) * w + x0, crop, y * cw, cw);
        BgOverride = m2; HsRasterResult r2 = Core(crop, cw, ch, 0); BgOverride = -1;
        if (!Usable(r2)) return r1;
        r2.Cx += x0; r2.Cy += y0; r2.Width = w; r2.Height = h;
        return r2;
    }
    static int BgOverride = -1;
    static void LongestRun(int[] cnt, double thr, out int a, out int b)
    {
        a = 0; b = cnt.Length - 1; int bestLen = 0, cur = -1;
        for (int i = 0; i <= cnt.Length; i++)
        {
            bool on = i < cnt.Length && cnt[i] >= thr;
            if (on && cur < 0) cur = i;
            if (!on && cur >= 0) { if (i - cur > bestLen) { bestLen = i - cur; a = cur; b = i - 1; } cur = -1; }
        }
    }
    static bool Usable(HsRasterResult r)
    {
        if (!r.Ok || r.Glyphs.Count == 0) return false;
        bool st = false; foreach (HsBar b in r.Bars) if (b.IsStart) st = true;
        if (!st) return false;
        List<double> f = new List<double>(); foreach (HsGlyphHit g in r.Glyphs) f.Add(g.PrimaryScore); f.Sort();
        return f[f.Count / 2] >= 0.55;
    }

    static HsRasterResult Core(byte[] gray, int w, int h, int depth)
    {
        HsRasterResult res = new HsRasterResult();
        int f = 1; while (Math.Max(w, h) / f > 2200) f++;
        if (f > 1) { int nw, nh; gray = Downscale(gray, w, h, f, out nw, out nh); w = nw; h = nh; }
        W = w; H = h; res.Width = w; res.Height = h;
        if (w < 120 || h < 120) { res.Reason = "Image too small to interpret."; return res; }

        // 1. background and ink polarity from the border
        List<int> border = new List<int>();
        for (int x = 0; x < w; x += 2) { border.Add(gray[x]); border.Add(gray[(h - 1) * w + x]); }
        for (int y = 0; y < h; y += 2) { border.Add(gray[y * w]); border.Add(gray[y * w + w - 1]); }
        border.Sort();
        // background = most common grey level (robust to screenshots with margins); border median as tie-break
        int[] ghist = new int[256]; for (int i = 0; i < w * h; i++) ghist[gray[i]]++;
        int mode = 0; double mbest = -1;
        for (int v = 0; v < 256; v++) { double sm2 = 0; for (int q = -3; q <= 3; q++) { int vv = v + q; if (vv >= 0 && vv < 256) sm2 += ghist[vv]; } if (sm2 > mbest) { mbest = sm2; mode = v; } }
        double bg = BgOverride >= 0 ? BgOverride : mode;
        res.DarkBackground = bg < 128;
        double range = res.DarkBackground ? (255 - bg) : bg; if (range < 40) { res.Reason = "No usable contrast between ink and background."; return res; }
        M = new bool[w * h]; int ink = 0;
        for (int i = 0; i < w * h; i++)
        {
            double v = res.DarkBackground ? (gray[i] - bg) / range : (bg - gray[i]) / range;
            if (v >= Threshold) { M[i] = true; ink++; }
        }
        res.InkPixels = ink;
        if (ink < 200) { res.Reason = "Almost no solid ink found."; return res; }

        // 2. centre: maximise radial concentration of ink
        List<int> px = new List<int>(), py = new List<int>();
        int step = Math.Max(1, ink / 40000);
        int cnt = 0; double sx = 0, sy = 0;
        for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) if (M[y * w + x]) { if (cnt % step == 0) { px.Add(x); py.Add(y); } cnt++; sx += x; sy += y; }
        double cx = sx / ink, cy = sy / ink;
        int maxR = (int)Math.Sqrt(w * w + h * h) + 2;
        double bestScore = -1, bcx = cx, bcy = cy;
        double span = Math.Max(w, h) / 12.0;
        double[] steps = new double[] { span / 10.0, span / 50.0, 0.5 };
        for (int pass = 0; pass < 3; pass++)
        {
            double st = Math.Max(0.5, steps[pass]); double ox = bcx, oy = bcy;
            for (int iy = -10; iy <= 10; iy++) for (int ix = -10; ix <= 10; ix++)
                {
                    double tx = ox + ix * st, ty = oy + iy * st;
                    int[] hist = new int[maxR];
                    for (int k = 0; k < px.Count; k++) { double ddx = px[k] - tx, ddy = py[k] - ty; int r = (int)Math.Sqrt(ddx * ddx + ddy * ddy); hist[r]++; }
                    int best = 0; for (int r = 20; r < maxR - 2; r++) { int v = hist[r - 1] + hist[r] + hist[r + 1]; double nv = v / Math.Sqrt(r); if (nv > best) best = (int)nv; }
                    if (best > bestScore) { bestScore = best; bcx = tx; bcy = ty; }
                }
        }
        cx = bcx; cy = bcy;

        // 3. band radii from normalised radial density
        double[] dens = new double[maxR];
        for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) if (M[y * w + x]) { double ddx = x - cx, ddy = y - cy; int r = (int)Math.Sqrt(ddx * ddx + ddy * ddy); if (r < maxR) dens[r] += 1; }
        for (int r = 1; r < maxR; r++) dens[r] /= (2 * Math.PI * r);
        double[] sm = new double[maxR];
        for (int r = 3; r < maxR - 3; r++) { double s2 = 0; for (int q = -3; q <= 3; q++) s2 += dens[r + q]; sm[r] = s2 / 7; }
        double peak = 0; for (int r = 20; r < maxR - 3; r++) if (sm[r] > peak) peak = sm[r];
        List<int> peaks = new List<int>();
        for (int r = 20; r < maxR - 4; r++)
            if (sm[r] >= 0.45 * peak && sm[r] >= sm[r - 1] && sm[r] > sm[r + 1])
            {
                bool far = true; foreach (int p in peaks) if (Math.Abs(p - r) < 25) far = false;
                if (far) peaks.Add(r);
            }
        if (peaks.Count == 0) { res.Reason = "No circular sentence ring detected."; return res; }
        // pick the smallest peak that yields a consistent band ladder
        double R0img = peaks[0]; double s = R0img / R0;
        List<double> bands = new List<double>();
        for (int k = 0; k < 12; k++)
        {
            double expect = (R0 + BandStep * k) * s; bool found = false;
            foreach (int p in peaks) if (Math.Abs(p - expect) < 0.08 * expect) { found = true; }
            if (found) bands.Add(expect); else break;
        }
        // refine each band radius and centre with an algebraic circle fit on ring pixels
        for (int pass = 0; pass < 2; pass++)
        {
            double Sx = 0, Sy = 0, Sxx = 0, Syy = 0, Sxy = 0, Sxz = 0, Syz = 0, Sz = 0; int n = 0;
            double Rb = bands[0];
            for (int y = 0; y < h; y++) for (int x = 0; x < w; x++)
                    if (M[y * w + x])
                    {
                        double ddx = x - cx, ddy = y - cy, r = Math.Sqrt(ddx * ddx + ddy * ddy);
                        if (Math.Abs(r - Rb) < 6 * s) { double z = x * x + y * y; Sx += x; Sy += y; Sxx += x * x; Syy += y * y; Sxy += x * y; Sxz += x * z; Syz += y * z; Sz += z; n++; }
                    }
            if (n < 50) break;
            // solve [Sxx Sxy Sx; Sxy Syy Sy; Sx Sy n] [D E F] = -[Sxz Syz Sz]
            double[,] A = new double[3, 4] { { Sxx, Sxy, Sx, -Sxz }, { Sxy, Syy, Sy, -Syz }, { Sx, Sy, n, -Sz } };
            for (int i = 0; i < 3; i++)
            {
                int pv = i; for (int j = i + 1; j < 3; j++) if (Math.Abs(A[j, i]) > Math.Abs(A[pv, i])) pv = j;
                for (int k = 0; k < 4; k++) { double tmp = A[i, k]; A[i, k] = A[pv, k]; A[pv, k] = tmp; }
                for (int j = 0; j < 3; j++) if (j != i) { double fct = A[j, i] / A[i, i]; for (int k = 0; k < 4; k++) A[j, k] -= fct * A[i, k]; }
            }
            double D = A[0, 3] / A[0, 0], E = A[1, 3] / A[1, 1], F = A[2, 3] / A[2, 2];
            cx = -D / 2; cy = -E / 2; double rr = Math.Sqrt(cx * cx + cy * cy - F);
            if (double.IsNaN(rr)) break;
            s = rr / R0;
            for (int k = 0; k < bands.Count; k++) bands[k] = (R0 + BandStep * k) * s;
        }
        res.Cx = cx; res.Cy = cy; res.Scale = s; res.BandR = bands.ToArray();
        if (s < 0.25) { res.Reason = "Logogram too small in the image (scale " + s.ToString("0.00") + ")."; return res; }
        if (s > 1.35 && depth == 0)
        {
            int fct = (int)Math.Ceiling(s / 1.15); int nw2, nh2;
            byte[] g2 = Downscale(gray, w, h, fct, out nw2, out nh2);
            HsRasterResult r2 = Core(g2, nw2, nh2, 1);
            r2.Cx = r2.Cx * fct + (fct - 1) / 2.0; r2.Cy = r2.Cy * fct + (fct - 1) / 2.0; r2.Scale *= fct;
            if (r2.BandR != null) for (int k = 0; k < r2.BandR.Length; k++) r2.BandR[k] *= fct;
            r2.Width = w; r2.Height = h; return r2;
        }


        // 4. per band: bases and bars from the two sampling rows
        for (int b = 0; b < bands.Count; b++)
        {
            double R = bands[b]; double rowOff = 13 * s;
            int na = (int)(2 * Math.PI * R / 0.5); double da = 360.0 / na;
            bool[] outR = new bool[na], inR = new bool[na];
            for (int i = 0; i < na; i++)
            {
                double th = i * da, x, y; bool o = false, n2 = false;
                for (int q = -1; q <= 1; q++)
                {
                    Pt(cx, cy, R + rowOff + q, th, out x, out y); if (At(M, x, y)) o = true;
                    Pt(cx, cy, R - rowOff + q, th, out x, out y); if (At(M, x, y)) n2 = true;
                }
                outR[i] = o; inR[i] = n2;
            }
            List<double[]> outRuns = Runs(outR, da, R), inRuns = Runs(inR, da, R);
            double pxPerDeg = Math.PI * R / 180.0;
            List<double[]> bases = new List<double[]>(); // angle, dir, width
            bool[] outUsed = new bool[outRuns.Count], inUsed = new bool[inRuns.Count];
            for (int i = 0; i < outRuns.Count; i++)
                for (int j = 0; j < inRuns.Count; j++)
                {
                    if (inUsed[j]) continue;
                    double dAng = Math.Abs(AngDiff(outRuns[i][0], inRuns[j][0])) * pxPerDeg;
                    if (dAng < 5 * s && outRuns[i][1] < 16 * s && inRuns[j][1] < 16 * s)
                    {
                        double a = AngMid(outRuns[i][0], inRuns[j][0]);
                        // start bar reaches R +/- 24s on both sides
                        int hitO = 0, hitI = 0;
                        for (double off = -4 * s; off <= 4 * s; off += 0.5)
                        {
                            double x, y, th = a + off / pxPerDeg;
                            Pt(cx, cy, R + 24 * s, th, out x, out y); if (At(M, x, y)) hitO++;
                            Pt(cx, cy, R - 24 * s, th, out x, out y); if (At(M, x, y)) hitI++;
                        }
                        bool isStart = (hitO > 0 && hitI > 0);
                        // a boundary stub ends at 20s: ink at 24s on only one side means a glyph stroke, not a bar
                        if (!isStart && (hitO > 0 || hitI > 0)) continue;
                        if (!isStart)
                        {
                            // a boundary bar is a short straight stub; if either half fits a full glyph it is a glyph, not a bar
                            Claim = null;
                            HsGlyphHit go = FitGlyph(new double[] { outRuns[i][0], 0, outRuns[i][1] }, b, R, cx, cy, s, pxPerDeg);
                            HsGlyphHit gi2 = FitGlyph(new double[] { inRuns[j][0], 1, inRuns[j][1] }, b, R, cx, cy, s, pxPerDeg);
                            if ((go != null && go.PrimaryScore >= 0.6) || (gi2 != null && gi2.PrimaryScore >= 0.6)) continue;
                        }
                        HsBar bar = new HsBar(); bar.Band = b; bar.Angle = a; bar.IsStart = isStart; bar.Strength = hitO + hitI;
                        res.Bars.Add(bar); outUsed[i] = true; inUsed[j] = true; break;
                    }
                }
            for (int i = 0; i < outRuns.Count; i++) if (!outUsed[i] && !NearBar(res, b, outRuns[i][0], 9 * s / pxPerDeg)) AddBase(bases, outRuns[i], 0, s, b, res);
            for (int j = 0; j < inRuns.Count; j++) if (!inUsed[j] && !NearBar(res, b, inRuns[j][0], 9 * s / pxPerDeg)) AddBase(bases, inRuns[j], 1, s, b, res);

            // a barb close to the ring can leave a narrow second run beside its own stroke: keep the wider
            {
                List<double[]> kept = new List<double[]>();
                foreach (double[] cand in bases)
                {
                    int clash = -1;
                    for (int q = 0; q < kept.Count; q++) if (kept[q][1] == cand[1] && Math.Abs(AngDiff(kept[q][0], cand[0])) * pxPerDeg < 18 * s) clash = q;
                    if (clash < 0) kept.Add(cand);
                    else if (cand[2] > kept[clash][2]) kept[clash] = cand;
                }
                bases = kept;
            }
            // 5. fit the glyph model at every base by overlap with the observed stroke component
            Claim = null;
            List<HsGlyphHit> hits = new List<HsGlyphHit>();
            foreach (double[] bs in bases)
            {
                HsGlyphHit g = FitGlyph(bs, b, R, cx, cy, s, pxPerDeg);
                if (g != null) hits.Add(g); else res.Unresolved.Add("band " + b + ": stroke at " + bs[0].ToString("0.0") + " deg could not be matched to any glyph");
            }
            // refine: each glyph is refitted with ink explained by its neighbours removed
            for (int round = 0; round < 3; round++)
            {
                if (round > 0)
                {
                    // a stroke fragment that belongs to a neighbouring glyph (e.g. a barb near the ring) is not a glyph
                    List<HsGlyphHit> keep = new List<HsGlyphHit>();
                    foreach (HsGlyphHit g in hits)
                    {
                        if (g.OwnFraction < 0.5 && g.PrimaryScore < 0.6) res.Unresolved.Add("band " + b + ": ignored stroke fragment at " + g.Angle.ToString("0.0") + " deg (part of a neighbouring glyph)");
                        else keep.Add(g);
                    }
                    hits = keep;
                }
                Claim = new int[W * H];
                foreach (HsGlyphHit g in hits) foreach (int pi in g.Pixels) Claim[pi]++;
                for (int i = 0; i < hits.Count; i++)
                {
                    foreach (int pi in hits[i].Pixels) Claim[pi]--;
                    HsGlyphHit g2 = FitGlyph(hits[i].Base, b, R, cx, cy, s, pxPerDeg);
                    if (g2 != null) hits[i] = g2;
                    foreach (int pi in hits[i].Pixels) Claim[pi]++;
                }
            }
            Claim = null;
            foreach (HsGlyphHit g in hits)
            {
                g.Pixels = null;
                // a stroke fragment that belongs to a neighbouring glyph (e.g. a barb near the ring) is not a glyph
                res.Glyphs.Add(g);
            }
        }
        res.Ok = true;
        return res;
    }

    // ---- model fitting -------------------------------------------------
    static double[] TaperPoly(double[] X, double[] Y, double w0, double swell)
    {
        int n = X.Length; double[] p = new double[4 * n];
        for (int i = 0; i < n; i++)
        {
            int i0 = Math.Max(0, i - 1), i1 = Math.Min(n - 1, i + 1);
            double dx = X[i1] - X[i0], dy = Y[i1] - Y[i0], m = Math.Sqrt(dx * dx + dy * dy); if (m == 0) m = 1;
            double nx = -dy / m, ny = dx / m, t = i / (n - 1.0);
            double ww = w0 * Math.Pow(1 - t, 0.9) * (1 + swell * Math.Sin(Math.PI * t));
            p[2 * i] = X[i] + nx * ww / 2; p[2 * i + 1] = Y[i] + ny * ww / 2;
            p[2 * (2 * n - 1 - i)] = X[i] - nx * ww / 2; p[2 * (2 * n - 1 - i) + 1] = Y[i] - ny * ww / 2;
        }
        return p;
    }

    static int[] stamp; static bool[] obs; static int wx0, wy0, wwid, whei, stampId;
    static int[] Claim; static List<int> Collect; static double[] lastCov;
    static double fcx, fcy, fR, fBand;

    static void FillCount(double[] p, ref int P, ref int I)
    {
        int n = p.Length / 2; double minY = 1e9, maxY = -1e9;
        for (int i = 0; i < n; i++) { if (p[2 * i + 1] < minY) minY = p[2 * i + 1]; if (p[2 * i + 1] > maxY) maxY = p[2 * i + 1]; }
        int y0 = Math.Max(wy0, (int)Math.Ceiling(minY - 0.5)), y1 = Math.Min(wy0 + whei - 1, (int)Math.Floor(maxY - 0.5));
        List<double> xs = new List<double>();
        for (int y = y0; y <= y1; y++)
        {
            double sy = y + 0.0; xs.Clear();
            for (int i = 0; i < n; i++)
            {
                int j = (i + 1) % n; double ay = p[2 * i + 1], by = p[2 * j + 1];
                if ((ay <= sy && by > sy) || (by <= sy && ay > sy)) xs.Add(p[2 * i] + (sy - ay) / (by - ay) * (p[2 * j] - p[2 * i]));
            }
            xs.Sort();
            for (int k = 0; k + 1 < xs.Count; k += 2)
            {
                int xa = Math.Max(wx0, (int)Math.Ceiling(xs[k])), xb = Math.Min(wx0 + wwid - 1, (int)Math.Floor(xs[k + 1]));
                for (int x = xa; x <= xb; x++)
                {
                    int li = (y - wy0) * wwid + (x - wx0);
                    if (stamp[li] == stampId) continue;
                    stamp[li] = stampId;
                    if (Collect != null) { Collect.Add(y * W + x); continue; }
                    if (Claim != null && Claim[y * W + x] > 0) continue;
                    double ddx = x - fcx, ddy = y - fcy; if (Math.Abs(Math.Sqrt(ddx * ddx + ddy * ddy) - fR) < fBand) continue;
                    P++; if (obs[li]) I++;
                }
            }
        }
    }

    static HsGlyphHit FitGlyph(double[] bs, int band, double R, double cx, double cy, double s, double pxPerDeg)
    {
        int d = (int)bs[1];
        double reach = (Len[2] + BarbLen + 14) * s;
        double bx0, by0; Pt(cx, cy, R, bs[0], out bx0, out by0);
        wx0 = Math.Max(0, (int)(bx0 - reach)); wy0 = Math.Max(0, (int)(by0 - reach));
        wwid = Math.Min(W, (int)(bx0 + reach)) - wx0; whei = Math.Min(H, (int)(by0 + reach)) - wy0;
        if (wwid < 10 || whei < 10) return null;
        fcx = cx; fcy = cy; fR = R; fBand = 10 * s;
        // observed: connected stroke component outside the ring band, seeded at the base row
        obs = new bool[wwid * whei]; stamp = new int[wwid * whei]; stampId = 0;
        double sxp, syp; Pt(cx, cy, R + (d == 0 ? 13 : -13) * s, bs[0], out sxp, out syp);
        int seedX = -1, seedY = -1; double bd = 1e9;
        for (int yy = (int)syp - 4; yy <= (int)syp + 4; yy++) for (int xx = (int)sxp - 4; xx <= (int)sxp + 4; xx++)
                if (xx >= 0 && yy >= 0 && xx < W && yy < H && M[yy * W + xx]) { double dd = (xx - sxp) * (xx - sxp) + (yy - syp) * (yy - syp); if (dd < bd) { bd = dd; seedX = xx; seedY = yy; } }
        if (seedX < 0) return null;
        int O = 0; Queue<int> qu = new Queue<int>(); int sl = (seedY - wy0) * wwid + (seedX - wx0); obs[sl] = true; qu.Enqueue(sl);
        while (qu.Count > 0)
        {
            int li = qu.Dequeue(); int lx = li % wwid, ly = li / wwid;
            if (Claim == null || Claim[(ly + wy0) * W + (lx + wx0)] == 0) O++;
            for (int k = 0; k < 4; k++)
            {
                int nx = lx + (k == 0 ? 1 : k == 1 ? -1 : 0), ny = ly + (k == 2 ? 1 : k == 3 ? -1 : 0);
                if (nx < 0 || ny < 0 || nx >= wwid || ny >= whei) continue;
                int ni = ny * wwid + nx; if (obs[ni]) continue;
                int gx = nx + wx0, gy = ny + wy0; if (!M[gy * W + gx]) continue;
                double ddx = gx - cx, ddy = gy - cy; if (Math.Abs(Math.Sqrt(ddx * ddx + ddy * ddy) - R) < fBand) continue;
                obs[ni] = true; qu.Enqueue(ni);
            }
        }
        if (O < 8) return null;
        int Otot = 0; for (int q = 0; q < obs.Length; q++) if (obs[q]) Otot++;
        double[] X = new double[NPri], Y = new double[NPri], BX = new double[NBarb], BY = new double[NBarb];
        double[] bestByVal = new double[36]; for (int k = 0; k < 36; k++) bestByVal[k] = -1;
        double best = -1, bestDel = 0; int bestV = -1;
        for (int pass = 0; pass < 2; pass++)
        {
            double lo = pass == 0 ? -8 : bestDel - 1.5, hi = pass == 0 ? 8 : bestDel + 1.5, st = pass == 0 ? 2 : 0.5;
            for (int c = 0; c < 2; c++) for (int l = 0; l < 3; l++) for (int bb = 0; bb < 3; bb++)
                    {
                        if (pass == 1 && (18 * d + 9 * c + 3 * bb + l) != bestV) continue;
                        for (double del = lo; del <= hi + 0.001; del += st)
                        {
                            double th = bs[0] + del * s / pxPerDeg, x0, y0; Pt(cx, cy, R, th, out x0, out y0);
                            Centerline(x0, y0, th, d, c, Len[l] * s, X, Y);
                            stampId++; int P = 0, I = 0;
                            FillCount(TaperPoly(X, Y, PriW * s, 0.35), ref P, ref I);
                            int side = c == 0 ? -1 : 1;
                            int[] ks = bb == 0 ? new int[0] : bb == 1 ? new int[] { 11 } : new int[] { 7, 14 };
                            foreach (int k in ks) { Barb(X, Y, k, side, s, BX, BY); FillCount(TaperPoly(BX, BY, BarbW * s, 0.1), ref P, ref I); }
                            double iou = (double)I / (P + O - I);
                            int v = 18 * d + 9 * c + 3 * bb + l;
                            if (iou > bestByVal[v]) bestByVal[v] = iou;
                            if (iou > best) { best = iou; bestV = v; bestDel = del; }
                        }
                    }
        }
        double second = 0; for (int k = 0; k < 36; k++) if (k != bestV && bestByVal[k] > second) second = bestByVal[k];
        // barb count: measure each candidate barb position on pixels outside the main stroke
        double barbMargin = 1;
        {
            int c3 = (bestV % 18) / 9, l3 = bestV % 3;
            double th = bs[0] + bestDel * s / pxPerDeg, x0, y0; Pt(cx, cy, R, th, out x0, out y0);
            Centerline(x0, y0, th, d, c3, Len[l3] * s, X, Y);
            Collect = new List<int>(); stampId++; int pp = 0, ii = 0;
            FillCount(TaperPoly(X, Y, PriW * s + 3 * s, 0.35), ref pp, ref ii);
            Dictionary<int, bool> prim = new Dictionary<int, bool>(); foreach (int pi2 in Collect) prim[pi2] = true;
            int side3 = c3 == 0 ? -1 : 1; int[] kk = new int[] { 7, 11, 14 }; double[] cov = new double[3];
            for (int q0 = 0; q0 < 9; q0++)
            {
                int q = q0 / 3, kpos = kk[q] + (q0 % 3) - 1;
                Barb(X, Y, kpos, side3, s, BX, BY);
                Collect = new List<int>(); stampId++;
                FillCount(TaperPoly(BX, BY, BarbW * s, 0.1), ref pp, ref ii);
                int tot = 0, hit = 0, totAll = 0, hitAll = 0;
                foreach (int gi in Collect)
                {
                    if (prim.ContainsKey(gi)) continue;
                    totAll++; if (M[gi]) hitAll++;
                    if (Claim != null && (Claim[gi] > 0 || (gi + 1 < W * H && Claim[gi + 1] > 0) || (gi >= 1 && Claim[gi - 1] > 0) || (gi + W < W * H && Claim[gi + W] > 0) || (gi >= W && Claim[gi - W] > 0))) continue;
                    tot++; if (M[gi]) hit++;
                }
                // if neighbours' strokes hide most of this barb position, judge it on all its pixels
                double cv = (tot < 0.12 * totAll || tot == 0) ? 0.35 : (double)hit / tot;
                if (q0 % 3 == 0 || cv > cov[q]) cov[q] = cv;
            }
            Collect = null;
            // presence threshold 0.35; the pattern decides the count
            double T = 0.35; double[] sB = new double[3];
            sB[0] = Math.Min(Math.Min(T - cov[0], T - cov[1]), T - cov[2]);
            sB[1] = Math.Min(cov[1] - T, cov[1] - Math.Max(cov[0], cov[2]));
            sB[2] = Math.Min(Math.Min(cov[0] - T, cov[2] - T), Math.Min(cov[0], cov[2]) - cov[1]);
            int bbest = 0; for (int q = 1; q < 3; q++) if (sB[q] > sB[bbest]) bbest = q;
            double bsec = -1; for (int q = 0; q < 3; q++) if (q != bbest && sB[q] > bsec) bsec = sB[q];
            barbMargin = sB[bbest] - bsec; lastCov = cov;
            int newV = 18 * d + 9 * c3 + 3 * bbest + l3;
            if (newV != bestV) { bestV = newV; }
        }
        HsGlyphHit g = new HsGlyphHit();
        {
            int c2 = (bestV % 18) / 9, b2 = (bestV % 9) / 3, l2 = bestV % 3;
            double th = bs[0] + bestDel * s / pxPerDeg, x0, y0; Pt(cx, cy, R, th, out x0, out y0);
            Centerline(x0, y0, th, d, c2, Len[l2] * s, X, Y);
            Collect = new List<int>(); stampId++; int P0 = 0, I0 = 0;
            FillCount(TaperPoly(X, Y, PriW * s, 0.35), ref P0, ref I0);
            int side2 = c2 == 0 ? -1 : 1;
            int[] ks2 = b2 == 0 ? new int[0] : b2 == 1 ? new int[] { 11 } : new int[] { 7, 14 };
            foreach (int k in ks2) { Barb(X, Y, k, side2, s, BX, BY); FillCount(TaperPoly(BX, BY, BarbW * s, 0.1), ref P0, ref I0); }
            g.Pixels = Collect; Collect = null;
        }
        g.Base = bs; g.OwnFraction = (double)O / Math.Max(1, Otot);
        g.Band = band; g.Angle = Norm(bs[0] + bestDel * s / pxPerDeg); g.Value = bestV; g.D = d;
        g.C = (bestV % 18) / 9; g.B = (bestV % 9) / 3; g.L = bestV % 3;
        g.PrimaryScore = best; g.BarbScore = best;
        g.BarbMargin = barbMargin; g.BarbCov = lastCov;
        double pm = 1; { int cb = (bestV % 18) / 9, lb = bestV % 3; double alt = 0; for (int k = 0; k < 36; k++) { if (k / 18 != d) continue; if ((k % 18) / 9 == cb && k % 3 == lb) continue; if (bestByVal[k] > alt) alt = bestByVal[k]; } double own = 0; for (int bb2 = 0; bb2 < 3; bb2++) { int kv = 18 * d + 9 * cb + 3 * bb2 + lb; if (bestByVal[kv] > own) own = bestByVal[kv]; } pm = own - alt; g.PrimaryMargin = pm; }
        g.Confidence = Math.Min(1, best / 0.6) * Math.Min(1, Math.Max(0, pm) / 0.08) * Math.Min(1, Math.Max(0, barbMargin + 0.1) / 0.3);
        return g;
    }

    static bool NearBar(HsRasterResult res, int band, double ang, double tolDeg)
    {
        foreach (HsBar br in res.Bars) if (br.Band == band && Math.Abs(AngDiff(br.Angle, ang)) < tolDeg) return true;
        return false;
    }

    static void AddBase(List<double[]> bases, double[] run, int dir, double s, int band, HsRasterResult res)
    {
        if (run[1] < 2.5 * s) return;
        if (run[1] > 28 * s) { res.Unresolved.Add("band " + band + ": ink mass " + run[1].ToString("0") + "px wide at " + run[0].ToString("0.0") + " deg is not a single glyph base"); return; }
        bases.Add(new double[] { run[0], dir, run[1] });
    }

    static List<double[]> Runs(bool[] row, double da, double R)
    {
        List<double[]> runs = new List<double[]>(); int n = row.Length;
        int startIdx = -1; for (int i = 0; i < n; i++) if (!row[i]) { startIdx = i; break; }
        if (startIdx < 0) return runs;
        int len = 0, first = -1;
        for (int k = 1; k <= n; k++)
        {
            int i = (startIdx + k) % n;
            if (row[i]) { if (len == 0) first = k; len++; }
            if ((!row[i] || k == n) && len > 0)
            {
                double mid = (startIdx + first + (len - 1) / 2.0) * da;
                runs.Add(new double[] { Norm(mid), len * da * Math.PI * R / 180.0 });
                len = 0;
            }
        }
        return runs;
    }
    static double Norm(double a) { a = a % 360.0; if (a < 0) a += 360.0; return a; }
    static double AngDiff(double a, double b) { double d = Norm(a - b); if (d > 180) d -= 360; return d; }
    static double AngMid(double a, double b) { return Norm(b + AngDiff(a, b) / 2.0); }
    // Synthetic raster of structural polygons (even-odd fill per polygon, 2x2 supersampled).
    // Used by the server self-test to exercise the raster pipeline without a browser.
    public static byte[] RenderPolygons(List<double[]> polys, int w, int h, double scale, bool darkBg, int seed)
    {
        int W2 = w * 2, H2 = h * 2; bool[] hi = new bool[W2 * H2];
        List<double> xs = new List<double>();
        foreach (double[] p in polys)
        {
            int n = p.Length / 2; double minY = 1e9, maxY = -1e9;
            for (int i = 0; i < n; i++) { double yy = p[2 * i + 1] * scale * 2; if (yy < minY) minY = yy; if (yy > maxY) maxY = yy; }
            int y0 = Math.Max(0, (int)Math.Floor(minY)), y1 = Math.Min(H2 - 1, (int)Math.Ceiling(maxY));
            for (int y = y0; y <= y1; y++)
            {
                double sy = y + 0.5; xs.Clear();
                for (int i = 0; i < n; i++)
                {
                    int j = (i + 1) % n;
                    double ax = p[2 * i] * scale * 2, ay = p[2 * i + 1] * scale * 2, bx = p[2 * j] * scale * 2, by = p[2 * j + 1] * scale * 2;
                    if ((ay <= sy && by > sy) || (by <= sy && ay > sy)) xs.Add(ax + (sy - ay) / (by - ay) * (bx - ax));
                }
                xs.Sort();
                for (int k = 0; k + 1 < xs.Count; k += 2)
                {
                    int xa = Math.Max(0, (int)Math.Ceiling(xs[k] - 0.5)), xb = Math.Min(W2 - 1, (int)Math.Floor(xs[k + 1] - 0.5));
                    for (int x = xa; x <= xb; x++) hi[y * W2 + x] = true;
                }
            }
        }
        byte[] g = new byte[w * h]; Random rnd = new Random(seed);
        double bg = darkBg ? 12 : 236, ink = darkBg ? 240 : 22;
        for (int y = 0; y < h; y++) for (int x = 0; x < w; x++)
            {
                int c = 0; if (hi[(2 * y) * W2 + 2 * x]) c++; if (hi[(2 * y) * W2 + 2 * x + 1]) c++; if (hi[(2 * y + 1) * W2 + 2 * x]) c++; if (hi[(2 * y + 1) * W2 + 2 * x + 1]) c++;
                double v = bg + (ink - bg) * c / 4.0 + (rnd.NextDouble() - 0.5) * 30;
                if (rnd.NextDouble() < 0.002) v = bg + (ink - bg) * 0.5;
                g[y * w + x] = (byte)Math.Max(0, Math.Min(255, v));
            }
        return g;
    }
}
'@

# ------------------------------------------------------------- main
Say '=== Heptapod L Studio installer 1.1.1 ===' 'Cyan'
if ($PSVersionTable.PSVersion.Major -lt 5) { Say 'Windows PowerShell 5.1 or later is required.' 'Red'; Write-Result 'FAILED: Windows PowerShell 5.1 or later is required.'; return }
$hadOld = Test-Path $AppDir

# 1. backup
try {
    if ($hadOld) { Copy-Item -Path $AppDir -Destination $BackupDir -Recurse -Force; Say ('Backup: ' + $BackupDir) }
    if (Test-Path $Lnk) { $LnkBackup = Join-Path $env:TEMP ('HeptapodStudio-' + $Stamp + '.lnk'); Copy-Item $Lnk $LnkBackup -Force; Say 'Backed up Startup shortcut.' }
} catch { Say ('Backup failed, nothing changed: ' + $_.Exception.Message) 'Red'; Write-Result ('FAILED: backup failed - ' + $_.Exception.Message); return }

$failure = $null
try {
    # 2. port
    if (-not (Stop-OldStudio)) { throw "Port $Port unavailable." }
    # 3. files
    if (-not (Test-Path $AppDir)) { New-Item -ItemType Directory -Path $AppDir | Out-Null }
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText((Join-Path $AppDir 'server.ps1'), $ServerSource, $utf8Bom)
    [System.IO.File]::WriteAllText((Join-Path $AppDir 'index.html'), $IndexHtml, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText((Join-Path $AppDir 'hsraster.cs'), $RasterSource, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText((Join-Path $AppDir 'VERSION.txt'), "1.1.1 HL-1.1 Heptapod L installed $Stamp", $utf8Bom)
    Get-ChildItem $AppDir -Filter '*error.log' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    # syntax check before starting
    $tok = $null; $perr = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $AppDir 'server.ps1'), [ref]$tok, [ref]$perr)
    if ($perr.Count -gt 0) { throw ('server.ps1 syntax error: ' + $perr[0].Message + ' line ' + $perr[0].Extent.StartLineNumber) }
    Say 'Files written; server.ps1 parses cleanly.'
    New-Shortcut $AppDir; Say ('Startup shortcut: ' + $Lnk)
    # 4. start + verify
    Start-Studio $AppDir
    $h = $null
    for ($i = 0; $i -lt 40; $i++) { Start-Sleep -Milliseconds 750; try { $h = Invoke-Api '/api/health' $null 5; break } catch {} }
    if ($null -eq $h) {
        $el = Join-Path $AppDir 'server-error.log'; $detail = ''; if (Test-Path $el) { $detail = (Get-Content $el -Tail 3) -join ' | ' }
        throw ('Server did not answer on port ' + $Port + '. ' + $detail)
    }
    if ($h.engine -ne '1.1.1') { throw ('Wrong engine answered: ' + $h.engine) }
    Say ('Health: ok, engine ' + $h.engine + ', ' + $h.orthography) 'Green'
    if ($h.rasterEngine -ne 'ready') { throw ('Image decoder did not compile: ' + $h.rasterEngine) }
    Say 'Image decoder: compiled and ready.' 'Green'
    $e = Invoke-Api '/api/encode' @{ text = 'What is your name?' } 60
    if ($e.status -ne 'ok' -or $e.sentences.Count -ne 1 -or $e.sentences[0].svg -notmatch '^<svg') { throw 'Encode check failed.' }
    Say ('Encode: ok, origin ' + $e.sentences[0].startAngle + ' deg, units ' + $e.sentences[0].orthographic) 'Green'
    $d = Invoke-Api '/api/decode' @{ svg = $e.sentences[0].svg } 60
    if ($d.status -ne 'ok' -or $d.text -ne 'WHAT IS YOUR NAME?') { throw ('Geometric decode check failed: ' + $d.status + ' ' + $d.text) }
    Say ('Decode: ok, recovered "' + $d.text + '" from geometry, confidence ' + $d.confidence) 'Green'
    Say 'Running engine self-test (11 sentences + 4 images: encode, then decode from the drawing)...'
    $v = Invoke-Api '/api/validate?scope=smoke' $null 600
    $bad = @($v.sentences | Where-Object { -not $_.pass })
    $badImg = @($v.images | Where-Object { -not $_.pass })
    if ($v.status -ne 'ok') { throw ('Self-test failed: ' + ((@($bad) + @($badImg) | ForEach-Object { $_.input + ' -> ' + $_.decoded }) -join '; ')) }
    Say ('Self-test: ok, ' + $v.sentences.Count + ' sentences and ' + @($v.images).Count + ' images round-tripped in ' + $v.seconds + ' s') 'Green'
} catch { $failure = $_.Exception.Message }

if ($null -eq $failure) {
    Say ''
    Say "INSTALLED. Open http://localhost:$Port/" 'Cyan'
    Write-Result 'OK'
    if ($hadOld) { Say ('Previous version kept at ' + $BackupDir) }
    try { Start-Process "http://localhost:$Port/" } catch {}
    return
}

# 5. rollback
Say ('FAILED: ' + $failure) 'Red'
Say 'Rolling back...' 'Yellow'
try {
    $procs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" | Where-Object { $_.CommandLine -match '\\HeptapodStudio\\server\.ps1' -and $_.ProcessId -ne $PID })
    foreach ($p in $procs) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 1
    $keepLog = Join-Path $env:TEMP ('HeptapodStudio-failed-' + $Stamp + '.log')
    $el = Join-Path $AppDir 'server-error.log'; if (Test-Path $el) { Copy-Item $el $keepLog -Force }
    if ($hadOld) {
        Remove-Item -Path $AppDir -Recurse -Force
        Copy-Item -Path $BackupDir -Destination $AppDir -Recurse -Force
        Say 'Previous files restored.'
    } elseif (Test-Path $AppDir) { Remove-Item -Path $AppDir -Recurse -Force }
    if ($LnkBackup) { Copy-Item $LnkBackup $Lnk -Force; Say 'Previous Startup shortcut restored.' } elseif (Test-Path $Lnk) { Remove-Item $Lnk -Force }
    if ($State.StoppedOld -and (Test-Path $Lnk)) { Start-Process $Lnk; Say 'Previous server restarted from its shortcut.' }
    if (Test-Path $keepLog) { Say ('New server log kept at ' + $keepLog) }
    Say 'Rollback complete. Nothing from this install remains active.' 'Yellow'
    Write-Result ('FAILED: ' + $failure + ' (rolled back to the previous version)')
} catch { Say ('Rollback error: ' + $_.Exception.Message + ' - backup is at ' + $BackupDir) 'Red'; Write-Result ('FAILED: ' + $failure + ' / rollback error - backup at ' + $BackupDir) }
}
