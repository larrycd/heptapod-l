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
