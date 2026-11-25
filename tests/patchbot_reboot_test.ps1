# Test for facts.d/patchbot.ps1 (the Windows patchbot fact).
#
# Run on any OS with PowerShell 7 (no Windows host, no registry, no Pester):
#
#   pwsh -NoProfile -File tests/patchbot_reboot_test.ps1
#
# It prints TAP and exits 1 when any case failed. It never runs the real
# probes. It does two things:
#
#   1. Reads patchbot.ps1, extracts the text between the exact lines
#      "# BEGIN reboot_status" and "# END reboot_status", dot-sources it and
#      tests Test-PatchbotProbe and Resolve-PatchbotRebootStatus with injected
#      probe outcomes and thrown exceptions.
#   2. Parses patchbot.ps1 with the PowerShell parser (the AST) and checks the
#      keys of the payload hashtable, so the contract keys cannot silently
#      disappear from the published fact.
#   3. Runs the fact against cache files in a temp ProgramData, and runs
#      files/patchbot_refresh.ps1 through a fake Windows Update Agent, to check
#      that the counts stay exact and truncated is set when the detail list is
#      capped.
#
# This file lives in tests/ on purpose and is not shipped: Facter on Windows
# executes every .ps1 it finds in facts.d, so a copy in facts.d would run as a
# fact. The Registry error behavior on
# a real Windows host is a human test, not something this file claims.

$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$factPath = Join-Path (Split-Path -Parent $here) 'facts.d/patchbot.ps1'

$script:n = 0
$script:failed = 0

function Write-Case([bool]$Pass, [string]$Name, [string]$Detail) {
    $script:n++
    if ($Pass) {
        Write-Output "ok $($script:n) - $Name"
    } else {
        $script:failed++
        Write-Output "not ok $($script:n) - $Name"
        if ($Detail) { Write-Output "# $Detail" }
    }
}

# ---- 1. extract and load the reboot_status block ---------------------------

$text = Get-Content -LiteralPath $factPath -Raw
$lines = $text -split "`r?`n"
$begin = [array]::IndexOf($lines, '# BEGIN reboot_status')
$end = [array]::IndexOf($lines, '# END reboot_status')

$blockLoaded = $false
if ($begin -lt 0) {
    Write-Case $false 'the fact has the line "# BEGIN reboot_status"' 'marker missing'
} elseif ($end -lt 0 -or $end -le $begin) {
    Write-Case $false 'the fact has the line "# END reboot_status" after the begin marker' 'marker missing'
} else {
    Write-Case $true 'the fact has the BEGIN and END reboot_status markers' ''
    $block = ($lines[($begin + 1)..($end - 1)]) -join "`n"
    try {
        . ([scriptblock]::Create($block))
        $blockLoaded = $true
    } catch {
        Write-Case $false 'the reboot_status block loads' "$($_.Exception.Message)"
    }
}

function Test-Resolve([string]$Name, [string[]]$In, [string]$WantStatus, [string]$WantReason) {
    if (-not $blockLoaded) {
        Write-Case $false $Name 'block not loaded'
        return
    }
    try {
        $r = Resolve-PatchbotRebootStatus -Cbs $In[0] -WindowsUpdate $In[1] -FileRename $In[2] -Sccm $In[3]
        $ok = ($r.Status -eq $WantStatus) -and ($r.Reason -eq $WantReason)
        Write-Case $ok $Name "wanted $WantStatus/$WantReason, got $($r.Status)/$($r.Reason)"
    } catch {
        Write-Case $false $Name "threw: $($_.Exception.Message)"
    }
}

# Task 1: the tracer case, a CBS reboot pending.
Test-Resolve 'cbs yes, wu no, filerename no, sccm absent: required, pending_reboot_probe' @('yes', 'no', 'no', 'absent') 'required' 'pending_reboot_probe'

# Task 2: the full matrix. Argument order: Cbs, WindowsUpdate, FileRename, Sccm.
Test-Resolve 'wu yes (rest no): required' @('no', 'yes', 'no', 'no') 'required' 'pending_reboot_probe'
Test-Resolve 'filerename yes (rest no): required' @('no', 'no', 'yes', 'no') 'required' 'pending_reboot_probe'
Test-Resolve 'sccm yes (rest no): required' @('no', 'no', 'no', 'yes') 'required' 'pending_reboot_probe'
Test-Resolve 'cbs no, wu no, filerename no, sccm absent: not_required, probes_clear' @('no', 'no', 'no', 'absent') 'not_required' 'probes_clear'
Test-Resolve 'cbs no, wu no, filerename error, sccm absent: not_required (D-25 counts only cbs and wu)' @('no', 'no', 'error', 'absent') 'not_required' 'probes_clear'
Test-Resolve 'cbs no, wu no, filerename no, sccm error: not_required' @('no', 'no', 'no', 'error') 'not_required' 'probes_clear'
Test-Resolve 'cbs error, wu no, filerename no, sccm absent: unknown, probes_failed' @('error', 'no', 'no', 'absent') 'unknown' 'probes_failed'
Test-Resolve 'cbs no, wu error, filerename no, sccm absent: unknown, probes_failed' @('no', 'error', 'no', 'absent') 'unknown' 'probes_failed'
Test-Resolve 'every probe error: unknown, probes_failed' @('error', 'error', 'error', 'error') 'unknown' 'probes_failed'
Test-Resolve 'cbs error, filerename yes: a yes wins over an error, required' @('error', 'no', 'yes', 'absent') 'required' 'pending_reboot_probe'

function Test-Probe([string]$Name, [scriptblock]$Probe, [string]$Want) {
    if (-not $blockLoaded) {
        Write-Case $false $Name 'block not loaded'
        return
    }
    try {
        $got = Test-PatchbotProbe $Probe
        Write-Case ($got -eq $Want) $Name "wanted $Want, got $got"
    } catch {
        Write-Case $false $Name "threw: $($_.Exception.Message)"
    }
}

Test-Probe 'probe returning true is yes' { $true } 'yes'
Test-Probe 'probe returning false is no' { $false } 'no'
Test-Probe 'probe throwing ItemNotFoundException is no' { throw [System.Management.Automation.ItemNotFoundException]::new('missing key') } 'no'
Test-Probe 'probe throwing UnauthorizedAccessException is error' { throw [System.UnauthorizedAccessException]::new('denied') } 'error'
Test-Probe 'probe throwing a plain string is error' { throw 'could not read' } 'error'

# ---- 2. the payload keys, by AST --------------------------------------------

$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($factPath, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) {
    Write-Case $false 'patchbot.ps1 parses' "$($errors[0].Message)"
}
$hashtables = $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.HashtableAst] }, $true)
$payload = $null
foreach ($h in $hashtables) {
    $keys = @($h.KeyValuePairs | ForEach-Object { $_.Item1.Extent.Text.Trim("'", '"') })
    if ($keys -contains 'reboot_required') { $payload = $h; break }
}

if ($null -eq $payload) {
    Write-Case $false 'the payload hashtable (the one with reboot_required) is found' 'not found'
} else {
    $keys = @($payload.KeyValuePairs | ForEach-Object { $_.Item1.Extent.Text.Trim("'", '"') })
    foreach ($want in 'schema_version', 'reboot_status', 'reboot_status_reason', 'reboot_required') {
        Write-Case ($keys -contains $want) "the payload carries the key $want" "keys: $($keys -join ',')"
    }
    $sv = $payload.KeyValuePairs | Where-Object { $_.Item1.Extent.Text.Trim("'", '"') -eq 'schema_version' } | Select-Object -First 1
    $svText = if ($sv) { $sv.Item2.Extent.Text.Trim() } else { '' }
    Write-Case ($svText -eq '2') 'schema_version is the integer 2' "got '$svText'"
}

# ---- 3. counts stay exact when the detail list is capped (schema "Cost and the cap") --------------------------------------
#
# The fact reads the cache the scheduled refresh writes, and the refresh caps the missing[] detail list. The contract says the counts
# stay exact and `truncated` is true when the list is capped, so the cache must carry the true totals and the fact must report them.
# Before this check the refresh stopped counting at the cap and the fact hard-coded truncated false, so a node with more updates than
# the cap under-reported available and package_count and never said so.
#
# ProgramData is pointed at a temp directory. On Windows the cache lives in PuppetLabs\patchbot below it; on any other OS the
# backslashes are part of a flat file name, which is why the fact's path is always built with the same Join-Path expression.

$refreshPath = Join-Path (Split-Path -Parent $here) 'files/patchbot_refresh.ps1'
$pwshExe = (Get-Process -Id $PID).Path

function New-ProgramDataDir {
    $d = Join-Path ([System.IO.Path]::GetTempPath()) ('patchbot-adapters-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    return $d
}

function Write-FactCache([string]$ProgramData, [string]$Json) {
    $f = Join-Path $ProgramData 'PuppetLabs\patchbot\patch_cache.json'
    New-Item -ItemType File -Path $f -Force | Out-Null
    Set-Content -LiteralPath $f -Value $Json -Encoding UTF8
}

function Invoke-AdaptersFact([string]$ProgramData) {
    $saved = $env:ProgramData
    $env:ProgramData = $ProgramData
    try {
        $raw = & $pwshExe -NoProfile -File $factPath 2>&1
    } finally {
        $env:ProgramData = $saved
    }
    return (($raw -join "`n") | ConvertFrom-Json -AsHashtable)['patchbot']
}

function New-CacheJson([int]$Listed, $MissingTotal, $SecurityTotal) {
    $items = @()
    $sevs = @('Critical', 'Important', 'Unspecified', $null, 'Moderate')
    for ($i = 0; $i -lt $Listed; $i++) {
        $items += [ordered]@{ kbs = @("KB500000$i"); title = "Update $i"; severity = $sevs[$i % $sevs.Count]; cve_ids = @(); reboot = $false }
    }
    $c = [ordered]@{
        generated_at      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        installed_kbs     = @()
        missing           = $items
        source            = 'wsus'
        wsus_server       = $null
        cve_ids_populated = $false
        scan_error        = $null
    }
    if ($null -ne $MissingTotal) { $c['missing_total'] = $MissingTotal }
    if ($null -ne $SecurityTotal) { $c['security_total'] = $SecurityTotal }
    return ($c | ConvertTo-Json -Compress -Depth 6)
}

$pd = New-ProgramDataDir
try {
    # A capped cache: three listed, seven true updates, four of them security.
    Write-FactCache $pd (New-CacheJson 3 7 4)
    $capped = Invoke-AdaptersFact $pd
    Write-Case (($capped['available'] -eq 7) -and ($capped['package_count'] -eq 7)) 'capped cache: available and package_count are the true total, not the listed count' "available=$($capped['available']) package_count=$($capped['package_count'])"
    Write-Case ($capped['security'] -eq 4) 'capped cache: security is the true security total' "got $($capped['security'])"
    Write-Case (@($capped['missing']).Count -eq 3) 'capped cache: missing[] keeps the capped detail list' "listed=$(@($capped['missing']).Count)"
    Write-Case ($capped['truncated'] -eq $true) 'capped cache: truncated is true' "got $($capped['truncated'])"

    # A cache at or under the cap: the totals equal the listed count and truncated stays false.
    Write-FactCache $pd (New-CacheJson 3 3 2)
    $under = Invoke-AdaptersFact $pd
    Write-Case (($under['available'] -eq 3) -and ($under['package_count'] -eq 3) -and (@($under['missing']).Count -eq 3)) 'uncapped cache: counts equal the listed updates' "available=$($under['available']) listed=$(@($under['missing']).Count)"
    Write-Case ($under['truncated'] -eq $false) 'uncapped cache: truncated is false' "got $($under['truncated'])"

    # A cache written before the totals existed: the listed count is all there is to report, and security is derived from the list.
    Write-FactCache $pd (New-CacheJson 3 $null $null)
    $old = Invoke-AdaptersFact $pd
    Write-Case (($old['available'] -eq 3) -and ($old['package_count'] -eq 3) -and ($old['truncated'] -eq $false)) 'a cache from before the totals existed reports the listed count and truncated false' "available=$($old['available']) truncated=$($old['truncated'])"
    Write-Case ($old['security'] -eq 2) 'a cache from before the totals existed derives security from the listed updates' "got $($old['security'])"
} catch {
    Write-Case $false 'the fact runs against a temp ProgramData cache' "$($_.Exception.Message)"
} finally {
    Remove-Item -LiteralPath $pd -Recurse -Force -ErrorAction SilentlyContinue
}

# The refresh script, through a fake Windows Update Agent (New-Object is shadowed by a function, which outranks the cmdlet). Five
# missing updates: Critical, Important, Unspecified, no severity, Moderate, so three count as security. With the cap at three, the
# detail list holds the first three (two of them security) while the cache must carry total 5 and security 3.
function Invoke-RefreshWithFakeWua([string]$ProgramData, [string]$Cap) {
    $savedPd = $env:ProgramData
    $env:ProgramData = $ProgramData
    try {
        & {
            function New-Object {
                param([Parameter(Position = 0)][string]$TypeName, [string]$ComObject, [object[]]$ArgumentList)
                if ($ComObject -eq 'Microsoft.Update.Session') {
                    $mk = { param($title, $sev, $kbs) [pscustomobject]@{ Title = $title; MsrcSeverity = $sev; KBArticleIDs = $kbs; CveIDs = @(); RebootRequired = $false } }
                    $missingUpdates = @(
                        (& $mk 'A' 'Critical' @('5031111')), (& $mk 'B' 'Important' @('5032222')), (& $mk 'C' 'Unspecified' @('5033333')),
                        (& $mk 'D' $null @('5034444')), (& $mk 'E' 'Moderate' @('5035555'))
                    )
                    $searcher = [pscustomobject]@{ ServerSelection = 1 }
                    $searcher | Add-Member -MemberType ScriptMethod -Name GetTotalHistoryCount -Value { 0 }
                    $searcher | Add-Member -MemberType ScriptMethod -Name QueryHistory -Value { param($a, $b) @() }
                    $searcher | Add-Member -MemberType ScriptMethod -Name Search -Value {
                        param($q)
                        if ($q -like 'IsInstalled=1*') { [pscustomobject]@{ Updates = @() } } else { [pscustomobject]@{ Updates = $missingUpdates } }
                    }.GetNewClosure()
                    $session = [pscustomobject]@{}
                    $session | Add-Member -MemberType ScriptMethod -Name CreateUpdateSearcher -Value { $searcher }.GetNewClosure()
                    return $session
                }
                Microsoft.PowerShell.Utility\New-Object -TypeName $TypeName
            }
            if ($Cap) { $env:PCM_PATCH_MAX_PACKAGES = $Cap }
            try { & $refreshPath | Out-Null } finally { $env:PCM_PATCH_MAX_PACKAGES = $null }
        }
    } finally {
        $env:ProgramData = $savedPd
    }
    $cacheFile = Join-Path (Join-Path $ProgramData 'PuppetLabs\patchbot') 'patch_cache.json'
    $cache = Get-Content -LiteralPath $cacheFile -Raw | ConvertFrom-Json -AsHashtable
    # Hand the cache to the fact at the path the fact builds (the same file on Windows, a flat file name elsewhere).
    Write-FactCache $ProgramData (Get-Content -LiteralPath $cacheFile -Raw)
    return $cache
}

$pd = New-ProgramDataDir
try {
    $cache = Invoke-RefreshWithFakeWua $pd '3'
    Write-Case ($cache['scan_error'] -eq $null) 'refresh with a fake scan reports no scan_error' "got $($cache['scan_error'])"
    Write-Case (@($cache['missing']).Count -eq 3) 'refresh caps the missing[] detail list at the cap' "listed=$(@($cache['missing']).Count)"
    Write-Case ($cache['missing_total'] -eq 5) 'refresh keeps counting past the cap: missing_total is every missing update' "got $($cache['missing_total'])"
    Write-Case ($cache['security_total'] -eq 3) 'refresh counts security over the whole scan, not the capped list' "got $($cache['security_total'])"
    $viaFact = Invoke-AdaptersFact $pd
    Write-Case (($viaFact['available'] -eq 5) -and ($viaFact['package_count'] -eq 5) -and ($viaFact['security'] -eq 3)) 'end to end: the fact reports the true totals from the refreshed cache' "available=$($viaFact['available']) security=$($viaFact['security'])"
    Write-Case (($viaFact['truncated'] -eq $true) -and (@($viaFact['missing']).Count -eq 3)) 'end to end: three listed of five, truncated true' "truncated=$($viaFact['truncated']) listed=$(@($viaFact['missing']).Count)"
} catch {
    Write-Case $false 'the fake-WUA refresh runs' "$($_.Exception.Message)"
} finally {
    Remove-Item -LiteralPath $pd -Recurse -Force -ErrorAction SilentlyContinue
}
$pd = New-ProgramDataDir
try {
    $cache = Invoke-RefreshWithFakeWua $pd ''
    Write-Case (($cache['missing_total'] -eq 5) -and (@($cache['missing']).Count -eq 5)) 'under the default cap every update is listed and missing_total matches' "total=$($cache['missing_total']) listed=$(@($cache['missing']).Count)"
    $viaFact = Invoke-AdaptersFact $pd
    Write-Case (($viaFact['available'] -eq 5) -and ($viaFact['truncated'] -eq $false)) 'end to end under the cap: available 5, truncated false' "available=$($viaFact['available']) truncated=$($viaFact['truncated'])"
} catch {
    Write-Case $false 'the fake-WUA refresh runs under the default cap' "$($_.Exception.Message)"
} finally {
    Remove-Item -LiteralPath $pd -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output "1..$($script:n)"
if ($script:failed -gt 0) { exit 1 }
exit 0
