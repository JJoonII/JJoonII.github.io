#Requires -Version 5.1
<#
.SYNOPSIS
    홈페이지에 올릴 mp4를 웹 배포용 크기로 압축한다.

.DESCRIPTION
    ffmpeg으로 mp4를 다시 인코딩한다.
      - 폭을 -Width(기본 1280)로 축소한다. 원본이 이미 더 좁으면 그대로 둔다.
      - H.264 / CRF -Crf(기본 24) / preset -Preset(기본 slow) / yuv420p
        yuv420p는 브라우저 호환성을 위한 것이니 바꾸지 않는 편이 좋다.
      - +faststart 로 moov 박스를 파일 앞으로 보낸다. 다 받기 전에 재생이 시작된다.
      - 무음 오디오 트랙은 자동으로 버린다(-KeepAudio 로 끌 수 있다).
        데모 영상은 보통 무음인데 그냥 두면 수 MB를 잡아먹는다.

    원본은 같은 폴더의 _originals\ 로 옮겨 보관한다. 이 폴더는 .gitignore에서
    제외되어 있으므로 커밋되지 않는다. 이미 _originals\ 에 같은 이름이 있으면
    "전에 압축한 파일"로 보고 건너뛴다. 즉 이 스크립트는 여러 번 돌려도 안전하다.

    ffmpeg이 PATH에 없으면 %LOCALAPPDATA%\ffmpeg-static\ 에 자동으로 내려받아 캐시한다.
    시스템 설치가 아니라 압축만 푸는 것이라 관리자 권한도, PATH 변경도 필요 없다.
    저장소가 OneDrive 안에 있으므로 일부러 저장소 밖에 둔다. 안에 두면 300MB가
    통째로 동기화된다. 한 번 받아두면 다음 실행부터는 바로 쓴다.

.PARAMETER Path
    압축할 mp4 경로. 생략하면 images\video\*.mp4 전부를 대상으로 한다.

.EXAMPLE
    .\tools\compress-video.ps1
    # images\video 안의 아직 압축 안 한 mp4를 전부 처리한다

.EXAMPLE
    .\tools\compress-video.ps1 images\video\Real2Sim_VLA.mp4

.EXAMPLE
    .\tools\compress-video.ps1 images\video\demo.mp4 -Width 960 -Crf 28
    # 더 작게. 화질은 조금 포기한다

.NOTES
    화면에서 520px 폭으로 보여주는 영상이라면 1280px로도 레티나(2배)까지 커버된다.
    파일이 여전히 크면 -Width 를 먼저 줄이고, 그래도 크면 -Crf 를 올린다.
    CRF는 값이 클수록 화질이 낮고 파일이 작다. 18=거의 무손실, 23=기본, 28=눈에 띄게 열화.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string[]]$Path,

    [int]$Width = 1280,

    [ValidateRange(0, 51)]
    [int]$Crf = 24,

    [ValidateSet('ultrafast', 'superfast', 'veryfast', 'faster', 'fast',
                 'medium', 'slow', 'slower', 'veryslow')]
    [string]$Preset = 'slow',

    [switch]$KeepAudio
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
# 저장소가 OneDrive 안이라 ffmpeg 캐시는 밖(LOCALAPPDATA)에 둔다. 동기화 대상에서 빠진다.
$FFmpegDir = Join-Path $env:LOCALAPPDATA 'ffmpeg-static'

# ffmpeg은 stderr로 로그를 뱉는다. PS 5.1에서 native 명령에 2>&1을 쓰면 각 줄이
# ErrorRecord로 감싸이고 $?가 false가 되므로, EAP를 잠시 낮추고 문자열로 되돌린다.
function Invoke-Capture {
    param([string]$Exe, [string[]]$Arguments)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = & $Exe @Arguments 2>&1
        return ($raw | ForEach-Object { $_.ToString() }) -join "`n"
    }
    finally { $ErrorActionPreference = $prev }
}

function Resolve-FFmpeg {
    # 1) 전에 이 스크립트가 받아둔 것
    if (Test-Path $FFmpegDir) {
        $local = Get-ChildItem -Path $FFmpegDir -Filter 'ffmpeg.exe' -Recurse -ErrorAction SilentlyContinue |
                 Select-Object -First 1
        if ($local) { return $local.Directory.FullName }
    }
    # 2) 시스템에 이미 깔려 있는 것
    $onPath = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($onPath) { return (Split-Path -Parent $onPath.Source) }

    # 3) 없으면 내려받는다.
    #    gyan.dev 미러는 느릴 때가 있어(30KB/s를 본 적이 있다) GitHub 쪽을 쓴다.
    Write-Host "ffmpeg이 없다. $FFmpegDir 에 내려받는다 (약 160MB, 설치 아님)..." -ForegroundColor Yellow
    New-Item -ItemType Directory -Force $FFmpegDir | Out-Null
    $zip = Join-Path $FFmpegDir 'ffmpeg.zip'
    $url = 'https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip'
    & curl.exe -L --fail --progress-bar -o $zip $url
    if (-not (Test-Path $zip)) { throw "ffmpeg 내려받기에 실패했다: $url" }
    Expand-Archive -Path $zip -DestinationPath $FFmpegDir -Force
    Remove-Item $zip -Force
    $exe = Get-ChildItem -Path $FFmpegDir -Filter 'ffmpeg.exe' -Recurse | Select-Object -First 1
    if (-not $exe) { throw "압축은 풀렸는데 ffmpeg.exe가 없다. $FFmpegDir 를 지우고 다시 시도해라." }
    Write-Host "  받았다: $($exe.FullName)" -ForegroundColor Green
    return $exe.Directory.FullName
}

function Get-VideoInfo {
    param([string]$FFprobe, [string]$File)
    $json = Invoke-Capture $FFprobe @(
        '-v', 'error', '-print_format', 'json',
        '-show_entries', 'format=duration,size',
        '-show_entries', 'stream=index,codec_type,codec_name,width,height',
        $File
    )
    return ($json | ConvertFrom-Json)
}

# 오디오가 사실상 무음인지 본다. 무음이면 트랙째 버려도 잃을 게 없다.
function Test-AudioIsSilent {
    param([string]$FFmpeg, [string]$File)
    $out = Invoke-Capture $FFmpeg @(
        '-hide_banner', '-nostats', '-i', $File, '-map', '0:a', '-af', 'volumedetect', '-f', 'null', '-'
    )
    if ($out -notmatch 'max_volume:\s*(-?[\d.]+) dB') { return $true }  # 오디오 스트림 자체가 없다
    return ([double]$Matches[1] -le -60)
}

function Format-Size {
    param([long]$Bytes)
    if ($Bytes -ge 1MB) { return "$([math]::Round($Bytes / 1MB, 2)) MB" }
    return "$([math]::Round($Bytes / 1KB, 1)) KB"
}

# --- 대상 정하기 ---------------------------------------------------------
if (-not $Path -or $Path.Count -eq 0) {
    $defaultDir = Join-Path $RepoRoot 'images\video'
    if (-not (Test-Path $defaultDir)) { throw "기본 대상 폴더가 없다: $defaultDir" }
    $Path = @(Get-ChildItem -Path $defaultDir -Filter '*.mp4' -File | ForEach-Object { $_.FullName })
    if ($Path.Count -eq 0) { Write-Host "images\video 에 mp4가 없다."; return }
    Write-Host "대상을 지정하지 않았으므로 images\video\*.mp4 를 훑는다 ($($Path.Count)개)." -ForegroundColor Cyan
}

$binDir  = Resolve-FFmpeg
$ffmpeg  = Join-Path $binDir 'ffmpeg.exe'
$ffprobe = Join-Path $binDir 'ffprobe.exe'

$totalBefore = 0L
$totalAfter  = 0L
$done = 0

foreach ($p in $Path) {
    if (-not (Test-Path -LiteralPath $p)) { Write-Warning "없는 파일이라 건너뛴다: $p"; continue }
    $file = Get-Item -LiteralPath $p

    $dir     = $file.Directory.FullName
    $origDir = Join-Path $dir '_originals'
    $backup  = Join-Path $origDir $file.Name

    Write-Host ""
    Write-Host "== $($file.Name)" -ForegroundColor Cyan

    if (Test-Path -LiteralPath $backup) {
        Write-Host "   _originals\ 에 원본이 이미 있다. 압축된 파일로 보고 건너뛴다." -ForegroundColor DarkGray
        continue
    }

    $info  = Get-VideoInfo $ffprobe $file.FullName
    $vs    = $info.streams | Where-Object { $_.codec_type -eq 'video' } | Select-Object -First 1
    $hasAudio = [bool]($info.streams | Where-Object { $_.codec_type -eq 'audio' })
    if (-not $vs) { Write-Warning "비디오 스트림이 없다. 건너뛴다."; continue }

    $srcW = [int]$vs.width
    $srcH = [int]$vs.height
    Write-Host ("   원본: {0}x{1}, {2}, {3}" -f $srcW, $srcH, (Format-Size $file.Length),
                                              ([math]::Round([double]$info.format.duration, 1)).ToString() + 's')

    # 원본이 목표 폭보다 좁으면 확대하지 않는다. 확대는 용량만 늘고 화질은 그대로다.
    $targetW = [math]::Min($Width, $srcW)
    $scale   = "scale=${targetW}:-2"

    $dropAudio = $false
    if ($hasAudio -and -not $KeepAudio) {
        if (Test-AudioIsSilent $ffmpeg $file.FullName) {
            $dropAudio = $true
            Write-Host "   오디오가 무음이라 트랙을 버린다." -ForegroundColor DarkGray
        }
    }

    $tmpOut = Join-Path $dir ("_compress_tmp_" + $file.BaseName + ".mp4")
    if (Test-Path -LiteralPath $tmpOut) { Remove-Item -LiteralPath $tmpOut -Force }

    $ffArgs = @(
        '-hide_banner', '-loglevel', 'warning', '-stats', '-y',
        '-i', $file.FullName,
        '-vf', $scale,
        '-c:v', 'libx264', '-crf', "$Crf", '-preset', $Preset, '-pix_fmt', 'yuv420p',
        '-movflags', '+faststart'
    )
    if ($dropAudio -or -not $hasAudio) { $ffArgs += '-an' }
    else { $ffArgs += @('-c:a', 'aac', '-b:a', '96k') }
    $ffArgs += $tmpOut

    Write-Host "   인코딩: ${targetW}px / CRF $Crf / preset $Preset ..."
    & $ffmpeg @ffArgs
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $tmpOut)) {
        if (Test-Path -LiteralPath $tmpOut) { Remove-Item -LiteralPath $tmpOut -Force }
        Write-Warning "인코딩에 실패했다(exit $LASTEXITCODE). 원본은 건드리지 않았다."
        continue
    }

    $newSize = (Get-Item -LiteralPath $tmpOut).Length
    if ($newSize -ge $file.Length) {
        Remove-Item -LiteralPath $tmpOut -Force
        Write-Host "   결과가 원본보다 크거나 같다($(Format-Size $newSize)). 원본을 그대로 둔다." -ForegroundColor Yellow
        continue
    }

    New-Item -ItemType Directory -Force $origDir | Out-Null
    Move-Item -LiteralPath $file.FullName -Destination $backup
    Move-Item -LiteralPath $tmpOut -Destination $file.FullName

    $pct = [math]::Round((1 - $newSize / $file.Length) * 100, 1)
    Write-Host ("   -> {0} ({1}% 감소). 원본은 _originals\ 에 있다." -f (Format-Size $newSize), $pct) -ForegroundColor Green

    $totalBefore += $file.Length
    $totalAfter  += $newSize
    $done++
}

Write-Host ""
if ($done -gt 0) {
    $pct = [math]::Round((1 - $totalAfter / $totalBefore) * 100, 1)
    Write-Host ("완료: {0}개, {1} -> {2} ({3}% 감소)" -f $done, (Format-Size $totalBefore), (Format-Size $totalAfter), $pct) -ForegroundColor Green
    Write-Host "HTML의 aspect-ratio 값을 쓰고 있다면 새 해상도에 맞게 확인해라." -ForegroundColor DarkGray
} else {
    Write-Host "압축한 파일이 없다."
}
