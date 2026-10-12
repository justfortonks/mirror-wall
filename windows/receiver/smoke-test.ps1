# Starts two packaged receivers the way Mirror Wall does (slots 1 and 2), lets them run a few
# seconds, and fails unless both started their server and announced it. Then closes their input,
# as the app does to stop them, and checks they exit cleanly.
$ErrorActionPreference = 'Stop'
$out = Join-Path $PSScriptRoot 'out'

$receivers = foreach ($slot in 1, 2) {
    $info = [System.Diagnostics.ProcessStartInfo]::new((Join-Path $out 'uxplay.exe'))
    $info.UseShellExecute = $false
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.Environment['GST_PLUGIN_SYSTEM_PATH'] = Join-Path $out 'lib\gstreamer-1.0'
    $info.Environment.Remove('GST_PLUGIN_PATH') | Out-Null
    $info.Environment['GST_PLUGIN_SCANNER'] = Join-Path $out 'gst-plugin-scanner.exe'
    $info.Environment['GST_REGISTRY'] = Join-Path $env:RUNNER_TEMP 'gstreamer-registry.bin'
    $info.Environment['MIRROR_WALL_QUIT_ON_EOF'] = '1'
    # GStreamer's warnings, which name a missing plugin or library.
    $info.Environment['GST_DEBUG'] = '2'
    $info.Environment['GST_DEBUG_NO_COLOR'] = '1'
    $port = 7200 + $slot * 100
    $rtp = 5598 + $slot * 2
    foreach ($argument in @(
        '-n', "Mirror Wall $slot · Test PC", '-nh', '-p', "$port", '-m', "02:00:00:00:00:0$slot",
        '-vsync', 'no', '-as', '0', '-d', '1', '-fps', '30', '-nc', 'no',
        '-vrtp', "config-interval=1 ! udpsink sync=false host=127.0.0.1 port=$rtp")) {
        $info.ArgumentList.Add($argument)
    }
    $process = [System.Diagnostics.Process]::Start($info)
    [pscustomobject]@{
        Slot = $slot
        Process = $process
        Output = $process.StandardOutput.ReadToEndAsync()
        Errors = $process.StandardError.ReadToEndAsync()
    }
    Start-Sleep -Seconds 2
}

Start-Sleep -Seconds 8
foreach ($receiver in $receivers) { $receiver.Process.StandardInput.Close() }

$failed = $false
foreach ($receiver in $receivers) {
    $exited = $receiver.Process.WaitForExit(10000)
    if (-not $exited) { $receiver.Process.Kill() }
    $text = $receiver.Output.Result + $receiver.Errors.Result
    Write-Host "----- slot $($receiver.Slot) (exit code $(if ($exited) { $receiver.Process.ExitCode } else { 'none: killed' })) -----"
    Write-Host $text
    foreach ($expected in 'Initialized server socket', 'register_dnssd') {
        if ($text -notmatch [regex]::Escape($expected)) {
            Write-Host "::error::Slot $($receiver.Slot)'s receiver never printed '$expected'"
            $failed = $true
        }
    }
    if (-not $exited -or $text -match 'uxplay crashed') {
        Write-Host "::error::Slot $($receiver.Slot)'s receiver didn't stop cleanly when its input closed"
        $failed = $true
    }
}
if ($failed) { exit 1 }
