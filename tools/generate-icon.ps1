<#
  Generates icon.ico (multi-size) for HashDiff.
  Run once: powershell -NoProfile -ExecutionPolicy Bypass -File generate-icon.ps1
  The design: a dark rounded tile with a bold cyan "#" (hash) glyph - a nod to the
  name and distinct from BranchDiff's green|rose bars.
#>
param([string]$OutPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'icon.ico'))

Add-Type -AssemblyName System.Drawing

function Add-RoundedRect($path, [single]$x, [single]$y, [single]$w, [single]$h, [single]$r) {
    $d = $r * 2
    $path.AddArc($x,            $y,            $d, $d, 180, 90)
    $path.AddArc($x + $w - $d,  $y,            $d, $d, 270, 90)
    $path.AddArc($x + $w - $d,  $y + $h - $d,  $d, $d,   0, 90)
    $path.AddArc($x,            $y + $h - $d,  $d, $d,  90, 90)
    $path.CloseFigure()
}

function New-IconBitmap([int]$s) {
    $f = $s / 256.0
    $bmp = New-Object System.Drawing.Bitmap($s, $s, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    # Background tile with vertical gradient
    $bg = New-Object System.Drawing.Drawing2D.GraphicsPath
    Add-RoundedRect $bg (8*$f) (8*$f) (240*$f) (240*$f) (44*$f)
    $bgRect = New-Object System.Drawing.RectangleF((8*$f), (8*$f), (240*$f), (240*$f))
    $bgBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        $bgRect,
        [System.Drawing.Color]::FromArgb(255, 32, 44, 72),
        [System.Drawing.Color]::FromArgb(255, 14, 22, 46),
        90)
    $g.FillPath($bgBrush, $bg)

    # Bold "#" glyph in bright cyan: two vertical + two horizontal thick strokes with
    # rounded caps. Big, simple strokes stay crisp down to 16px.
    $cyan = [System.Drawing.Color]::FromArgb(255, 56, 189, 248)
    $pen = New-Object System.Drawing.Pen($cyan, (26 * $f))
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round
    # verticals (slightly inset from the horizontals' span)
    $g.DrawLine($pen, (100*$f), (52*$f),  (88*$f),  (204*$f))
    $g.DrawLine($pen, (168*$f), (52*$f),  (156*$f), (204*$f))
    # horizontals
    $g.DrawLine($pen, (56*$f),  (104*$f), (200*$f), (104*$f))
    $g.DrawLine($pen, (52*$f),  (152*$f), (196*$f), (152*$f))
    $pen.Dispose()

    $g.Dispose()
    return $bmp
}

# Build an uncompressed BMP/DIB icon image (BITMAPINFOHEADER + 32bpp XOR + AND mask).
# Classic format — fully supported by .NET's Icon class and ToBitmap (unlike PNG entries).
function New-IconDib([System.Drawing.Bitmap]$bmp) {
    $w = $bmp.Width; $h = $bmp.Height
    $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
    $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
                          [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $stride = $data.Stride
    $buf = New-Object byte[] ($stride * $h)
    [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $buf, 0, $buf.Length)
    $bmp.UnlockBits($data)

    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    # BITMAPINFOHEADER (height doubled: XOR image + AND mask)
    $bw.Write([uint32]40); $bw.Write([int32]$w); $bw.Write([int32]($h * 2))
    $bw.Write([uint16]1); $bw.Write([uint16]32); $bw.Write([uint32]0)
    $bw.Write([uint32]0); $bw.Write([int32]0); $bw.Write([int32]0)
    $bw.Write([uint32]0); $bw.Write([uint32]0)
    # XOR pixels, bottom-up rows, BGRA
    for ($y = $h - 1; $y -ge 0; $y--) {
        $bw.Write($buf, $y * $stride, $w * 4)
    }
    # AND mask: 1 bpp, rows padded to 32 bits, all zero (alpha drives transparency)
    $maskRow = [int]([math]::Floor(($w + 31) / 32)) * 4
    $bw.Write((New-Object byte[] ($maskRow * $h)))
    $bw.Flush()
    $bytes = $ms.ToArray()
    $bw.Dispose(); $ms.Dispose()
    return ,$bytes
}

$sizes = 16, 24, 32, 48, 64, 128, 256
$images = @()
foreach ($s in $sizes) {
    $bmp = New-IconBitmap $s
    $images += ,(New-IconDib $bmp)
    $bmp.Dispose()
}

# Assemble ICO
$out = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter($out)
$bw.Write([uint16]0)              # reserved
$bw.Write([uint16]1)              # type = icon
$bw.Write([uint16]$sizes.Count)   # image count

$offset = 6 + (16 * $sizes.Count)
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $s = $sizes[$i]; $len = $images[$i].Length
    $dim = if ($s -ge 256) { 0 } else { $s }
    $bw.Write([byte]$dim)         # width
    $bw.Write([byte]$dim)         # height
    $bw.Write([byte]0)            # palette
    $bw.Write([byte]0)            # reserved
    $bw.Write([uint16]1)          # color planes
    $bw.Write([uint16]32)         # bits per pixel
    $bw.Write([uint32]$len)       # size of image data
    $bw.Write([uint32]$offset)    # offset
    $offset += $len
}
foreach ($img in $images) { $bw.Write($img) }
$bw.Flush()
[System.IO.File]::WriteAllBytes($OutPath, $out.ToArray())
$bw.Dispose(); $out.Dispose()
Write-Host "Wrote $OutPath ($([math]::Round((Get-Item $OutPath).Length/1kb,1)) KB, $($sizes.Count) sizes)"
