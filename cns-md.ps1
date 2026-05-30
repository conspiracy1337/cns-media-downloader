$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# --- Color helpers ---

function Write-Header($text) {
    Write-Host ""
    Write-Host "  $text" -ForegroundColor Cyan
    Write-Host ("  " + ("-" * $text.Length)) -ForegroundColor DarkCyan
}

function Write-Option($num, $label) {
    Write-Host -NoNewline "  "
    Write-Host -NoNewline "[$num]" -ForegroundColor Yellow
    Write-Host " $label"
}

function Write-Status($text)  { Write-Host "  $text" -ForegroundColor Cyan }
function Write-Ok($text)      { Write-Host "  $text" -ForegroundColor Green }
function Write-Warn($text)    { Write-Host "  $text" -ForegroundColor DarkYellow }
function Write-Err($text)     { Write-Host "  $text" -ForegroundColor Red }

function Read-Key {
    $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    Write-Host $key.Character -ForegroundColor Yellow
    return [string]$key.Character
}

# --- Auto-setup ---

function Download-File($url, $dest) {
    Write-Status "Downloading $(Split-Path -Leaf $dest)..."
    Start-BitsTransfer -Source $url -Destination $dest
}

if (-not (Test-Path "$ScriptDir\dl")) {
    New-Item -ItemType Directory -Path "$ScriptDir\dl" | Out-Null
}

$runBat = "$ScriptDir\run.bat"
if (-not (Test-Path $runBat)) {
    Set-Content -Path $runBat -Value "@echo off`r`npowershell -ExecutionPolicy Bypass -File `"%~dp0cns-md.ps1`""
}

function Update-YtDlp {
    $versionFile = "$ScriptDir\dlp-version.txt"
    $apiUrl = "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest"

    Write-Status "Checking yt-dlp version..."
    try {
        $release = Invoke-RestMethod -Uri $apiUrl -Headers @{ "User-Agent" = "cns media downloader" }
        $latestVersion = $release.tag_name
    } catch {
        Write-Warn "Could not reach GitHub API, skipping version check."
        return
    }

    $installedVersion = if (Test-Path $versionFile) { Get-Content $versionFile -Raw | ForEach-Object { $_.Trim() } } else { "" }

    if ($installedVersion -eq $latestVersion) {
        Write-Ok "yt-dlp is up to date ($latestVersion)."
        return
    }

    if ($installedVersion -eq "") {
        Write-Status "Installing yt-dlp $latestVersion..."
    } else {
        Write-Status "Updating yt-dlp $installedVersion -> $latestVersion..."
    }

    Download-File "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe" "$ScriptDir\yt-dlp.exe"
    Set-Content -Path $versionFile -Value $latestVersion
    Write-Ok "yt-dlp $latestVersion ready."
}

Clear-Host
Write-Host ""
Write-Host "  +-----------------------+" -ForegroundColor Cyan
Write-Host -NoNewline "  | " -ForegroundColor Cyan
Write-Host -NoNewline "cns' media downloader" -ForegroundColor White
Write-Host " |" -ForegroundColor Cyan
Write-Host "  +-----------------------+" -ForegroundColor Cyan

if (-not (Test-Path "$ScriptDir\yt-dlp.exe")) {
    Write-Host ""
    Write-Warn "yt-dlp not found. Setting up..."
    Update-YtDlp
} else {
    Write-Host ""
    Update-YtDlp
}

$ffmpegLocation = $null

$systemFfmpeg = Get-Command ffmpeg -ErrorAction SilentlyContinue
if ($systemFfmpeg) {
    Write-Ok "ffmpeg found in PATH: $($systemFfmpeg.Source)"
    $ffmpegLocation = $null
}
else {
    $localFfmpeg = "$ScriptDir\ffmpeg\ffmpeg.exe"
    if (Test-Path $localFfmpeg) {
        Write-Ok "ffmpeg found locally: $localFfmpeg"
        $ffmpegLocation = "$ScriptDir\ffmpeg"
    }
    else {
        Write-Host ""
        Write-Warn "ffmpeg not found in PATH or locally. One-time setup (~200 MB download)..."
        $zipPath = "$ScriptDir\ffmpeg.zip"

        Download-File "https://github.com/BtbN/FFmpeg-Builds/releases/latest/download/ffmpeg-master-latest-win64-gpl.zip" $zipPath

        Write-Status "Extracting ffmpeg to .\ffmpeg ..."
        $ffmpegFolder = "$ScriptDir\ffmpeg"
        if (-not (Test-Path $ffmpegFolder)) {
            New-Item -ItemType Directory -Path $ffmpegFolder | Out-Null
        }

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
        foreach ($entry in $zip.Entries) {
            if ($entry.Name -eq "ffmpeg.exe" -or $entry.Name -eq "ffprobe.exe") {
                $destFile = "$ffmpegFolder\$($entry.Name)"
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $destFile, $true)
                Write-Ok "Extracted $($entry.Name) to ffmpeg\"
            }
        }
        $zip.Dispose()
        Remove-Item $zipPath -Force

        $ffmpegLocation = "$ScriptDir\ffmpeg"
        Write-Ok "ffmpeg setup complete (local copy in ffmpeg\ folder)"
    }
}

# --- Helpers ---

$audioExts = @("mp3", "flac", "aac", "ogg", "wav", "opus", "m4a", "wma", "vorbis")

function Build-DlArgs($format, $resolution, $ffmpegLoc, $outputTemplate) {
    $resCap    = if ($resolution) { "[height<=$resolution]" } else { "" }
    $mp4Format = "bestvideo[vcodec^=avc1]$resCap+bestaudio[acodec^=mp4a]/bestvideo[vcodec^=avc1]$resCap+bestaudio/bestvideo$resCap+bestaudio/best"

    $dlArgs = @()
    if ($ffmpegLoc) { $dlArgs += "--ffmpeg-location", $ffmpegLoc }

    if ($format -eq "mp4") {
        $dlArgs += "--merge-output-format", "mp4", "-f", $mp4Format
    } elseif ($format -eq "mp3") {
        $dlArgs += "-x", "--audio-format", "mp3", "--embed-thumbnail", "--add-metadata"
    } elseif ($audioExts -contains $format) {
        $dlArgs += "-x", "--audio-format", $format, "--add-metadata"
    } else {
        $dlArgs += "--remux-video", $format, "-f", "bestvideo[vcodec^=avc1]+bestaudio/best"
    }

    $dlArgs += "--windows-filenames", "-o", $outputTemplate
    return $dlArgs
}

function Run-Download($url, $format, $resolution, $ffmpegLoc) {
    $ytdlp    = "$ScriptDir\yt-dlp.exe"
    $baseArgs = Build-DlArgs $format $resolution $ffmpegLoc "dl/%(title)s.%(ext)s"

    Write-Host ""
    & $ytdlp ($baseArgs + @($url))

    if ($LASTEXITCODE -ne 0) {
        Write-Err "Download failed (exit code $LASTEXITCODE)."
    } else {
        Write-Ok "Done! File saved to the dl\ folder."
    }
}

function Get-PlaylistEntries($url) {
    $ytdlp = "$ScriptDir\yt-dlp.exe"
    Write-Status "Fetching info..."
    $lines = & $ytdlp --flat-playlist --print "%(url)s`t%(title)s" --quiet $url 2>$null
    if (-not $lines) { return @() }
    return @($lines) | ForEach-Object {
        $parts = $_ -split "`t", 2
        [PSCustomObject]@{
            Url   = $parts[0]
            Title = if ($parts.Count -gt 1 -and $parts[1]) { $parts[1] } else { $parts[0] }
        }
    }
}

function Invoke-PlaylistDownload($entries, $baseArgs) {
    $ytdlp    = "$ScriptDir\yt-dlp.exe"
    $logDir   = "$ScriptDir\logs"
    $maxConc  = 10
    $dailyLog = "$logDir\$(Get-Date -Format 'yyyy-MM-dd').log"

    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }

    $total   = $entries.Count
    $queue   = [System.Collections.Generic.Queue[object]]::new()
    $idx     = 0
    foreach ($e in $entries) { $idx++; $queue.Enqueue(@{ Entry = $e; Index = $idx }) }

    $running = @()
    $done    = 0
    $failed  = 0

    Write-Host ""

    while ($queue.Count -gt 0 -or $running.Count -gt 0) {
        while ($running.Count -lt $maxConc -and $queue.Count -gt 0) {
            $item    = $queue.Dequeue()
            $e       = $item.Entry
            $i       = $item.Index
            $outLog  = "$logDir\_tmp_$i.txt"
            $errLog  = "$logDir\_tmp_${i}_err.txt"
            $paddedIdx = $i.ToString('D3')
            $allArgs   = @()
            $skipNext  = $false
            foreach ($arg in $baseArgs) {
                if ($skipNext) { $allArgs += "dl/${paddedIdx}_%(title)s.%(ext)s"; $skipNext = $false; continue }
                if ($arg -eq '-o') { $allArgs += $arg; $skipNext = $true; continue }
                $allArgs += $arg
            }
            $allArgs += $e.Url
            try {
                $proc = Start-Process -FilePath $ytdlp -ArgumentList $allArgs `
                    -RedirectStandardOutput $outLog -RedirectStandardError $errLog `
                    -NoNewWindow -PassThru
                $running += @{ Proc = $proc; Index = $i; Title = $e.Title; OutLog = $outLog; ErrLog = $errLog }
            } catch {
                Write-Host ("`r  [FAIL] $i. $($e.Title)" + (" " * 20)) -ForegroundColor Red
                $failed++
            }
        }

        $stillRunning = @()
        foreach ($job in $running) {
            if ($job.Proc.HasExited) {
                $exitCode     = try { $job.Proc.ExitCode } catch { -1 }
                $hasRealError = $false
                if ($exitCode -ne 0) {
                    $errContent   = if (Test-Path $job.ErrLog) { Get-Content $job.ErrLog -Raw -ErrorAction SilentlyContinue } else { "" }
                    $hasRealError = $errContent -match '(?m)^ERROR:'
                }

                $sep = "=" * 60
                Add-Content -Path $dailyLog -Value "`n$sep`n[$($job.Index)] $($job.Title)`n$sep"
                if (Test-Path $job.OutLog) { Get-Content $job.OutLog | Add-Content $dailyLog; Remove-Item $job.OutLog -Force }
                if (Test-Path $job.ErrLog) {
                    Add-Content -Path $dailyLog -Value "--- stderr ---"
                    Get-Content $job.ErrLog | Add-Content $dailyLog
                    Remove-Item $job.ErrLog -Force
                }

                if (-not $hasRealError) {
                    $done++
                    Write-Host ("`r  [OK]   $($job.Index). $($job.Title)" + (" " * 20)) -ForegroundColor Green
                } else {
                    $failed++
                    Write-Host ("`r  [FAIL] $($job.Index). $($job.Title)  (see $dailyLog)" + (" " * 5)) -ForegroundColor Red
                }
            } else {
                $stillRunning += $job
            }
        }
        $running = $stillRunning

        $completed  = $done + $failed
        $pct        = if ($total -gt 0) { [int](($completed / $total) * 20) } else { 0 }
        $bar        = ("#" * $pct) + ("-" * (20 - $pct))
        $statusLine = "  [$bar] $completed/$total  |  $($running.Count) running  |  $failed failed  |  $($queue.Count) queued"
        Write-Host "`r$statusLine" -NoNewline -ForegroundColor Cyan

        Start-Sleep -Milliseconds 500
    }

    Write-Host ""
    Write-Host ""
    if ($failed -eq 0) {
        Write-Ok "All $total video(s) downloaded successfully!"
    } else {
        Write-Ok "$done/$total downloaded. $failed failed. Full log: $dailyLog"
    }
}

# --- Download loop ---

while ($true) {
    Write-Header "Source"
    Write-Option "1" "YouTube"
    Write-Option "2" "Other site"
    Write-Option "3" "Exit"
    Write-Host -NoNewline "`n  > " -ForegroundColor DarkCyan
    $src = Read-Key
    if ($src -eq "3") { Write-Host ""; exit }
    if ($src -notin @("1", "2")) { Write-Err "Invalid choice."; continue }

    Write-Header "Format"
    Write-Option "1" "MP4  (video)"
    Write-Option "2" "MP3  (audio)"
    Write-Option "3" "Other (type extension)"
    Write-Host -NoNewline "`n  > " -ForegroundColor DarkCyan
    $fmtChoice = Read-Key

    $format     = $null
    $resolution = $null

    if ($fmtChoice -eq "1") {
        $format = "mp4"

        Write-Header "Resolution"
        Write-Option "1" "Best"
        Write-Option "2" "1080p"
        Write-Option "3" "720p"
        Write-Option "4" "480p"
        Write-Host -NoNewline "`n  > " -ForegroundColor DarkCyan
        $resChoice = Read-Key
        $resolution = switch ($resChoice) {
            "2" { "1080" }
            "3" { "720" }
            "4" { "480" }
            default { $null }
        }
    } elseif ($fmtChoice -eq "2") {
        $format = "mp3"
    } elseif ($fmtChoice -eq "3") {
        Write-Host -NoNewline "`n  Extension (e.g. mkv, flac, webm): " -ForegroundColor DarkCyan
        $ext = ($Host.UI.ReadLine()).Trim().ToLower()
        if ($ext -eq "") { Write-Err "No extension entered."; continue }
        $format = $ext
    } else {
        Write-Err "Invalid choice."
        continue
    }

    Write-Host -NoNewline "`n  URL: " -ForegroundColor DarkCyan
    $url = ($Host.UI.ReadLine()).Trim()
    if ($url -eq "") { Write-Err "No URL entered."; continue }

    Set-Location $ScriptDir

    $entries = Get-PlaylistEntries $url

    if ($entries.Count -gt 1) {
        Write-Ok "Detected playlist: $($entries.Count) videos"
        $baseArgs = Build-DlArgs $format $resolution $ffmpegLocation "dl/%(title)s.%(ext)s"
        Invoke-PlaylistDownload $entries $baseArgs
    } else {
        Run-Download $url $format $resolution $ffmpegLocation
    }
}
