# windows/tests/test_common.ps1 -- tests for windows/tuned-common.ps1. Plain pwsh, no Pester
# (the box ships Pester 3.4 and these need nothing from it). Run: pwsh -File windows/tests/test_common.ps1
# [-Exe <a self-contained .exe to stamp a copy of; default System32\whoami.exe>]. Exits 1 if any case fails.
param([string]$Exe = '')

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\tuned-common.ps1"

$script:pass = 0; $script:fail = 0
function Assert-Equal($Name, $Want, $Got) {
    if ($Want -ceq $Got) { $script:pass++ } else { $script:fail++; Write-Host "FAIL $Name`n  want: '$Want'`n  got:  '$Got'" }
}
function Assert-Throws($Name, [scriptblock]$Block, $Match = '') {
    try { & $Block | Out-Null; $script:fail++; Write-Host "FAIL $Name (did not throw)" }
    catch { if ($_.Exception.Message -match $Match) { $script:pass++ } else { $script:fail++; Write-Host "FAIL $Name`n  message: $($_.Exception.Message)" } }
}

# scratch repos live under the temp dir, created and removed at literal paths
$tmp = Join-Path ([IO.Path]::GetTempPath()) "tuned-ps-test-$PID"
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    # --- dates and labels (cases from tests/test_common.sh and docs/VERSIONING.md) ---
    Assert-Equal 'valid_date ok' $true (Test-TunedValidDate '20261010')
    Assert-Equal 'valid_date leap day' $true (Test-TunedValidDate '20240229')
    Assert-Equal 'valid_date not leap' $false (Test-TunedValidDate '20230229')
    Assert-Equal 'valid_date month 13' $false (Test-TunedValidDate '20261301')
    Assert-Equal 'valid_date leading zero' $false (Test-TunedValidDate '01234567')
    Assert-Equal 'valid_date short' $false (Test-TunedValidDate '2026101')
    Assert-Equal 'valid_date trailing newline' $false (Test-TunedValidDate "20261010`n")

    Assert-Equal 'local_version_dated' 'gb10.cu134.20261010.0' (New-TunedLocalVersionDated gb10 134 20261010)
    Assert-Equal 'local_version_dated seq' 'n1x.cu134.20261010.12' (New-TunedLocalVersionDated n1x 134 20261010 12)
    Assert-Throws 'local_version_dated bad variant' { New-TunedLocalVersionDated GB10 134 20261010 } 'variant'
    Assert-Throws 'local_version_dated bad cuda' { New-TunedLocalVersionDated gb10 13.4 20261010 } 'cuda'
    Assert-Throws 'local_version_dated bad date' { New-TunedLocalVersionDated gb10 134 20261310 } 'date'
    Assert-Throws 'local_version_dated padded seq' { New-TunedLocalVersionDated gb10 134 20261010 01 } 'sequence'

    Assert-Equal 'date_label wheel .1' '20261010.1' (Get-TunedDateLabel '2.15.0+gb10.cu134.20261010.1')
    Assert-Equal 'date_label wheel .0 is bare' '20261010' (Get-TunedDateLabel '2.15.0+gb10.cu134.20261010.0')
    Assert-Equal 'date_label wheel bare' '20261010' (Get-TunedDateLabel '2.15.0+gb10.cu134.20261010')
    Assert-Equal 'date_label sha prefix' '20261010' (Get-TunedDateLabel '2.15.0+g44a0a3c96.gb10.cu134.20261010')
    Assert-Equal 'date_label public dev version' $null (Get-TunedDateLabel '2.15.0.dev20260911')
    Assert-Equal 'date_label counter form' $null (Get-TunedDateLabel '0.7.0+gb10.cu134.tuning.35')
    Assert-Equal 'date_label impossible date' $null (Get-TunedDateLabel '1.0+gb10.cu134.20261310')
    Assert-Equal 'date_label padded seq' $null (Get-TunedDateLabel '1.0+gb10.cu134.20261010.01')
    Assert-Equal 'date_label native .0' '20261016' (Get-TunedDateLabel 'v0.20261016.0-gb10-cu133')
    Assert-Equal 'date_label native .3' '20261016.3' (Get-TunedDateLabel 'v0.20261016.3-n1x-cu134')
    Assert-Equal 'date_label native old sha form' $null (Get-TunedDateLabel 'v26.12-gb10-cu134-g9d97792e')

    Assert-Equal 'label_seq bare' '0' (Get-TunedLabelSeq '20261010')
    Assert-Equal 'label_seq 2' '2' (Get-TunedLabelSeq '20261010.2')

    Assert-Equal 'native_tag seq 0' 'v0.20261011.0-n1x-cu134' (New-TunedNativeTag n1x cu134 20261011)
    Assert-Equal 'native_tag seq 2' 'v0.20261011.2-n1x-cu134' (New-TunedNativeTag n1x cu134 20261011.2)
    Assert-Throws 'native_tag no cu prefix' { New-TunedNativeTag n1x 134 20261011 } 'need'
    Assert-Throws 'native_tag explicit .0' { New-TunedNativeTag n1x cu134 20261011.0 } 'need'
    Assert-Throws 'native_tag bad date' { New-TunedNativeTag n1x cu134 20261311 } 'need'
    Assert-Equal 'native_tag round trip' '20261011.2' (Get-TunedDateLabel (New-TunedNativeTag n1x cu134 20261011.2))

    Assert-Equal 'next_seq empty' '0' (Get-TunedNextSeq 20261010 @())
    Assert-Equal 'next_seq bare taken' '1' (Get-TunedNextSeq 20261010 @('20261010'))
    Assert-Equal 'next_seq fills gap' '1' (Get-TunedNextSeq 20261010 @('20261010', '20261010.2'))
    Assert-Equal 'next_seq other date ignored' '0' (Get-TunedNextSeq 20261010 @('20261009', '20261011.1'))
    Assert-Equal 'next_seq 2 before 10' '3' (Get-TunedNextSeq 20261010 @('20261010', '20261010.1', '20261010.2', '20261010.10'))
    Assert-Throws 'next_seq bad date' { Get-TunedNextSeq 2026 @() } 'not a valid'

    # --- git-backed allocation: a commit made late in the evening west of UTC is the next day in UTC ---
    $repo = Join-Path $tmp 'repo'
    $bare = Join-Path $tmp 'origin.git'
    git init -q $repo; git init -q --bare $bare
    git -C $repo config user.email t@example.com; git -C $repo config user.name t
    git -C $repo remote add origin $bare
    Set-Content -LiteralPath (Join-Path $repo 'f') 'x'
    git -C $repo add f
    $env:GIT_COMMITTER_DATE = '2026-10-10T23:30:00-07:00'   # = 2026-10-11 06:30 UTC
    $env:GIT_AUTHOR_DATE = $env:GIT_COMMITTER_DATE
    git -C $repo commit -q -m c1
    Remove-Item Env:GIT_COMMITTER_DATE, Env:GIT_AUTHOR_DATE
    Assert-Equal 'head_date is UTC' '20261011' (Get-TunedHeadDate $repo)
    Assert-Equal 'head_date ignores TZ' '20261011' (& { $env:TZ = 'America/Los_Angeles'; try { Get-TunedHeadDate $repo } finally { Remove-Item Env:TZ } })
    Assert-Throws 'head_date not a repo' { Get-TunedHeadDate $tmp } 'cannot read'

    Remove-Item Env:GPU_TUNED_LABEL_SEQ -ErrorAction SilentlyContinue
    Assert-Equal 'allocate first' '20261011' (New-TunedDateLabel $repo origin)
    git -C $repo tag 'v0.20261011.0-n1x-cu134'
    git -C $repo push -q origin 'v0.20261011.0-n1x-cu134'
    Assert-Equal 'allocate after one on origin' '20261011.1' (New-TunedDateLabel $repo origin)
    git -C $repo tag -d 'v0.20261011.0-n1x-cu134' | Out-Null
    Assert-Equal 'allocate sees origin-only tag' '20261011.1' (New-TunedDateLabel $repo origin)
    git -C $repo tag '2.15.0+n1x.cu134.20261011.1'
    Assert-Equal 'allocate sees local wheel tag too' '20261011.2' (New-TunedDateLabel $repo origin)
    git -C $repo tag 'v0.20261012.0-n1x-cu134'
    Assert-Equal 'allocate ignores other dates' '20261011.2' (New-TunedDateLabel $repo origin)
    Assert-Throws 'allocate unreadable remote fails loudly' { New-TunedDateLabel $repo (Join-Path $tmp 'nope.git') } 'GPU_TUNED_LABEL_SEQ'
    $env:GPU_TUNED_LABEL_SEQ = '0'
    Assert-Equal 'allocate override offline' '20261011' (New-TunedDateLabel $repo (Join-Path $tmp 'nope.git'))
    $env:GPU_TUNED_LABEL_SEQ = '7'
    Assert-Equal 'allocate override 7' '20261011.7' (New-TunedDateLabel $repo origin)
    $env:GPU_TUNED_LABEL_SEQ = '07'
    Assert-Throws 'allocate override padded' { New-TunedDateLabel $repo origin } 'canonical'
    Remove-Item Env:GPU_TUNED_LABEL_SEQ

    # --- repo URL scrubbing ---
    Assert-Equal 'url https .git' 'https://github.com/zbrad/llama.cpp' (Get-TunedPublicRepoUrl 'https://github.com/zbrad/llama.cpp.git')
    Assert-Equal 'url scp' 'https://github.com/zbrad/x' (Get-TunedPublicRepoUrl 'git@github.com:zbrad/x.git')
    Assert-Equal 'url ssh alias user' 'https://github.com/zbrad/x' (Get-TunedPublicRepoUrl 'ssh://org-123@github.com/zbrad/x.git')
    Assert-Equal 'url token dropped' 'https://github.com/zbrad/x' (Get-TunedPublicRepoUrl 'https://ghp_abc123@github.com/zbrad/x.git')

    # --- JSON ---
    Assert-Equal 'json empty' '{"schema":"tuned-build-info/1"}' (New-TunedBuildInfoJson)
    Assert-Equal 'json nesting and types' '{"schema":"tuned-build-info/1","release":"v0.20261011.0-n1x-cu134","fork":{"url":"u","dirty":false,"commit_count":12},"x":null}' `
        (New-TunedBuildInfoJson @('release=v0.20261011.0-n1x-cu134', 'fork.url=u', 'fork.dirty:bool=false', 'fork.commit_count:int=12', 'x:null='))
    Assert-Equal 'json escapes' ('{"schema":"tuned-build-info/1","t":"a\"b\\c' + [char]92 + 'u00e9' + [char]92 + 'u4e2d"}') (New-TunedBuildInfoJson @("t=a`"b\c$([char]0xe9)$([char]0x4e2d)"))
    Assert-Throws 'json no equals' { New-TunedBuildInfoJson @('nope') } 'name=value'
    Assert-Throws 'json bad name' { New-TunedBuildInfoJson @('Bad=1') } 'bad field'
    Assert-Throws 'json bad int' { New-TunedBuildInfoJson @('n:int=007') } 'canonical'
    Assert-Throws 'json bad bool' { New-TunedBuildInfoJson @('b:bool=yes') } 'true or false'
    Assert-Throws 'json duplicate' { New-TunedBuildInfoJson @('a=1', 'a=2') } 'duplicate'
    Assert-Throws 'json value and parent' { New-TunedBuildInfoJson @('a=1', 'a.b=2') } 'both a value and a parent'
    Assert-Throws 'json control char' { New-TunedBuildInfoJson @("a=x`ty`u{1}") } 'control character'

    # --- sidecar from inside the repo (fork.* come from git) ---
    $sidecar = Join-Path $tmp 'BUILD_INFO.json'
    Push-Location $repo
    try { Write-TunedBuildInfoJson $sidecar @('release=v0.20261011.2-n1x-cu134', 'package=llama.cpp', 'fork.commit_count:int=1') } finally { Pop-Location }
    $text = [IO.File]::ReadAllText($sidecar)
    Assert-Equal 'sidecar ends with one LF' $true ($text.EndsWith("}`n") -and -not $text.Contains("`r"))
    Assert-Equal 'sidecar no BOM' 0x7b ([IO.File]::ReadAllBytes($sidecar)[0])
    Test-TunedBuildInfoJsonFile $sidecar @('release=v0.20261011.2-n1x-cu134', 'package=llama.cpp', 'fork.dirty:bool=false')
    Assert-Throws 'sidecar verify wrong value' { Test-TunedBuildInfoJsonFile $sidecar @('release=v0.1.0-x-cu1') } 'expected'
    Assert-Throws 'sidecar verify empty' { Test-TunedBuildInfoJsonFile (Join-Path $tmp 'missing.json') } 'missing or empty'

    # --- PE version resource, on a copy of a real executable ---
    if (-not $Exe) { $Exe = Join-Path $env:SystemRoot 'System32\whoami.exe' }   # self-contained, runs with no arguments
    $copy = Join-Path $tmp 'stamped.exe'
    Copy-Item -LiteralPath $Exe $copy
    Push-Location $repo
    try {
        Set-TunedExeBuildInfo $copy @('release=v0.20261011.2-n1x-cu134', 'package=llama.cpp', 'component=stamped')
        Set-TunedExeBuildInfo $copy @('release=v0.20261011.3-n1x-cu134', 'package=llama.cpp', 'component=stamped')   # idempotent: replaces
    } finally { Pop-Location }
    $vi = [Diagnostics.FileVersionInfo]::GetVersionInfo($copy)
    Assert-Equal 'exe FileVersion' 'v0.20261011.3-n1x-cu134' $vi.FileVersion
    Assert-Equal 'exe ProductVersion' 'v0.20261011.3-n1x-cu134' $vi.ProductVersion
    Assert-Equal 'exe ProductName' 'llama.cpp' $vi.ProductName
    Test-TunedBuildInfo $copy @('release=v0.20261011.3-n1x-cu134', 'component=stamped', 'fork.dirty:bool=false')
    Assert-Throws 'exe verify stale release' { Test-TunedBuildInfo $copy @('release=v0.20261011.2-n1x-cu134') } 'expected'
    Assert-Throws 'exe unstamped fails' { Get-TunedBuildInfo $Exe } 'no tuned build-info'
    Assert-Throws 'exe stamp needs release' { Set-TunedExeBuildInfo $copy @('package=x') } 'release'
    Assert-Equal 'stamped exe still runs' ((& $Exe) -join "`n") ((& $copy) -join "`n")
    Assert-Equal 'source exe untouched' $false ((Get-FileHash $Exe).Hash -eq (Get-FileHash $copy).Hash)
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "passed: $script:pass, failed: $script:fail"
if ($script:fail) { exit 1 }
