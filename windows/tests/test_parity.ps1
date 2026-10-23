# windows/tests/test_parity.ps1 -- runs the same inputs through tuned-common.sh (in WSL) and
# windows/tuned-common.ps1 and requires the same result: the same text on success, and failure on
# both when either fails. Needs WSL with a distro that has bash, git and python3.
# Run: pwsh -File windows/tests/test_parity.ps1 [-Distro u26]. Exits 1 on any difference.
param([string]$Distro = '')

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\tuned-common.ps1"

$wslArgs = if ($Distro) { @('-d', $Distro) } else { @() }
function ConvertTo-WslPath([string]$p) { '/mnt/' + $p.Substring(0, 1).ToLower() + ($p.Substring(2) -replace '\\', '/') }
$caseSh = ConvertTo-WslPath (Join-Path $PSScriptRoot 'parity_case.sh')

$tmp = Join-Path ([IO.Path]::GetTempPath()) "tuned-parity-$PID"
New-Item -ItemType Directory -Path $tmp | Out-Null
$argsFile = Join-Path $tmp 'args.txt'

# One result per side: "ok:<text>" or "err" (the message differs by design: bash prints, PowerShell throws).
function Invoke-Bash([string]$Fn, [string[]]$Arg) {
    [IO.File]::WriteAllText($argsFile, (($Arg -join "`n") + $(if ($Arg.Count) { "`n" } else { '' })), [Text.UTF8Encoding]::new($false))
    $out = & wsl @wslArgs -- bash $caseSh $Fn (ConvertTo-WslPath $argsFile) 2>$null
    if ($LASTEXITCODE -ne 0) { return 'err' }
    'ok:' + (($out -join "`n").TrimEnd("`n"))
}
function Invoke-Ps([scriptblock]$Block) {
    try { $r = & $Block; 'ok:' + ($(if ($null -eq $r) { '' } else { "$r" }))  } catch { 'err' }
}

$script:pass = 0; $script:fail = 0
function Compare-Case([string]$Name, [string]$Fn, [string[]]$Arg, [scriptblock]$Ps) {
    $b = Invoke-Bash $Fn $Arg
    $p = Invoke-Ps $Ps
    if ($b -ceq $p) { $script:pass++ } else { $script:fail++; Write-Host "DIFF $Name`n  bash: $b`n  ps:   $p" }
}

try {
    # Known difference, not tested: GNU date rejects year 9999 ("invalid date '9999-12-31'"), so bash
    # calls 99991231 invalid and PowerShell accepts it. Every year up to 2999 agrees.
    # gpu_tuned_valid_date prints nothing: compare its exit status through a wrapper-free echo
    foreach ($d in '20261010', '20240229', '20230229', '20261301', '01234567', '2026101', '20500101', '25001231', '10000101', 'abcdefgh') {
        $b = Invoke-Bash 'gpu_tuned_valid_date' @($d)
        $bashOk = $b -ceq 'ok:'
        if ($bashOk -eq (Test-TunedValidDate $d)) { $script:pass++ } else { $script:fail++; Write-Host "DIFF valid_date $d  bash ok=$bashOk" }
    }

    foreach ($v in '2.15.0+gb10.cu134.20261010.1', '2.15.0+gb10.cu134.20261010.0', '2.15.0+gb10.cu134.20261010',
        '2.15.0+g44a0a3c96.gb10.cu134.20261010', '2.15.0.dev20260911', '0.7.0+gb10.cu134.tuning.35', '1.0+gb10.cu134.20261310',
        '1.0+gb10.cu134.20261010.01', 'v0.20261016.0-gb10-cu133', 'v0.20261016.3-n1x-cu134', 'v26.12-gb10-cu134-g9d97792e',
        'v0.20261016.00-gb10-cu133', 'v0.20261316.0-gb10-cu133', '1.0+GB10.cu134.20261010', 'v0.20261016.0-GB10-cu133') {
        Compare-Case "date_label $v" 'gpu_tuned_date_label' @($v) ([scriptblock]::Create("Get-TunedDateLabel '$v'"))
    }

    foreach ($l in '20261010', '20261010.2', '20261010.10') {
        Compare-Case "label_seq $l" 'gpu_tuned_label_seq' @($l) ([scriptblock]::Create("Get-TunedLabelSeq '$l'"))
    }

    foreach ($c in @('gb10 cu134 20261011', 'n1x cu134 20261011.2', 'n1x 134 20261011', 'n1x cu134 20261011.0', 'n1x cu134 20261311',
            'GB10 cu134 20261011', 'n1x cu134 20261011.01', 'n1x cu134 20261011.', '1x cu134 20261011')) {
        $a = $c -split ' '
        Compare-Case "native_tag $c" 'gpu_tuned_native_tag' $a ([scriptblock]::Create("New-TunedNativeTag '$($a[0])' '$($a[1])' '$($a[2])'"))
    }

    foreach ($c in @('gb10 134 20261010 0', 'n1x 134 20261010 12', 'GB10 134 20261010 0', 'gb10 13.4 20261010 0', 'gb10 134 20261310 0', 'gb10 134 20261010 01')) {
        $a = $c -split ' '
        Compare-Case "local_version_dated $c" 'gpu_tuned_local_version_dated' $a ([scriptblock]::Create("New-TunedLocalVersionDated '$($a[0])' '$($a[1])' '$($a[2])' '$($a[3])'"))
    }

    # next_seq: first argument is the date, the rest are the taken labels
    foreach ($c in @('20261010', '20261010 20261010', '20261010 20261010 20261010.2', '20261010 20261009 20261011.1',
            '20261010 20261010 20261010.1 20261010.2 20261010.10', '2026')) {
        $a = $c -split ' '
        $taken = if ($a.Count -gt 1) { "@('" + (($a[1..($a.Count - 1)]) -join "','") + "')" } else { '@()' }
        Compare-Case "next_seq $c" 'gpu_tuned_next_seq' $a ([scriptblock]::Create("Get-TunedNextSeq '$($a[0])' $taken"))
    }

    foreach ($u in 'https://github.com/zbrad/llama.cpp.git', 'git@github.com:zbrad/x.git', 'ssh://org-123@github.com/zbrad/x.git',
        'https://ghp_abc123@github.com/zbrad/x.git', 'ssh://git@host:2222/o/r.git', 'http://user:pw@example.com/o/r') {
        Compare-Case "public_repo_url $u" 'gpu_tuned_public_repo_url' @($u) ([scriptblock]::Create("Get-TunedPublicRepoUrl '$u'"))
    }

    # build-info JSON: byte for byte, including escaping of quotes, backslashes and non-ASCII
    $jsonCases = @(
        @(),
        @('release=v0.20261011.0-n1x-cu134', 'fork.url=u', 'fork.dirty:bool=false', 'fork.commit_count:int=12', 'x:null='),
        @('t=a"b\c' + [char]0xe9 + [char]0x4e2d + [char]::ConvertFromUtf32(0x1f600)),
        @('t=tab' + "`t" + 'x'), @('nope'), @('Bad=1'), @('n:int=007'), @('b:bool=yes'), @('a=1', 'a=2'), @('a=1', 'a.b=2'),
        @('a.b=1', 'a.c=2', 'd=3'), @('s=with space and = sign'), @('u=' + [char]0x7f + 'del')
    )
    $i = 0
    foreach ($c in $jsonCases) {
        $i++
        $ps = { New-TunedBuildInfoJson -Field $c }.GetNewClosure()
        Compare-Case "build_info_json #$i" 'gpu_tuned_build_info_json' ([string[]]$c) $ps
    }

    # head date and label allocation on a scratch repo with an origin: a late-evening commit west of UTC
    $repo = Join-Path $tmp 'repo'; $bare = Join-Path $tmp 'origin.git'
    git init -q $repo; git init -q --bare $bare
    git -C $repo config user.email t@example.com; git -C $repo config user.name t
    git -C $repo remote add origin $bare
    Set-Content -LiteralPath (Join-Path $repo 'f') 'x'
    git -C $repo add f 2>$null
    $env:GIT_COMMITTER_DATE = '2026-10-10T23:30:00-07:00'; $env:GIT_AUTHOR_DATE = $env:GIT_COMMITTER_DATE
    git -C $repo commit -q -m c1
    Remove-Item Env:GIT_COMMITTER_DATE, Env:GIT_AUTHOR_DATE
    $wslRepo = ConvertTo-WslPath $repo; $wslBare = ConvertTo-WslPath $bare
    Remove-Item Env:GPU_TUNED_LABEL_SEQ -ErrorAction SilentlyContinue
    Compare-Case 'head_date' 'gpu_tuned_head_date' @($wslRepo) { Get-TunedHeadDate $repo }
    # bash reaches the bare origin by its WSL path, PowerShell by its Windows path: same repo, so give each its own remote name
    git -C $repo remote add wslorigin $wslBare
    foreach ($step in @(
            @{ tag = $null; label = 'no tags' },
            @{ tag = 'v0.20261011.0-n1x-cu134'; label = 'one tag' },
            @{ tag = '2.15.0+n1x.cu134.20261011.1'; label = 'wheel tag' },
            @{ tag = 'v0.20261012.0-n1x-cu134'; label = 'other date' },
            @{ tag = 'v0.20261011.3-gb10-cu133'; label = 'gap at 2' })) {
        if ($step.tag) { git -C $repo tag $step.tag; git -C $repo push -q origin $step.tag 2>$null }
        Compare-Case "allocate_date_label ($($step.label))" 'gpu_tuned_allocate_date_label' @($wslRepo, 'wslorigin') { New-TunedDateLabel $repo origin }
    }
    $env:WSLENV = 'GPU_TUNED_LABEL_SEQ'   # lets the variable reach the bash side
    $env:GPU_TUNED_LABEL_SEQ = '5'
    Compare-Case 'allocate_date_label override' 'gpu_tuned_allocate_date_label' @($wslRepo, 'wslorigin') { New-TunedDateLabel $repo origin }
    $env:GPU_TUNED_LABEL_SEQ = '05'
    Compare-Case 'allocate_date_label bad override' 'gpu_tuned_allocate_date_label' @($wslRepo, 'wslorigin') { New-TunedDateLabel $repo origin }
    Remove-Item Env:GPU_TUNED_LABEL_SEQ, Env:WSLENV
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "parity passed: $script:pass, differed: $script:fail"
if ($script:fail) { exit 1 }
