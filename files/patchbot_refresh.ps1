# patchbot_refresh — the Windows patch scanner behind the patchbot fact
# (formerly pcm_patch_refresh / pcm_patch).
#
# Run from a scheduled task created by `stagehand::patching` (default: daily
# with jitter, plus at boot). Writes
# C:\ProgramData\PuppetLabs\patchbot\patch_cache.json, which patchbot.ps1
# reads cheaply on every Facter run.
#
# The split matters: a Windows Update Agent search reaches WSUS or Windows
# Update and routinely takes minutes. Doing that inside a fact would stall
# every Puppet run on the box. Scanner writes, fact reads — the same shape
# pe_patch uses.
#
# Deliberate choices, each of which is a bug in something else:
#
#   * Get-HotFix / Win32_QuickFixEngineering are NOT used. Both read only the
#     CBS/QFE store and miss a large fraction of installed updates — every LCU
#     delivered through Windows Update, servicing stack updates, .NET Framework
#     updates, Defender definitions. Tools built on Get-HotFix under-report
#     installed patches and therefore over-report vulnerabilities.
#
#   * Installed state comes from BOTH IUpdateSearcher.QueryHistory (filtered to
#     ResultCode 2 = succeeded) and Search("IsInstalled=1"). History catches
#     updates the current service no longer offers; the search catches updates
#     applied before this history began (image-baked, or history rolled).
#
#   * CveIDs is read off IUpdate2 and the result is reported as a diagnostic
#     rather than assumed. See cve_ids_populated below.
#
# Exit code is always 0: a scheduled task that "fails" produces alerts nobody
# actions. Scan failures are recorded in the cache as scan_error and surfaced
# through the fact, where the console's coverage view can show them honestly.

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$CacheDir  = Join-Path $env:ProgramData 'PuppetLabs\patchbot'
$CacheFile = Join-Path $CacheDir 'patch_cache.json'
$TmpFile   = "$CacheFile.tmp"
$MaxMissing = 500   # cap the detail array; counts stay exact (missing_total, security_total)
# The same environment override the Linux fact honours, for a node that genuinely needs more detail or for a test.
$capEnv = 0
if ([int]::TryParse([string]$env:PCM_PATCH_MAX_PACKAGES, [ref]$capEnv) -and $capEnv -gt 0) { $MaxMissing = $capEnv }

$installedKbs   = New-Object System.Collections.Generic.HashSet[string]
$missing        = @()
$missingTotal   = 0        # every missing update, not just the listed ones
$securityTotal  = 0        # of those, the ones with a severity other than Unspecified
$source         = 'unknown'
$wsusServer     = $null
$scanError      = $null
$cveSeen        = $false     # did ANY update expose a non-empty CveIDs?
$cveChecked     = $false     # did we get far enough to look?

function Get-KbList($update) {
    $out = @()
    try {
        foreach ($kb in $update.KBArticleIDs) {
            if ($kb) { $out += ("KB" + ($kb -replace '^KB', '')) }
        }
    } catch { }
    return $out
}

try {
    if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null }

    $session  = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()

    # Which service are we actually asking? 0=default 1=WSUS 2=Windows Update
    # 3=other. This decides what the answer even means: a box pointed at WSUS
    # reports what WSUS has approved, not what Microsoft has published — and
    # that difference is exactly the Windows equivalent of the repo_gap state
    # on Linux.
    switch ($searcher.ServerSelection) {
        1 { $source = 'wsus' }
        2 { $source = 'windowsupdate' }
        3 { $source = 'other' }
        default { $source = 'default' }
    }
    $wsusKey = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -Name 'WUServer' -ErrorAction SilentlyContinue
    if ($null -ne $wsusKey) { $wsusServer = [string]$wsusKey.WUServer; if ($source -eq 'default') { $source = 'wsus' } }

    # ---- installed: history first (cheap, local) --------------------------
    try {
        $count = $searcher.GetTotalHistoryCount()
        if ($count -gt 0) {
            foreach ($entry in $searcher.QueryHistory(0, $count)) {
                if ($entry.ResultCode -ne 2) { continue }   # 2 = succeeded
                if ($entry.Title -match 'KB(\d{6,})') { [void]$installedKbs.Add("KB" + $Matches[1]) }
            }
        }
    } catch { }

    # ---- installed: searcher view (catches image-baked updates) -----------
    try {
        $inst = $searcher.Search("IsInstalled=1 and Type='Software'")
        foreach ($u in $inst.Updates) { foreach ($kb in (Get-KbList $u)) { [void]$installedKbs.Add($kb) } }
    } catch { }

    # ---- missing: the network-dependent part ------------------------------
    $res = $searcher.Search("IsInstalled=0 and Type='Software' and IsHidden=0")
    $cveChecked = $true
    foreach ($u in $res.Updates) {
        # Every update is counted, so available and security stay exact on a node more updates behind than the cap; only the detail
        # list below is capped (the contract: "the counts are always exact").
        $missingTotal++

        $sev = $null
        try { if ($u.MsrcSeverity) { $sev = [string]$u.MsrcSeverity } } catch { }
        if ($sev -and $sev -ne 'Unspecified') { $securityTotal++ }

        if ($missing.Count -ge $MaxMissing) { continue }

        # IUpdate2::CveIDs. Documented since XP; in practice every scanner
        # correlates KB->CVE externally against MSRC instead, which suggests
        # this is empty in the field. Report what we actually observe rather
        # than assuming either way — cve_ids_populated is how a fleet answers
        # this question with data.
        $cves = @()
        try {
            if ($null -ne $u.CveIDs) {
                foreach ($c in $u.CveIDs) { if ($c) { $cves += [string]$c } }
            }
        } catch { }
        if ($cves.Count -gt 0) { $cveSeen = $true }

        $missing += [ordered]@{
            kbs      = (Get-KbList $u)
            title    = [string]$u.Title
            severity = $sev
            cve_ids  = $cves
            reboot   = [bool]$u.RebootRequired
        }
    }
} catch {
    # Unreachable WSUS, service disabled, WU broken — all normal in the field.
    # Record it; the fact surfaces it; coverage counts it as unassessed.
    $scanError = $_.Exception.Message
}

$payload = [ordered]@{
    generated_at      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    installed_kbs     = @($installedKbs | Sort-Object)
    missing           = $missing
    missing_total     = $missingTotal
    security_total    = $securityTotal
    source            = $source
    wsus_server       = $wsusServer
    cve_ids_populated = $(if ($cveChecked) { $cveSeen } else { $null })
    scan_error        = $scanError
}

# Atomic-ish write so a Facter run never reads a half-written cache.
$payload | ConvertTo-Json -Compress -Depth 6 | Set-Content -Path $TmpFile -Encoding UTF8
Move-Item -Path $TmpFile -Destination $CacheFile -Force

exit 0
