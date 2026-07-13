param(
    [Parameter(Mandatory = $true)]
    [string]$OverleafToken,

    [Parameter(Mandatory = $false)]
    [string]$CommitMessage = "Sync local edits",

    [Parameter(Mandatory = $false)]
    [string]$RepoPath = "C:\Users\z0038a8y\Documents\CMRA_Paper\src",

    [Parameter(Mandatory = $false)]
    [string]$GitHubRemote = "origin",

    [Parameter(Mandatory = $false)]
    [string]$GitHubUrl = "https://github.com/mbacher/PhysicsOfPT.git",

    [Parameter(Mandatory = $false)]
    [string]$OverleafUrl = "https://git@git.overleaf.com/6a4b94ee4a557ddc788e81ed"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Args
    )

    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & git @Args 2>&1
    }
    finally {
        $ErrorActionPreference = $oldPreference
    }
    if ($LASTEXITCODE -ne 0) {
        $text = ($output | Out-String).Trim()
        throw "git $($Args -join ' ') failed.`n$text"
    }
    return $output
}

function Invoke-GitAllowFail {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Args
    )

    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & git @Args 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldPreference
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = $output
    }
}

if (-not (Test-Path $RepoPath)) {
    throw "RepoPath does not exist: $RepoPath"
}

Set-Location $RepoPath

if (-not (Test-Path ".git")) {
    throw "No git repository at: $RepoPath"
}

$remotes = (& git remote)
if (-not ($remotes -contains $GitHubRemote)) {
    Invoke-Git -Args @("remote", "add", $GitHubRemote, $GitHubUrl) | Out-Null
}

$remotes = (& git remote)
if (-not ($remotes -contains "overleaf")) {
    Invoke-Git -Args @("remote", "add", "overleaf", $OverleafUrl) | Out-Null
}
else {
    Invoke-Git -Args @("remote", "set-url", "overleaf", $OverleafUrl) | Out-Null
}

${currentBranch} = ((Invoke-Git -Args @("branch", "--show-current")) | Select-Object -First 1).Trim()
$status = (& git status --porcelain)
$localCommit = $null
if ($status) {
    Invoke-Git -Args @("add", ".") | Out-Null
    Invoke-Git -Args @("commit", "-m", $CommitMessage) | Out-Null
    $localCommit = ((Invoke-Git -Args @("rev-parse", "HEAD")) | Select-Object -First 1).Trim()
}

if ($currentBranch -ne "main") {
    Invoke-Git -Args @("checkout", "--quiet", "main") | Out-Null
}
Invoke-Git -Args @("pull", "--ff-only", $GitHubRemote, "main") | Out-Null

if ($localCommit) {
    & git merge-base --is-ancestor $localCommit main 2>$null
    $isAncestor = ($LASTEXITCODE -eq 0)
    if (-not $isAncestor) {
        $cpMainResult = Invoke-GitAllowFail -Args @("cherry-pick", $localCommit)
        $cpMainOutput = $cpMainResult.Output
        $cpMainExit = $cpMainResult.ExitCode
        if ($cpMainExit -ne 0) {
            $cpMainText = ($cpMainOutput | Out-String)
            if ($cpMainText -match "previous cherry-pick is now empty" -or $cpMainText -match "nothing to commit") {
                Invoke-Git -Args @("cherry-pick", "--skip") | Out-Null
            }
            else {
                throw @"
Cherry-pick to local main failed and needs manual conflict resolution.
Run:
  git status
  # resolve conflicts
  git add <files>
  git cherry-pick --continue
Then rerun the script.
"@
            }
        }
    }
}

$mainCommit = ((Invoke-Git -Args @("rev-parse", "main")) | Select-Object -First 1).Trim()
Invoke-Git -Args @("push", $GitHubRemote, "main") | Out-Null

$authOverleafUrl = $OverleafUrl -replace "^https://git@", "https://git:$OverleafToken@"
Invoke-Git -Args @("fetch", $authOverleafUrl, "main:overleaf-main") | Out-Null
Invoke-Git -Args @("checkout", "-B", "overleaf-sync", "overleaf-main") | Out-Null

$cherryPickResult = Invoke-GitAllowFail -Args @("cherry-pick", $mainCommit)
$cherryPickOutput = $cherryPickResult.Output
$cherryPickExit = $cherryPickResult.ExitCode
if ($cherryPickExit -ne 0) {
    $cpText = ($cherryPickOutput | Out-String)
    if ($cpText -match "previous cherry-pick is now empty" -or $cpText -match "nothing to commit") {
        Invoke-Git -Args @("cherry-pick", "--skip") | Out-Null
    }
    else {
        throw @"
Cherry-pick failed and needs manual conflict resolution.
Run:
  git status
  # resolve conflicts
  git add <files>
  git cherry-pick --continue
Then push:
  git push $authOverleafUrl overleaf-sync:main
"@
    }
}

Invoke-Git -Args @("push", $authOverleafUrl, "overleaf-sync:main") | Out-Null
Invoke-Git -Args @("checkout", "--quiet", "main") | Out-Null

Write-Host "Sync complete."
Write-Host "GitHub main  : up to date"
Write-Host "Overleaf main: updated"
