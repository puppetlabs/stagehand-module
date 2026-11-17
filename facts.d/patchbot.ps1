# patchbot — external fact (facts.d, pluginsynced from the stagehand module;
# formerly named pcm_patch), Windows.
#
# Sibling of patchbot.sh. Same fact name, same consumers (Patching page,
# Action Center, and the correlation engine behind the Labs
# `computed_findings` flag), Windows-appropriate fields.
#
# ---------------------------------------------------------------------------
# THE POINT OF THIS FILE: os_build is the whole Windows vulnerability story.
#
# Since Windows 10 / Server 2016, cumulative updates are exactly that — a host
# on the January LCU contains every fix shipped since 2016. MSRC, however,
# links a CVE only to the KB that FIRST fixed it. So the obvious correlation —
# intersect installed KBs with the KBs named per CVE — reports thousands of
# false positives, because none of those historical KB IDs are individually
# present. Every naive Windows scanner has this bug.
#
# MSRC also publishes `FixedBuild` per remediation per product
# (e.g. "10.0.20348.1970"). Comparing the host's actual build against that is a
# monotonic integer comparison: immune to supersedence, no KB graph to walk, no
# missing-edge problem. So the primary signal this fact must deliver, quickly
# and always, is an accurate four-part build number.
#
# Everything else here is enrichment.
# ---------------------------------------------------------------------------
#
# SPEED: this runs on every Facter run, so it must be fast. The registry reads
# below are sub-millisecond. The expensive part — asking the Windows Update
# Agent what is installed and what is missing, which can take minutes and needs
# to reach WSUS/WU — is NOT done here. It is done by patchbot_refresh.ps1 on a
# scheduled task, which writes a cache this fact merely reads. That is the same
# scanner/fact split pe_patch uses, and for the same reason.
#
# A cold or missing cache is not an error: os_build still resolves, so Windows
# vulnerability correlation works on a host whose WUA scan has never run.
#
# Output: one line of JSON on stdout (Facter 4 / Puppet 8 — i.e. Puppet Core;
# the only stack we target, see docs: NO OpenVox), matching patchbot.sh.

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

$CacheFile = Join-Path $env:ProgramData 'PuppetLabs\patchbot\patch_cache.json'
$CacheMaxAgeSeconds = 86400 * 2   # cache older than this is reported stale

function Get-OsBuild {
    # Four-part build: CurrentMajorVersionNumber.CurrentMinorVersionNumber.
    # CurrentBuildNumber.UBR — e.g. 10.0.20348.3328.
    #
    # UBR is the revision that changes with every cumulative update and is the
    # ONLY part that distinguishes a patched host from an unpatched one. It
    # lives in the registry and nowhere else convenient: Facter's os.release
    # stops at the build number, and [Environment]::OSVersion has been
    # shimmed/lying since Windows 8.1. Read the registry.
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $cv  = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
    if ($null -eq $cv) { return $null }

    $major = $cv.CurrentMajorVersionNumber
    $minor = $cv.CurrentMinorVersionNumber
    if ($null -eq $major) {
        # Pre-Windows 10 (Server 2012 R2 and older) has no
        # CurrentMajorVersionNumber; fall back to the "6.3" style string.
        $parts = ("$($cv.CurrentVersion)").Split('.')
        if ($parts.Count -ge 2) { $major = $parts[0]; $minor = $parts[1] }
        else { return $null }
    }
    $build = $cv.CurrentBuildNumber
    $ubr   = $cv.UBR
    if ($null -eq $ubr) { $ubr = 0 }   # absent on pre-Win10; treat as .0
    return "$major.$minor.$build.$ubr"
}

# BEGIN reboot_status
# Reboot answer, three states. Each probe answers yes, no or error, and an
# error is never read as a no (D-09). The classification below is D-25: any yes
# is required; the CBS and Windows Update probes both answering a definite no is
# not required (the file-rename and SCCM probes only add a yes); otherwise
# unknown with reason probes_failed.
#
# ASSUMED until a Windows host confirms it (RESEARCH A1): a missing registry key
# raises ItemNotFoundException and a denied key raises another exception type,
# as the filesystem provider does. Verified on the filesystem provider only.
function Test-PatchbotProbe([scriptblock]$Probe) {
    try {
        if (& $Probe) { 'yes' } else { 'no' }
    } catch [System.Management.Automation.ItemNotFoundException] {
        'no'
    } catch {
        'error'
    }
}

function Resolve-PatchbotRebootStatus([string]$Cbs, [string]$WindowsUpdate, [string]$FileRename, [string]$Sccm) {
    if (($Cbs, $WindowsUpdate, $FileRename, $Sccm) -contains 'yes') {
        return [pscustomobject]@{ Status = 'required'; Reason = 'pending_reboot_probe' }
    }
    if ($Cbs -eq 'no' -and $WindowsUpdate -eq 'no') {
        return [pscustomobject]@{ Status = 'not_required'; Reason = 'probes_clear' }
    }
    return [pscustomobject]@{ Status = 'unknown'; Reason = 'probes_failed' }
}
# END reboot_status

function Get-RebootStatus {
    # Four independent signals; each is run through Test-PatchbotProbe with
    # -ErrorAction Stop inside its scriptblock, so a probe that could not read
    # the registry answers error and not no.
    $cbs = Test-PatchbotProbe {
        $null = Get-Item -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending' -ErrorAction Stop
        $true
    }
    $wu = Test-PatchbotProbe {
        $null = Get-Item -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired' -ErrorAction Stop
        $true
    }
    $fileRename = Test-PatchbotProbe {
        # GetValue returns a plain null when the value is absent, so an absent
        # value is a no and only a failure to open the key is an error.
        $key = Get-Item -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction Stop
        $v = $key.GetValue('PendingFileRenameOperations')
        ($null -ne $v) -and (@($v).Count -gt 0)
    }

    # SCCM's own opinion, only when the client is actually installed. A missing
    # client is not applicable, not an error.
    $sccm = 'absent'
    if (Get-CimClass -Namespace 'root\ccm\clientsdk' -ClassName 'CCM_ClientUtilities' -ErrorAction SilentlyContinue) {
        $sccm = Test-PatchbotProbe {
            $r = Invoke-CimMethod -Namespace 'root\ccm\clientsdk' -ClassName 'CCM_ClientUtilities' `
                                  -MethodName 'DetermineIfRebootPending' -ErrorAction Stop
            ($null -ne $r) -and ($r.RebootPending -eq $true -or $r.IsHardRebootPending -eq $true)
        }
    }
    return Resolve-PatchbotRebootStatus -Cbs $cbs -WindowsUpdate $wu -FileRename $fileRename -Sccm $sccm
}

# ---- fast path: always available, no network, no WUA -----------------------
$osBuild = Get-OsBuild
$reboot  = Get-RebootStatus

# ---- cached path: whatever the last refresh managed to collect -------------
$cache        = $null
$cacheAge     = $null
$cacheStale   = $true
if (Test-Path $CacheFile) {
    try {
        $cache    = Get-Content -Path $CacheFile -Raw -ErrorAction Stop | ConvertFrom-Json
        $written  = [DateTime]::Parse($cache.generated_at, [Globalization.CultureInfo]::InvariantCulture,
                                      [Globalization.DateTimeStyles]::RoundtripKind)
        $cacheAge = [int]([DateTime]::UtcNow - $written.ToUniversalTime()).TotalSeconds
        $cacheStale = ($cacheAge -gt $CacheMaxAgeSeconds)
    } catch {
        $cache = $null   # unreadable cache is a cold cache, not a failure
    }
}

$installedKbs = @()
$missing      = @()
$source       = 'unknown'
$wsus         = $null
$scanError    = $null
$cvePopulated = $null

if ($null -ne $cache) {
    if ($cache.installed_kbs) { $installedKbs = @($cache.installed_kbs) }
    if ($cache.missing)       { $missing      = @($cache.missing) }
    if ($cache.source)        { $source       = [string]$cache.source }
    if ($cache.wsus_server)   { $wsus         = [string]$cache.wsus_server }
    if ($cache.scan_error)    { $scanError    = [string]$cache.scan_error }
    # Diagnostic, deliberately surfaced as a fact: does WUA actually populate
    # IUpdate2::CveIDs on this OS? Documented as existing since XP, but no
    # tooling in the wild reads it and every real scanner correlates KB->CVE
    # externally instead. If this comes back true across a fleet, a large part
    # of the correlation engine collapses into a local API call.
    if ($null -ne $cache.cve_ids_populated) { $cvePopulated = [bool]$cache.cve_ids_populated }
}

# The refresh caps the missing[] detail list but counts every update (missing_total, security_total), so the counts stay exact and
# truncated says when the list is shorter than the total (the contract's "Cost and the cap"). A cache written before the totals
# existed has only the capped list, so its listed count is all there is to report and truncated stays false until the next refresh.
$availableCount = $missing.Count
$securityCount  = @($missing | Where-Object { $_.severity -and $_.severity -ne 'Unspecified' }).Count
if ($null -ne $cache) {
    $t = 0
    if ($null -ne $cache.missing_total -and [int]::TryParse([string]$cache.missing_total, [ref]$t) -and $t -ge $missing.Count) {
        $availableCount = $t
        $s = 0
        if ($null -ne $cache.security_total -and [int]::TryParse([string]$cache.security_total, [ref]$s) -and $s -ge 0 -and $s -le $t) {
            $securityCount = $s
        }
    }
}
$truncated = ($availableCount -gt $missing.Count)

$payload = [ordered]@{
    schema_version  = 2
    available       = $availableCount
    security        = $securityCount
    # Kept for version 1 readers: true only when reboot_status is required.
    reboot_required = ($reboot.Status -eq 'required')
    reboot_status        = $reboot.Status
    reboot_status_reason = $reboot.Reason
    last_checked    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    manager         = 'wua'
    os_build        = $osBuild
    installed_kbs   = $installedKbs
    missing         = $missing
    source          = $source
    wsus_server     = $wsus
    package_count   = $availableCount
    truncated       = $truncated
    # Staleness is reported, never hidden. A scan against a two-week-old view
    # of Windows Update is not evidence of anything, and the console's coverage
    # view exists to say so out loud.
    cache_age_seconds  = $cacheAge
    cache_stale        = $cacheStale
    cve_ids_populated  = $cvePopulated
    scan_error         = $scanError
}

# -Compress keeps it to one line; Depth 6 covers missing[].cve_ids.
@{ patchbot = $payload } | ConvertTo-Json -Compress -Depth 6
