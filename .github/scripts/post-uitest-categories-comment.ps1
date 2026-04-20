#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Posts or updates a UI test category-detection summary comment on a PR.

.DESCRIPTION
    Maintains ONE comment per PR identified by <!-- UI Test Categories -->.
    Reads an Azure DevOps build, finds the discover stage and every per-job
    "Check if category should run" task, then summarises what the detection
    decided and which matrix cells the pipeline skipped.

    Each invocation adds an expandable session keyed by the PR HEAD SHA.
    - Same SHA  -> replaces that session in-place.
    - New SHA   -> prepends a new session (latest first; older collapsed).

.PARAMETER PRNumber
    The pull request number (required).

.PARAMETER BuildId
    The Azure DevOps build ID to summarise (required).

.PARAMETER Repo
    Repo in owner/name form. Defaults to dotnet/maui.

.PARAMETER AzdoOrg
    Azure DevOps org. Defaults to dnceng-public.

.PARAMETER AzdoProject
    Azure DevOps project. Defaults to public.

.PARAMETER DryRun
    Print the comment instead of posting.

.EXAMPLE
    ./post-uitest-categories-comment.ps1 -PRNumber 33176 -BuildId 1386279

.EXAMPLE
    ./post-uitest-categories-comment.ps1 -PRNumber 33176 -BuildId 1386279 -DryRun
#>

param(
    [Parameter(Mandatory = $true)]
    [int]$PRNumber,

    [Parameter(Mandatory = $true)]
    [int]$BuildId,

    [Parameter(Mandatory = $false)]
    [string]$Repo = "dotnet/maui",

    [Parameter(Mandatory = $false)]
    [string]$AzdoOrg = "dnceng-public",

    [Parameter(Mandatory = $false)]
    [string]$AzdoProject = "public",

    [Parameter(Mandatory = $false)]
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$MARKER = "<!-- UI Test Categories -->"
$BuildUrl = "https://dev.azure.com/$AzdoOrg/$AzdoProject/_build/results?buildId=$BuildId"
$ApiBase = "https://dev.azure.com/$AzdoOrg/$AzdoProject/_apis/build/builds/$BuildId"

# ============================================================================
# FETCH BUILD + TIMELINE
# ============================================================================

Write-Host "Fetching build $BuildId..." -ForegroundColor Cyan
$build = Invoke-RestMethod -Uri "$ApiBase`?api-version=7.1"
$timeline = Invoke-RestMethod -Uri "$ApiBase/timeline?api-version=7.1"

# ----------------------------------------------------------------------------
# Detected categories — read from any "Check if category should run" log
# (every job logs the same DETECTED_CATEGORIES value).
# ----------------------------------------------------------------------------

$checkRecords = @($timeline.records |
    Where-Object { $_.name -eq "Check if category should run" -and $_.log -and $_.log.id })

if ($checkRecords.Count -eq 0) {
    throw "Build $BuildId has no 'Check if category should run' tasks — wrong build?"
}

$detectedCategories = $null
$filterEngaged = $false

foreach ($rec in $checkRecords) {
    $log = Invoke-RestMethod -Uri "$ApiBase/logs/$($rec.log.id)?api-version=7.1"
    if ($log -match "Detected Categories:\s*'([^']*)'\s*\(filter engaged:\s*(True|False)\)") {
        $val = $Matches[1]
        $eng = $Matches[2] -eq "True"
        if (-not $val.StartsWith('$(')) {
            $detectedCategories = $val
            $filterEngaged = $eng
            break
        }
    }
}

if ([string]::IsNullOrWhiteSpace($detectedCategories)) {
    $detectedCategories = "(none — full matrix will run)"
}

Write-Host "Detected categories: $detectedCategories" -ForegroundColor Green
Write-Host "Filter engaged: $filterEngaged" -ForegroundColor Green

# ----------------------------------------------------------------------------
# Per-job decisions — parse every check log
# ----------------------------------------------------------------------------

$decisions = @()
foreach ($rec in $checkRecords) {
    $log = Invoke-RestMethod -Uri "$ApiBase/logs/$($rec.log.id)?api-version=7.1"
    $group = if ($log -match "Category Group \(from matrix\):\s*'([^']*)'") { $Matches[1] } else { "?" }
    $shouldRun = if ($log -match "Should run tests:\s*(True|False)") { $Matches[1] -eq "True" } else { $true }
    $matched = if ($log -match "Matching categories for this job:\s*(.+)") { $Matches[1].Trim() } else { "" }

    # Walk up to find the parent job/stage name for context
    $parent = $timeline.records | Where-Object { $_.id -eq $rec.parentId } | Select-Object -First 1
    $stageName = $parent.name
    if ($parent -and $parent.parentId) {
        $grandparent = $timeline.records | Where-Object { $_.id -eq $parent.parentId } | Select-Object -First 1
        if ($grandparent) { $stageName = $grandparent.name }
    }

    $decisions += [pscustomobject]@{
        Stage     = $stageName
        Group     = $group
        ShouldRun = $shouldRun
        Matched   = $matched
    }
}

$ranDecisions     = @($decisions | Where-Object { $_.ShouldRun })
$skippedDecisions = @($decisions | Where-Object { -not $_.ShouldRun })

Write-Host "Jobs ran: $($ranDecisions.Count) / Skipped: $($skippedDecisions.Count)" -ForegroundColor Green

# ----------------------------------------------------------------------------
# Stage results
# ----------------------------------------------------------------------------

$stageRows = @($timeline.records |
    Where-Object { $_.type -eq "Stage" } |
    Sort-Object name -Unique |
    ForEach-Object {
        $icon = switch ($_.result) {
            "succeeded"            { "✅" }
            "succeededWithIssues"  { "⚠️" }
            "failed"               { "❌" }
            "canceled"             { "🚫" }
            default                { "⏸️" }
        }
        "| $icon | $($_.name) | $($_.result) |"
    })

# ============================================================================
# FETCH PR METADATA
# ============================================================================

try {
    $commitJson = gh api "repos/$Repo/pulls/$PRNumber/commits" --jq '.[-1] | {message: .commit.message, sha: .sha}' 2>$null | ConvertFrom-Json
} catch {
    Write-Host "⚠️ Could not fetch commits: $_" -ForegroundColor Yellow
    $commitJson = $null
}
$commitTitle = if ($commitJson) { ($commitJson.message -split "`n")[0] } else { "Unknown" }
$commitTitle = $commitTitle -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;'
$commitSha7  = if ($commitJson) { $commitJson.sha.Substring(0, 7) } else { "unknown" }
$commitFull  = if ($commitJson) { $commitJson.sha } else { "" }
$commitUrl   = if ($commitJson) { "https://github.com/$Repo/commit/$commitFull" } else { "#" }

try { $prAuthor = gh api "repos/$Repo/pulls/$PRNumber" --jq '.user.login' 2>$null } catch { $prAuthor = $null }

$timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm UTC")

# ============================================================================
# BUILD SESSION BLOCK
# ============================================================================

$summaryLine = if ($filterEngaged) {
    "🎯 Filter engaged — **$($ranDecisions.Count) of $($decisions.Count)** matrix cells ran (skipped **$($skippedDecisions.Count)**)."
} else {
    "📦 Filter not engaged — full matrix ran."
}

$ranTable = if ($ranDecisions.Count -gt 0) {
    @(
        "| Stage | Category Group | Matched |"
        "|---|---|---|"
        ($ranDecisions | ForEach-Object { "| $($_.Stage) | ``$($_.Group)`` | ``$(if ($_.Matched) { $_.Matched } else { $_.Group })`` |" })
    ) -join "`n"
} else { "_No jobs ran._" }

$skippedTable = if ($skippedDecisions.Count -gt 0) {
    @(
        "| Stage | Category Group |"
        "|---|---|"
        ($skippedDecisions | ForEach-Object { "| $($_.Stage) | ``$($_.Group)`` |" })
    ) -join "`n"
} else { "_No jobs were skipped._" }

$stageTable = if ($stageRows.Count -gt 0) {
    @(
        "| | Stage | Result |"
        "|---|---|---|"
        ($stageRows -join "`n")
    ) -join "`n"
} else { "_No stages found._" }

$buildBadge = switch ($build.result) {
    "succeeded"           { "✅ succeeded" }
    "succeededWithIssues" { "⚠️ succeeded with issues" }
    "failed"              { "❌ failed" }
    "canceled"            { "🚫 canceled" }
    default               { "🔄 $($build.status)" }
}

$sessionStart = "<!-- SESSION:$commitSha7 START -->"
$sessionEnd   = "<!-- SESSION:$commitSha7 END -->"

$sessionBody = @"
$sessionStart
<details open>
<summary>🧪 <strong>UI Test Category Detection</strong> — <a href="$commitUrl"><code>$commitSha7</code></a> · <strong>$commitTitle</strong> · <em>$timestamp</em></summary>

---

**Build:** [#$BuildId]($BuildUrl) · $buildBadge
**Detected categories:** ``$detectedCategories``

$summaryLine

#### Stages

$stageTable

<details>
<summary>✅ <strong>Jobs that ran ($($ranDecisions.Count))</strong></summary>

$ranTable

</details>

<details>
<summary>⏭️ <strong>Jobs skipped ($($skippedDecisions.Count))</strong></summary>

$skippedTable

</details>

</details>
$sessionEnd
"@

# ============================================================================
# MERGE WITH EXISTING SESSIONS
# ============================================================================

function Merge-Sessions {
    param([string]$ExistingBody, [string]$NewSession, [string]$Sha7)

    $pattern = '(?s)<!-- SESSION:([a-f0-9]+) START -->.*?<!-- SESSION:\1 END -->'
    $matches = [regex]::Matches($ExistingBody, $pattern)

    $sessions = [ordered]@{}
    foreach ($m in $matches) { $sessions[$m.Groups[1].Value] = $m.Value }
    $sessions[$Sha7] = $NewSession

    $orderedKeys = @($Sha7) + @($sessions.Keys | Where-Object { $_ -ne $Sha7 })
    $blocks = @()
    $first = $true
    foreach ($k in $orderedKeys) {
        $b = $sessions[$k]
        if ($first) {
            $b = $b -replace '<details(?:\s+open)?>', '<details open>'
            $first = $false
        } else {
            $b = $b -replace '<details\s+open>', '<details>'
        }
        $blocks += $b
    }
    return ($blocks -join "`n`n---`n`n")
}

Write-Host "Looking for existing comment on $Repo#$PRNumber..." -ForegroundColor Cyan
$existingId = $null
$existingBody = $null

$existingRaw = gh api "repos/$Repo/issues/$PRNumber/comments" --paginate 2>$null
if ($existingRaw) {
    try {
        $all = $existingRaw | ConvertFrom-Json
        $existing = @($all | Where-Object { $_.body -and $_.body.Contains($MARKER) }) | Select-Object -Last 1
        if ($existing) {
            $existingId = $existing.id
            $existingBody = $existing.body
            Write-Host "Found existing comment (ID: $existingId)" -ForegroundColor Green
        }
    } catch {
        Write-Host "⚠️ Could not parse comments: $_" -ForegroundColor Yellow
    }
}

$authorPing = if ($prAuthor) { "> 👋 @$prAuthor — UI test detection summary updated for the latest commit." } else { "" }

if ($existingBody) {
    $merged = Merge-Sessions -ExistingBody $existingBody -NewSession $sessionBody -Sha7 $commitSha7
    $commentBody = @"
$MARKER

## 🧪 UI Test Category Detection

$authorPing

$merged
"@
} else {
    $commentBody = @"
$MARKER

## 🧪 UI Test Category Detection

$authorPing

$sessionBody
"@
}

$commentBody = $commentBody -replace "`n{4,}", "`n`n`n"

if ($DryRun) {
    Write-Host ""
    Write-Host "=== COMMENT PREVIEW ===" -ForegroundColor Cyan
    Write-Host $commentBody
    Write-Host "=== END PREVIEW ===" -ForegroundColor Cyan
    exit 0
}

$tempFile = [System.IO.Path]::GetTempFileName()
try {
    @{ body = $commentBody } | ConvertTo-Json -Depth 10 | Set-Content -Path $tempFile -Encoding UTF8
    if ($existingId) {
        Write-Host "Updating comment $existingId..." -ForegroundColor Yellow
        gh api --method PATCH "repos/$Repo/issues/comments/$existingId" --input $tempFile | Out-Null
        Write-Host "✅ Updated" -ForegroundColor Green
        Write-Output "COMMENT_ID=$existingId"
    } else {
        Write-Host "Creating new comment..." -ForegroundColor Yellow
        $resp = gh api --method POST "repos/$Repo/issues/$PRNumber/comments" --input $tempFile | ConvertFrom-Json
        Write-Host "✅ Posted (ID: $($resp.id))" -ForegroundColor Green
        Write-Output "COMMENT_ID=$($resp.id)"
    }
} finally {
    Remove-Item $tempFile -ErrorAction SilentlyContinue
}
