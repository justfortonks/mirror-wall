# Starts two packaged receivers the way Mirror Wall does (slots 1 and 2), lets them run a few
# seconds, and fails unless both started their server and announced it.
$ErrorActionPreference = 'Stop'
$out = Join-Path $PSScriptRoot 'out'
$env:GST_PLUGIN_SYSTEM_PATH = Join-Path $out 'lib\gstreamer-1.0'
$env:GST_PLUGIN_PATH = ''
$env:GST_PLUGIN_SCANNER = Join-Path $out 'gst-plugin-scanner.exe'
$env:GST_REGISTRY = Join-Path $env:RUNNER_TEMP 'gstreamer-registry.bin'
$env:MIRROR_WALL_QUIT_ON_EOF = '1'

$receivers = foreach ($slot in 1, 2) {
    $port = 7200 + $slot * 100
    $rtp = 5598 + $slot * 2
    $arguments = @(
        '-n', "`"Mirror Wall $slot`"", '-nh', '-p', $port, '-m', "02:00:00:00:00:0$slot",
        '-vsync', 'no', '-as', '0', '-d', '1', '-fps', '30', '-nc', 'no',
        '-vrtp', "`"config-interval=1 ! udpsink sync=false host=127.0.0.1 port=$rtp`""
    )
    $log = Join-Path $env:RUNNER_TEMP "slot-$slot.log"
    $process = Start-Process -FilePath (Join-Path $out 'uxplay.exe') -ArgumentList $arguments `
        -RedirectStandardOutput $log -RedirectStandardError "$log.err" -PassThru -NoNewWindow
    [pscustomobject]@{ Slot = $slot; Process = $process; Log = $log }
}

Start-Sleep -Seconds 10
$failed = $false
foreach ($receiver in $receivers) {
    if (-not $receiver.Process.HasExited) { Stop-Process -Id $receiver.Process.Id -Force }
    $text = (Get-Content $receiver.Log -Raw) + (Get-Content "$($receiver.Log).err" -Raw)
    Write-Host "----- slot $($receiver.Slot) -----"
    Write-Host $text
    foreach ($expected in 'Initialized server socket', 'register_dnssd') {
        if ($text -notmatch [regex]::Escape($expected)) {
            Write-Host "::error::Slot $($receiver.Slot)'s receiver never printed '$expected'"
            $failed = $true
        }
    }
}
if ($failed) { exit 1 }
