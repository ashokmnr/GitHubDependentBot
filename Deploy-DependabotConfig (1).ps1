<#
.SYNOPSIS
    Deploys a dependabot.yml file to repositories in a GitHub organization using the GitHub CLI (gh).

.DESCRIPTION
    - Targets every repo in an org (processed in batches, default 20) or only the repos you name.
    - Skips repos that already have the file unless -Overwrite is set.
    - Skips repos whose file is already identical (no empty commits).
    - Commits directly to the default branch, or opens a PR with -CreatePullRequest.
    - Supports -WhatIf for a dry run.

    All GitHub calls go through gh:
      gh repo list / gh repo view   -> resolve repos
      gh api                        -> read/write file contents, create branch
      gh pr list / gh pr create     -> pull requests

.PARAMETER Organization
    GitHub organization name.

.PARAMETER SourceFile
    Path to the local dependabot.yml to deploy.

.PARAMETER Repository
    One or more repo names (or org/repo) to target instead of the whole org.

.PARAMETER ExcludeRepository
    Repo names to skip when targeting the whole org.

.PARAMETER Overwrite
    Replace the file if it already exists in the repo.

.PARAMETER CreatePullRequest
    Push to a branch and open a PR instead of committing to the default branch.

.PARAMETER BatchSize
    Repos per batch (default 20).

.PARAMETER PauseSeconds
    Pause between batches to stay clear of GitHub secondary rate limits (default 30).

.PARAMETER Token
    Optional. If omitted, gh uses GH_TOKEN / GITHUB_TOKEN or your `gh auth login` session.

.PARAMETER Hostname
    GitHub host. Use your GHES hostname for GitHub Enterprise Server.

.EXAMPLE
    .\Deploy-DependabotConfig.ps1 -Organization my-org -SourceFile .\dependabot.yml -WhatIf

.EXAMPLE
    .\Deploy-DependabotConfig.ps1 -Organization my-org -SourceFile .\dependabot.yml -Overwrite -CreatePullRequest

.EXAMPLE
    .\Deploy-DependabotConfig.ps1 -Organization my-org -SourceFile .\dependabot.yml -Repository api-orders, web-portal
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'AllRepos')]
param(
    [Parameter(Mandatory)]
    [string]$Organization,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$SourceFile,

    [Parameter(Mandatory, ParameterSetName = 'SpecificRepos')]
    [string[]]$Repository,

    [Parameter(ParameterSetName = 'AllRepos')]
    [string[]]$ExcludeRepository = @(),

    [switch]$Overwrite,
    [switch]$CreatePullRequest,

    [ValidateRange(1, 100)]
    [int]$BatchSize = 20,

    [ValidateRange(0, 3600)]
    [int]$PauseSeconds = 30,

    [string]$TargetPath    = '.github/dependabot.yml',
    [string]$CommitMessage = 'chore: add/update dependabot.yml',
    [string]$PrBranchName  = 'chore/dependabot-config',
    [string]$PrBody        = 'Adds or updates .github/dependabot.yml as part of the org-wide Dependabot rollout.',
    [string]$Token,
    [string]$Hostname      = 'github.com'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Cmdlet = $PSCmdlet
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

#region gh setup
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw 'GitHub CLI (gh) not found. Install it from https://cli.github.com (Windows: winget install --id GitHub.cli)'
}

$env:GH_PROMPT_DISABLED   = '1'
$env:GH_NO_UPDATE_NOTIFIER = '1'
if ($Hostname -ne 'github.com') { $env:GH_HOST = $Hostname }
if ($Token) {
    if ($Hostname -eq 'github.com') { $env:GH_TOKEN = $Token } else { $env:GH_ENTERPRISE_TOKEN = $Token }
}
#endregion

#region Helpers
function Invoke-Gh {
    <#
      Runs gh with the given arguments, returns stdout as a string.
      Throws an exception carrying the HTTP status in .Data['Status'] on failure.
      Retries automatically on rate limiting.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$AllowNotFound
    )
    $maxAttempts = 4
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        # Native stderr + 'Stop' would throw in Windows PowerShell 5.1, so relax it locally.
        $ErrorActionPreference = 'Continue'
        $output   = & gh @Arguments 2>&1
        $exitCode = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'

        $stdout = ($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n"
        $stderr = ($output | Where-Object { $_ -is   [System.Management.Automation.ErrorRecord] } |
                   ForEach-Object { $_.ToString() }) -join ' '

        if ($exitCode -eq 0) { return $stdout }

        $status = if ($stderr -match 'HTTP (\d{3})') { [int]$Matches[1] } else { 0 }
        if ($status -eq 404 -and $AllowNotFound) { return $null }

        if ($stderr -match 'rate limit' -or $status -eq 429) {
            if ($attempt -lt $maxAttempts) {
                $wait = 60 * $attempt
                Write-Warning "Rate limited. Waiting $wait s before retry $($attempt + 1)/$maxAttempts..."
                Start-Sleep -Seconds $wait
                continue
            }
        }

        $ex = [System.Exception]::new("gh $($Arguments[0]) failed (HTTP $status): $stderr".Trim())
        $ex.Data['Status'] = $status
        throw $ex
    }
}

function Get-StatusCode {
    param($ErrorRecord)
    $s = $ErrorRecord.Exception.Data['Status']
    if ($s) { [int]$s } else { 0 }
}

function Get-RemoteFile {
    param([string]$Repo, [string]$Branch)
    $ref  = [uri]::EscapeDataString($Branch)
    $json = Invoke-Gh -AllowNotFound -Arguments @('api', "repos/$Organization/$Repo/contents/${TargetPath}?ref=$ref")
    if ($json) { $json | ConvertFrom-Json } else { $null }
}

function ConvertFrom-RemoteContent {
    param($File)
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($File.content -replace '\s', '')))
}

function Test-SameContent {
    param([string]$A, [string]$B)
    ($A -replace "`r`n", "`n").Trim() -eq ($B -replace "`r`n", "`n").Trim()
}

function ConvertTo-RepoInfo {
    param($GhRepo)
    $branch = $null
    if ($GhRepo.defaultBranchRef) { $branch = $GhRepo.defaultBranchRef.name }
    [pscustomobject]@{
        name           = $GhRepo.name
        default_branch = $branch
        archived       = [bool]$GhRepo.isArchived
        empty          = [bool]$GhRepo.isEmpty
    }
}

function New-Result {
    param([string]$Repo, [string]$Status, [string]$Detail = '', [string]$Url = '')
    [pscustomobject]@{
        Repository = $Repo
        Status     = $Status
        Detail     = $Detail
        Url        = $Url
        Timestamp  = (Get-Date).ToString('s')
    }
}

function Deploy-DependabotFile {
    param([Parameter(Mandatory)]$Repo)

    $name     = $Repo.name
    $base     = $Repo.default_branch
    $fullName = "$Organization/$name"

    try {
        if ($Repo.archived)               { return New-Result $name 'Skipped' 'Archived repository' }
        if ($Repo.empty -or -not $base)   { return New-Result $name 'Skipped' 'Empty repository' }

        $existing = Get-RemoteFile -Repo $name -Branch $base
        if ($existing) {
            if (Test-SameContent (ConvertFrom-RemoteContent $existing) $script:LocalText) {
                return New-Result $name 'Unchanged' 'Identical file already on default branch' $existing.html_url
            }
            if (-not $Overwrite) {
                return New-Result $name 'Skipped' 'File exists (use -Overwrite to replace)' $existing.html_url
            }
        }

        $action = if ($existing) { 'Update' } else { 'Create' }
        $mode   = if ($CreatePullRequest) { 'via PR' } else { "on $base" }
        if (-not $script:Cmdlet.ShouldProcess($fullName, "$action $TargetPath $mode")) {
            return New-Result $name 'WhatIf' "$action $mode"
        }

        $targetBranch = $base
        $fileSha      = if ($existing) { $existing.sha } else { $null }
        $skipCommit   = $false

        if ($CreatePullRequest) {
            $targetBranch = $PrBranchName

            $baseSha = Invoke-Gh @('api', "repos/$fullName/git/ref/heads/$base", '--jq', '.object.sha')
            try {
                Invoke-Gh @('api', '--method', 'POST', "repos/$fullName/git/refs",
                            '-f', "ref=refs/heads/$PrBranchName", '-f', "sha=$baseSha") | Out-Null
            }
            catch {
                if ((Get-StatusCode $_) -ne 422) { throw }   # 422 = branch already exists, reuse it
            }

            $branchFile = Get-RemoteFile -Repo $name -Branch $PrBranchName
            $fileSha    = if ($branchFile) { $branchFile.sha } else { $null }
            $skipCommit = [bool]($branchFile -and (Test-SameContent (ConvertFrom-RemoteContent $branchFile) $script:LocalText))
        }

        $commitUrl = ''
        if (-not $skipCommit) {
            $ghArgs = @('api', '--method', 'PUT', "repos/$fullName/contents/$TargetPath",
                        '-f', "message=$CommitMessage",
                        '-f', "content=$script:LocalB64",
                        '-f', "branch=$targetBranch",
                        '--jq', '.commit.html_url')
            if ($fileSha) { $ghArgs += @('-f', "sha=$fileSha") }
            $commitUrl = Invoke-Gh $ghArgs
        }

        if (-not $CreatePullRequest) {
            $status = if ($existing) { 'Updated' } else { 'Created' }
            return New-Result $name $status "Committed to $base" $commitUrl
        }

        $openPr = Invoke-Gh @('pr', 'list', '--repo', $fullName, '--head', $PrBranchName, '--base', $base,
                              '--state', 'open', '--json', 'url', '--jq', '.[].url')
        if ($openPr) {
            return New-Result $name 'PR Exists' 'Branch updated; PR already open' (($openPr -split "`n")[0])
        }

        $prUrl = Invoke-Gh @('pr', 'create', '--repo', $fullName, '--base', $base, '--head', $PrBranchName,
                             '--title', $CommitMessage, '--body', $PrBody)
        return New-Result $name 'PR Opened' "$action $TargetPath" (($prUrl -split "`n")[-1])
    }
    catch {
        $status = Get-StatusCode $_
        if ($status -eq 409) { return New-Result $name 'Skipped' 'Empty repository' }
        return New-Result $name 'Failed' $_.Exception.Message
    }
}
#endregion

#region Pre-flight
try {
    Invoke-Gh @('auth', 'status', '--hostname', $Hostname) | Out-Null
}
catch {
    throw "gh is not authenticated for $Hostname. Set GH_TOKEN, pass -Token, or run 'gh auth login'. $($_.Exception.Message)"
}

$resolvedSource   = (Resolve-Path $SourceFile).Path
$localBytes       = [IO.File]::ReadAllBytes($resolvedSource)
$script:LocalB64  = [Convert]::ToBase64String($localBytes)
$script:LocalText = [Text.Encoding]::UTF8.GetString($localBytes)
if ($script:LocalText -notmatch '(?m)^\s*version:\s*2\s*$') {
    throw "$SourceFile does not look like a dependabot config (missing 'version: 2')."
}
#endregion

#region Resolve target repos
$results    = [System.Collections.Generic.List[object]]::new()
$jsonFields = 'name,defaultBranchRef,isArchived,isEmpty'

if ($PSCmdlet.ParameterSetName -eq 'SpecificRepos') {
    Write-Host "Resolving $($Repository.Count) specified repo(s) in '$Organization'..." -ForegroundColor Cyan
    $repos = foreach ($r in $Repository) {
        $repoName = ($r -split '/')[-1].Trim()
        try {
            ConvertTo-RepoInfo (Invoke-Gh @('repo', 'view', "$Organization/$repoName", '--json', $jsonFields) | ConvertFrom-Json)
        }
        catch {
            $results.Add((New-Result $repoName 'Failed' "Repo not found or no access: $($_.Exception.Message)"))
        }
    }
}
else {
    Write-Host "Listing all repos in '$Organization'..." -ForegroundColor Cyan
    $listJson = Invoke-Gh @('repo', 'list', $Organization, '--limit', '5000', '--no-archived', '--json', $jsonFields)
    $repos = ($listJson | ConvertFrom-Json) |
        ForEach-Object { ConvertTo-RepoInfo $_ } |
        Where-Object { $_.name -notin $ExcludeRepository }
}

$repos = @($repos | Where-Object { $_ } | Sort-Object name)
if ($repos.Count -eq 0) {
    Write-Warning 'No repositories to process.'
    if ($results.Count) {
        $results | Format-Table -AutoSize
        exit 1
    }
    return
}
#endregion

#region Process in batches
$total      = $repos.Count
$batchCount = [math]::Ceiling($total / $BatchSize)
$index      = 0

Write-Host "Processing $total repo(s) in $batchCount batch(es) of up to $BatchSize. Overwrite=$Overwrite, PR mode=$CreatePullRequest" -ForegroundColor Cyan

$statusColors = @{
    Created = 'Green'; Updated = 'Green'; 'PR Opened' = 'Green'; 'PR Exists' = 'DarkGreen'
    Unchanged = 'DarkGray'; Skipped = 'Yellow'; WhatIf = 'Magenta'; Failed = 'Red'
}

for ($b = 0; $b -lt $batchCount; $b++) {
    $slice = @($repos | Select-Object -Skip ($b * $BatchSize) -First $BatchSize)
    Write-Host "`n=== Batch $($b + 1)/$batchCount ($($slice.Count) repos) ===" -ForegroundColor Cyan

    foreach ($repo in $slice) {
        $index++
        Write-Progress -Activity 'Deploying dependabot.yml' -Status "$index/$total : $($repo.name)" `
                       -PercentComplete (($index / $total) * 100)

        $result = Deploy-DependabotFile -Repo $repo
        $results.Add($result)

        $color = if ($statusColors.ContainsKey($result.Status)) { $statusColors[$result.Status] } else { 'White' }
        Write-Host ("[{0,-9}] {1} {2}" -f $result.Status, $result.Repository, $result.Detail) -ForegroundColor $color
    }

    if ($b -lt $batchCount - 1 -and $PauseSeconds -gt 0 -and -not $WhatIfPreference) {
        Write-Host "Pausing $PauseSeconds s before next batch..." -ForegroundColor DarkGray
        Start-Sleep -Seconds $PauseSeconds
    }
}
Write-Progress -Activity 'Deploying dependabot.yml' -Completed
#endregion

#region Summary
Write-Host "`n=== Summary ===" -ForegroundColor Cyan
$results | Group-Object Status | Sort-Object Name |
    Select-Object @{ n = 'Status'; e = { $_.Name } }, Count | Format-Table -AutoSize

$failed = @($results | Where-Object Status -eq 'Failed')
if ($failed.Count) {
    Write-Warning "$($failed.Count) repo(s) failed. Re-run them with: -Repository $(($failed.Repository) -join ', ')"
    exit 1
}
#endregion
