<#
.SYNOPSIS
  UtilMonster.ico 를 그려서 만든다 (16~256px 다중 크기). 디자인을 바꾸려면 이 파일을 고치고 다시 실행.
  사용: .\MakeIcon.ps1 [-Out ..\UtilMonster.ico] [-Preview 미리보기.png]
#>
param(
    [string]$Out = (Join-Path $PSScriptRoot '..\UtilMonster.ico'),
    [string]$Preview
)
Add-Type -AssemblyName System.Drawing
$ErrorActionPreference = 'Stop'

function C([string]$hex) { [System.Drawing.ColorTranslator]::FromHtml($hex) }

function New-RoundRect([float]$x, [float]$y, [float]$w, [float]$h, [float]$r) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $r * 2
    $p.AddArc($x, $y, $d, $d, 180, 90)
    $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    $p
}

function New-GearPath([float]$cx, [float]$cy, [float]$ro, [float]$ri, [int]$teeth) {
    $pts = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]'
    for ($i = 0; $i -lt $teeth; $i++) {
        $a0 = 2 * [math]::PI * $i / $teeth
        $step = 2 * [math]::PI / $teeth
        foreach ($f in @(@(0.0, $ri), @(0.18, $ro), @(0.42, $ro), @(0.60, $ri))) {
            $a = $a0 + $f[0] * $step * 1.6 - $step * 0.2
            $pts.Add((New-Object System.Drawing.PointF(($cx + $f[1] * [math]::Cos($a)), ($cy + $f[1] * [math]::Sin($a)))))
        }
    }
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $p.AddPolygon($pts.ToArray())
    $p
}

# 256x256 기준 좌표로 그린다
function Draw-Icon([int]$size, [bool]$detail) {
    $bmp = New-Object System.Drawing.Bitmap(256, 256, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)

    # 배경: 둥근 사각형 + 남색 그라데이션
    $bgPath = New-RoundRect 6 6 244 244 54
    $bg = New-Object System.Drawing.Drawing2D.LinearGradientBrush((New-Object System.Drawing.Point(0, 0)), (New-Object System.Drawing.Point(0, 256)), (C '#6C7BFF'), (C '#2A2E8A'))
    $g.FillPath($bg, $bgPath)

    # 뿔
    $horn = New-Object System.Drawing.SolidBrush((C '#FFE08A'))
    $g.FillPolygon($horn, @((New-Object System.Drawing.PointF(66, 96)), (New-Object System.Drawing.PointF(76, 30)), (New-Object System.Drawing.PointF(112, 82))))
    $g.FillPolygon($horn, @((New-Object System.Drawing.PointF(190, 96)), (New-Object System.Drawing.PointF(180, 30)), (New-Object System.Drawing.PointF(144, 82))))

    # 몸통: 라임색 둥글둥글한 덩어리
    $bodyPath = New-RoundRect 34 64 188 164 70
    $body = New-Object System.Drawing.Drawing2D.LinearGradientBrush((New-Object System.Drawing.Point(0, 64)), (New-Object System.Drawing.Point(0, 228)), (C '#B8F55A'), (C '#33B864'))
    $g.FillPath($body, $bodyPath)
    $outline = New-Object System.Drawing.Pen((C '#1E7A45'), 5)
    $g.DrawPath($outline, $bodyPath)

    # 눈
    $white = [System.Drawing.Brushes]::White
    $black = New-Object System.Drawing.SolidBrush((C '#14143A'))
    $g.FillEllipse($white, 62, 96, 60, 66)
    $g.FillEllipse($white, 134, 96, 60, 66)
    $g.FillEllipse($black, 80, 116, 28, 34)
    $g.FillEllipse($black, 148, 116, 28, 34)
    if ($detail) {
        $g.FillEllipse($white, 90, 122, 9, 9)
        $g.FillEllipse($white, 158, 122, 9, 9)
    }

    # 입 + 이빨
    $mouthPath = New-Object System.Drawing.Drawing2D.GraphicsPath
    $mouthPath.AddArc(78, 160, 100, 56, 0, 180)
    $mouthPath.CloseFigure()
    $g.FillPath($black, $mouthPath)
    $g.SetClip($mouthPath)
    foreach ($x in 88, 116, 144) {
        $g.FillPolygon($white, @((New-Object System.Drawing.PointF($x, 186)), (New-Object System.Drawing.PointF(($x + 26), 186)), (New-Object System.Drawing.PointF(($x + 13), 210))))
    }
    $g.ResetClip()
    $g.DrawArc((New-Object System.Drawing.Pen((C '#14143A'), 5)), 78, 160, 100, 56, 0, 180)

    # 톱니바퀴 (유틸리티 상징) - 큰 크기에서만
    if ($detail) {
        $gear = New-GearPath 204 204 40 30 8
        $gearBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush((New-Object System.Drawing.Point(170, 170)), (New-Object System.Drawing.Point(240, 240)), (C '#FFC93C'), (C '#F08A1C'))
        $g.FillPath($gearBrush, $gear)
        $g.DrawPath((New-Object System.Drawing.Pen((C '#9A4E08'), 4)), $gear)
        $g.FillEllipse((New-Object System.Drawing.SolidBrush((C '#2A2E8A'))), 190, 190, 28, 28)
    }
    $g.Dispose()

    if ($size -eq 256) { return $bmp }
    $out = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g2 = [System.Drawing.Graphics]::FromImage($out)
    $g2.InterpolationMode = 'HighQualityBicubic'
    $g2.PixelOffsetMode = 'HighQuality'
    $g2.SmoothingMode = 'HighQuality'
    $g2.DrawImage($bmp, 0, 0, $size, $size)
    $g2.Dispose()
    $bmp.Dispose()
    $out
}

# 32bpp 비트맵 -> ICO 안의 DIB 데이터 (BITMAPINFOHEADER + 아래→위 BGRA + AND 마스크)
function ConvertTo-Dib([System.Drawing.Bitmap]$bmp) {
    $w = $bmp.Width; $h = $bmp.Height
    $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
    $data = $bmp.LockBits($rect, 'ReadOnly', [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $raw = New-Object byte[] ($data.Stride * $h)
    [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $raw, 0, $raw.Length)
    $bmp.UnlockBits($data)

    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $bw.Write([int]40); $bw.Write([int]$w); $bw.Write([int]($h * 2))
    $bw.Write([int16]1); $bw.Write([int16]32); $bw.Write([int]0); $bw.Write([int]0)
    $bw.Write([int]0); $bw.Write([int]0); $bw.Write([int]0); $bw.Write([int]0)
    for ($y = $h - 1; $y -ge 0; $y--) { $bw.Write($raw, $y * $data.Stride, $w * 4) }
    $maskRow = [int]([math]::Ceiling($w / 32.0) * 4)
    $bw.Write((New-Object byte[] ($maskRow * $h)))
    $bw.Flush()
    , $ms.ToArray()
}

$sizes = 16, 20, 24, 32, 40, 48, 64, 128, 256
$images = @()
foreach ($s in $sizes) {
    $bmp = Draw-Icon $s ($s -ge 48)
    if ($s -eq 256) {
        if ($Preview) { $bmp.Save($Preview, [System.Drawing.Imaging.ImageFormat]::Png) }
        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $bytes = $ms.ToArray()
    }
    else { $bytes = ConvertTo-Dib $bmp }
    $images += [pscustomobject]@{ Size = $s; Bytes = $bytes }
    $bmp.Dispose()
}

$fs = [System.IO.File]::Create([System.IO.Path]::GetFullPath($Out))
$bw = New-Object System.IO.BinaryWriter($fs)
$bw.Write([int16]0); $bw.Write([int16]1); $bw.Write([int16]$images.Count)
$offset = 6 + 16 * $images.Count
foreach ($i in $images) {
    $dim = if ($i.Size -ge 256) { 0 } else { $i.Size }
    $bw.Write([byte]$dim); $bw.Write([byte]$dim); $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([int16]1); $bw.Write([int16]32)
    $bw.Write([int]$i.Bytes.Length); $bw.Write([int]$offset)
    $offset += $i.Bytes.Length
}
foreach ($i in $images) { $bw.Write($i.Bytes) }
$bw.Close()
Write-Host ("아이콘 생성: {0}  ({1}개 크기: {2})" -f [System.IO.Path]::GetFullPath($Out), $images.Count, ($sizes -join ','))
