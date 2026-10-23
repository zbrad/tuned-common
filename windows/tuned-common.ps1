# windows/tuned-common.ps1 -- PowerShell port of the identity and build-info parts of
# tuned-common.sh, for native Windows builds (no bash, no objcopy). Dot-source it:
#
#   . "$PSScriptRoot\tuned-common.ps1"
#
# Requires PowerShell 7+ and git on PATH. Functions throw on error (the bash ones return 1
# with a message on stderr); the "never fails" readers return $null instead.
#
# Parity: every function below behaves like the bash function named in its header comment, on
# the same inputs, and tests/test_parity.ps1 compares the two through WSL. The rules live in
# docs/VERSIONING.md and docs/ARCHITECTURE.md (E1-E8, H7); this file only implements them.
#
# Not ported: the free-text stamp (gpu_tuned_embed_build_info, gpu_tuned_git_provenance, kept
# in bash for repos that have not moved to the JSON stamp) and everything that needs an ELF
# (objcopy/patchelf, RUNPATH, ldd). A PE file carries the JSON stamp as a version resource
# instead (Set-TunedExeBuildInfo), and a tarball carries BUILD_INFO.json beside its files.

Set-StrictMode -Version Latest

# --- labels -----------------------------------------------------------------------------------

# gpu_tuned_valid_date -- an 8-digit real calendar date, not starting with 0.
function Test-TunedValidDate {
    param([string]$Date)
    if ($Date -notmatch '^[1-9][0-9]{7}\z') { return $false }
    $parsed = [datetime]::MinValue
    return [datetime]::TryParseExact($Date, 'yyyyMMdd', [cultureinfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::None, [ref]$parsed)
}

# gpu_tuned_local_version_dated -- <variant>.cu<cuda>.<YYYYMMDD>.<seq>
function New-TunedLocalVersionDated {
    param([string]$Variant, [string]$Cuda, [string]$Date, [string]$Seq = '0')
    if ($Variant -cnotmatch '^[a-z][a-z0-9]*\z') {
        throw "New-TunedLocalVersionDated: variant '$Variant' must be lowercase alphanumeric (e.g. gb10)."
    }
    if ($Cuda -notmatch '^[0-9]+\z') {
        throw "New-TunedLocalVersionDated: cuda-compact '$Cuda' must be digits only (e.g. 134 for CUDA 13.4)."
    }
    if (-not (Test-TunedValidDate $Date)) {
        throw "New-TunedLocalVersionDated: date '$Date' must be a real calendar date as YYYYMMDD, not starting with 0."
    }
    if ($Seq -notmatch '^(0|[1-9][0-9]*)\z') {
        throw "New-TunedLocalVersionDated: sequence '$Seq' must be a canonical integer (0 = first build of the day, no leading zeros)."
    }
    "$Variant.cu$Cuda.$Date.$Seq"
}

# gpu_tuned_date_label -- the "<YYYYMMDD>[.<seq>]" at the end of a date-form version or native
# tag; $null (never an error) if there is none. Sequence 0 reads as the bare date.
function Get-TunedDateLabel {
    param([string]$Version)
    $label = $null
    if ($Version -cmatch '\.cu[0-9]+\.([1-9][0-9]{7})(\.(0|[1-9][0-9]*))?\z') {
        $label = $Matches[1]
        $seq = $Matches[3]
        if (-not (Test-TunedValidDate $label)) { return $null }
        if ($seq -and $seq -ne '0') { $label = "$label.$seq" }
    } elseif ($Version -cmatch '^v0\.([1-9][0-9]{7})\.(0|[1-9][0-9]*)-[a-z][a-z0-9]*-cu[0-9]+\z') {
        $label = $Matches[1]
        $seq = $Matches[2]
        if (-not (Test-TunedValidDate $label)) { return $null }
        if ($seq -ne '0') { $label = "$label.$seq" }
    }
    $label
}

# gpu_tuned_label_seq -- the sequence integer of a "<YYYYMMDD>[.<seq>]" label (0 for a bare date).
function Get-TunedLabelSeq {
    param([string]$Label)
    if ($Label.Contains('.')) { $Label.Substring($Label.IndexOf('.') + 1) } else { '0' }
}

# gpu_tuned_native_tag -- v0.<YYYYMMDD>.<seq>-<variant>-<cuda-tag>, the sequence always written.
function New-TunedNativeTag {
    param([string]$Variant, [string]$CudaTag, [string]$Label)
    $date = $Label.Split('.')[0]
    $seq = Get-TunedLabelSeq $Label
    $bad = ($Variant -cnotmatch '^[a-z][a-z0-9]*\z') -or ($CudaTag -cnotmatch '^cu[0-9]+\z') `
        -or (-not (Test-TunedValidDate $date)) -or ($seq -notmatch '^(0|[1-9][0-9]*)\z') `
        -or (($Label -ne $date) -and (($seq -eq '0') -or ($Label -ne "$date.$seq")))
    if ($bad) {
        throw "New-TunedNativeTag: need <variant> <cuNNN> <YYYYMMDD[.seq]>, got '$Variant' '$CudaTag' '$Label'."
    }
    "v0.$date.$seq-$Variant-$CudaTag"
}

# gpu_tuned_nvcc_compact -- the CUDA release nvcc reports, without the dot ("134" for 13.4).
# CudaHome defaults to $env:CUDA_HOME, else $env:CUDA_PATH (what the Windows installer sets).
function Get-TunedNvccCompact {
    param([string]$CudaHome = $(if ($env:CUDA_HOME) { $env:CUDA_HOME } else { $env:CUDA_PATH }))
    if (-not $CudaHome) { throw 'Get-TunedNvccCompact: no CUDA home given and CUDA_HOME/CUDA_PATH are not set.' }
    $nvcc = Join-Path $CudaHome 'bin\nvcc.exe'
    if (-not (Test-Path -LiteralPath $nvcc -PathType Leaf)) { throw "Get-TunedNvccCompact: $nvcc is not a file." }
    $out = (& $nvcc --version 2>$null) -join "`n"
    if ($out -notmatch 'release ([0-9]+\.[0-9]+)') {
        throw "Get-TunedNvccCompact: cannot read a 'release X.Y' from $nvcc --version."
    }
    $Matches[1].Replace('.', '')
}

# --- label allocation (date from HEAD, sequence from the tags) --------------------------------

# gpu_tuned_head_date -- UTC committer date of HEAD as YYYYMMDD. Reads the epoch (%ct) and
# converts it here, so neither the commit's own timezone nor TZ in the environment can move it.
function Get-TunedHeadDate {
    param([string]$Dir = '.')
    $ct = (& git -C $Dir log -1 --format=%ct HEAD 2>$null) -join ''
    $d = ''
    if ($LASTEXITCODE -eq 0 -and $ct -match '^[0-9]+\z') {
        $d = [DateTimeOffset]::FromUnixTimeSeconds([long]$ct).UtcDateTime.ToString('yyyyMMdd')
    }
    if (-not (Test-TunedValidDate $d)) {
        throw "Get-TunedHeadDate: cannot read a valid HEAD commit date in $Dir (got '$d')."
    }
    $d
}

# gpu_tuned_taken_date_labels -- every date label already carried by a tag in <remote> or locally.
# Fails if the remote cannot be read: a silent fallback to local tags could reuse a published sequence.
function Get-TunedTakenDateLabels {
    param([string]$Dir = '.', [string]$Remote = 'origin')
    $remoteTags = & git -C $Dir ls-remote --tags $Remote 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Get-TunedTakenDateLabels: cannot read tags from remote '$Remote' in $Dir, so an unused sequence cannot be chosen. Check the network, or choose it yourself with GPU_TUNED_LABEL_SEQ=<n>."
    }
    $localTags = & git -C $Dir tag --list
    $names = @($remoteTags | Where-Object { $_ } | ForEach-Object { ($_ -split '\s+')[1] -replace '^refs/tags/', '' -replace '\^\{\}\z', '' }) + @($localTags)
    @($names | Where-Object { $_ } | Sort-Object -Unique -CaseSensitive |
        ForEach-Object { Get-TunedDateLabel $_ } | Where-Object { $_ } | Sort-Object -Unique -CaseSensitive)
}

# gpu_tuned_next_seq -- the lowest sequence (0, 1, 2, ...) whose label is not in $Taken.
function Get-TunedNextSeq {
    param([string]$Date, [string[]]$Taken = @())
    if (-not (Test-TunedValidDate $Date)) { throw "Get-TunedNextSeq: '$Date' is not a valid YYYYMMDD date." }
    $n = 0
    while ($true) {
        $label = if ($n -eq 0) { $Date } else { "$Date.$n" }
        if ($Taken -cnotcontains $label) { break }
        $n++
    }
    "$n"
}

# gpu_tuned_allocate_date_label -- "<YYYYMMDD>" for the first build of HEAD's UTC date, else
# "<YYYYMMDD>.<n>". GPU_TUNED_LABEL_SEQ=<n> skips the lookup (dev builds, offline).
function New-TunedDateLabel {
    param([string]$Dir = '.', [string]$Remote = 'origin')
    $date = Get-TunedHeadDate $Dir
    if ($env:GPU_TUNED_LABEL_SEQ) {
        if ($env:GPU_TUNED_LABEL_SEQ -notmatch '^(0|[1-9][0-9]*)\z') {
            throw "New-TunedDateLabel: GPU_TUNED_LABEL_SEQ='$($env:GPU_TUNED_LABEL_SEQ)' must be a canonical integer (0 = first build of the day, no leading zeros)."
        }
        $seq = $env:GPU_TUNED_LABEL_SEQ
    } else {
        $seq = Get-TunedNextSeq $date (Get-TunedTakenDateLabels $Dir $Remote)
    }
    if ($seq -eq '0') { $date } else { "$date.$seq" }
}

# --- build info (JSON) ------------------------------------------------------------------------
# The same strict one-line JSON as the bash stamp ("schema":"tuned-build-info/1" first, same
# field names, same escaping as Python's json.dumps(ensure_ascii=True, separators=(",", ":"))), so a
# Windows and a Linux artifact are read by the same tooling.

# gpu_tuned_public_repo_url -- the public https form of a git remote (no userinfo, no .git).
function Get-TunedPublicRepoUrl {
    param([string]$Url)
    $Url = $Url -replace '\.git\z', ''
    $Url = $Url -replace '^ssh://[^@/]*@([^/:]+)(:[0-9]+)?/', 'https://$1/'
    $Url = $Url -replace '^[^@/:]+@([^:/]+):', 'https://$1/'
    $Url -replace '^(https?://)[^/@]*@', '$1'
}

function ConvertTo-TunedJson {
    param($Value)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { return $(if ($Value) { 'true' } else { 'false' }) }
    if ($Value -is [int] -or $Value -is [long]) { return "$Value" }
    if ($Value -is [System.Collections.IDictionary]) {
        $parts = foreach ($k in $Value.Keys) { (ConvertTo-TunedJson ([string]$k)) + ':' + (ConvertTo-TunedJson $Value[$k]) }
        return '{' + ($parts -join ',') + '}'
    }
    $sb = [Text.StringBuilder]::new('"')
    foreach ($c in ([string]$Value).ToCharArray()) {
        $n = [int]$c
        # the escapes Python's json.dumps(ensure_ascii=True) writes: anything outside space..~ becomes a \u escape
        $e = switch ($n) { 0x22 { '\"' } 0x5c { '\\' } 0x0a { '\n' } 0x0d { '\r' } 0x09 { '\t' } 0x08 { '\b' } 0x0c { '\f' } default { $null } }
        if ($e) { [void]$sb.Append($e) }
        elseif ($n -lt 0x20 -or $n -gt 0x7e) { [void]$sb.Append(('\u{0:x4}' -f $n)) }
        else { [void]$sb.Append($c) }
    }
    [void]$sb.Append('"')
    $sb.ToString()
}

# gpu_tuned_build_info_json -- the JSON object for name[:type]=value arguments; a dotted name
# nests, a :int, :bool or :null suffix sets the type. Fails on a bad name, int or bool, a
# duplicate, or a name that is both a value and a parent.
function New-TunedBuildInfoJson {
    param([string[]]$Field = @())
    $obj = [ordered]@{ schema = 'tuned-build-info/1' }
    foreach ($arg in $Field) {
        $eq = $arg.IndexOf('=')
        if ($eq -lt 0) { throw "New-TunedBuildInfoJson: '$arg' is not name=value." }
        $name = $arg.Substring(0, $eq)
        $value = $arg.Substring($eq + 1)
        $type = 'str'
        $colon = $name.LastIndexOf(':')
        if ($colon -ge 0) { $type = $name.Substring($colon + 1); $name = $name.Substring(0, $colon) }
        if ($type -cnotin 'str', 'int', 'bool', 'null' -or $name -cnotmatch '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*\z') {
            throw "New-TunedBuildInfoJson: bad field name or type in '$arg'."
        }
        switch ($type) {
            'int' {
                if ($value -notmatch '^(0|[1-9][0-9]*)\z') { throw "New-TunedBuildInfoJson: $name is not a canonical integer: '$value'." }
                $value = [long]$value
            }
            'bool' {
                if ($value -cne 'true' -and $value -cne 'false') { throw "New-TunedBuildInfoJson: $name must be true or false, got '$value'." }
                $value = ($value -ceq 'true')
            }
            'null' { $value = $null }
        }
        if ($null -ne $value -and "$value" -match '[\x00-\x1f]') {
            throw "New-TunedBuildInfoJson: $name contains a control character."
        }
        $parts = $name.Split('.')
        $node = $obj
        for ($i = 0; $i -lt $parts.Count - 1; $i++) {
            if (-not $node.Contains($parts[$i])) { $node[$parts[$i]] = [ordered]@{} }
            if ($node[$parts[$i]] -isnot [System.Collections.IDictionary]) {
                throw "New-TunedBuildInfoJson: $(($parts[0..$i]) -join '.') is both a value and a parent."
            }
            $node = $node[$parts[$i]]
        }
        if ($node.Contains($parts[-1])) { throw "New-TunedBuildInfoJson: duplicate or conflicting field $name." }
        $node[$parts[-1]] = $value
    }
    ConvertTo-TunedJson $obj
}

# gpu_tuned__git_info_fields -- name=value lines describing the checkout in the current directory:
# fork.url, fork.commit, fork.dirty, fork.commit_count, and the upstream.* fields when an
# `upstream` remote exists. Never fetches, never fails: a non-git directory yields nothing.
function Get-TunedGitInfoFields {
    param([string]$ForkUrl = '')
    $sha = (& git rev-parse HEAD 2>$null) -join ''
    if ($LASTEXITCODE -ne 0 -or -not $sha) { return @() }
    if (-not $ForkUrl) { $ForkUrl = (& git remote get-url origin 2>$null) -join '' }
    $url = Get-TunedPublicRepoUrl $ForkUrl
    $count = (& git rev-list --count HEAD 2>$null) -join ''
    $dirty = [bool]((& git status --porcelain --untracked-files=no 2>$null) -join '')
    $f = @("fork.url=$(if ($url) { $url } else { 'unknown' })", "fork.commit=$sha", "fork.dirty:bool=$($dirty.ToString().ToLower())")
    if ($count) { $f += "fork.commit_count:int=$count" }
    $upUrl = (& git remote get-url upstream 2>$null) -join ''
    if ($LASTEXITCODE -ne 0 -or -not $upUrl) { return $f }
    $f += "upstream.url=$(Get-TunedPublicRepoUrl $upUrl)"
    $upRef = $env:GPU_TUNED_UPSTREAM_REF
    if (-not $upRef) { $upRef = (& git symbolic-ref -q --short refs/remotes/upstream/HEAD 2>$null) -join '' }
    if (-not $upRef) { return $f + 'upstream.ref:null=' }
    $f += "upstream.ref=$upRef"
    $base = (& git merge-base HEAD $upRef 2>$null) -join ''
    if ($LASTEXITCODE -ne 0 -or -not $base) { return $f }
    $f += "upstream.base=$base"
    $nearest = (& git describe --tags --abbrev=0 --exclude 'tuning-*' $base 2>$null) -join ''
    if ($nearest) {
        $dist = (& git rev-list --count "refs/tags/$nearest..$base" 2>$null) -join ''
        $f += "upstream.nearest_tag=$nearest+$(if ($dist) { $dist } else { '0' })"
    }
    $f
}

# gpu_tuned__build_info_full -- the JSON for the given fields plus the checkout's git fields and a
# UTC "built" time; fields given by the caller win over the automatic ones. Run inside the repo.
function New-TunedBuildInfoFull {
    param([string[]]$Field = @())
    $given = @($Field | ForEach-Object { ($_ -split '[:=]')[0] })
    $auto = @(Get-TunedGitInfoFields | Where-Object { $_ -and (($_ -split '[:=]')[0] -notin $given) })
    New-TunedBuildInfoJson ($Field + $auto + "built=$([datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))")
}

# gpu_tuned_write_build_info_json -- the JSON on one line in <OutFile> (ship it as BUILD_INFO.json,
# docs/ARCHITECTURE.md H7). UTF-8 without a BOM and LF, as bash writes it.
function Write-TunedBuildInfoJson {
    param([string]$OutFile, [string[]]$Field = @())
    if (-not $OutFile) { throw 'Write-TunedBuildInfoJson: need an output file.' }
    $json = New-TunedBuildInfoFull $Field
    [IO.File]::WriteAllText($OutFile, "$json`n", [Text.UTF8Encoding]::new($false))
}

# gpu_tuned__verify_json_fields -- every given name[:type]=expected must equal the stamp's value.
function Test-TunedJsonFields {
    param([string]$Json, [string[]]$Field = @())
    try { $obj = $Json | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
    catch { throw "Test-TunedJsonFields: the stamp is not valid JSON ($($_.Exception.Message))." }
    $bad = @()
    foreach ($arg in $Field) {
        $eq = $arg.IndexOf('=')
        $name = $arg.Substring(0, $eq)
        $want = $arg.Substring($eq + 1)
        $type = 'str'
        $colon = $name.LastIndexOf(':')
        if ($colon -ge 0) { $type = $name.Substring($colon + 1); $name = $name.Substring(0, $colon) }
        if ($type -eq 'int') { $want = [long]$want } elseif ($type -eq 'bool') { $want = ($want -ceq 'true') }
        $node = $obj
        foreach ($part in $name.Split('.')) {
            $node = if ($node -is [System.Collections.IDictionary] -and $node.Contains($part)) { $node[$part] } else { $null }
        }
        if ($node -cne $want) { $bad += "field $name is '$node', expected '$want'." }
    }
    if ($bad) { throw "Test-TunedJsonFields: $($bad -join ' ')" }
}

# gpu_tuned_verify_build_info_json_file -- the field check for a BUILD_INFO.json.
function Test-TunedBuildInfoJsonFile {
    param([string]$File, [string[]]$Field = @())
    if (-not (Test-Path -LiteralPath $File -PathType Leaf) -or (Get-Item -LiteralPath $File).Length -eq 0) {
        throw "Test-TunedBuildInfoJsonFile: $File is missing or empty."
    }
    Test-TunedJsonFields ([IO.File]::ReadAllText($File).Trim()) $Field
}

# --- PE version-resource stamp ----------------------------------------------------------------
# The JSON goes into the .exe/.dll's VS_VERSIONINFO as the "Comments" string, with the release
# label in FileVersion/ProductVersion, so Explorer's Details tab, `(Get-Item x).VersionInfo` and
# Get-TunedBuildInfo all read it. The numeric FILEVERSION stays 0.0.0.0: its fields are 16 bits and
# a v0.<YYYYMMDD>.<seq> label does not fit. Stamp staged copies, never the build tree (H3).

function Initialize-TunedResourceApi {
    if ('TunedNative.Res' -as [type]) { return }
    Add-Type -Namespace TunedNative -Name Res -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true, CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern System.IntPtr BeginUpdateResource(string file, bool deleteExisting);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern bool UpdateResource(System.IntPtr h, System.IntPtr type, System.IntPtr name, ushort lang, System.IntPtr data, uint cb);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern bool EndUpdateResource(System.IntPtr h, bool discard);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true, CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern System.IntPtr LoadLibraryEx(string file, System.IntPtr zero, uint flags);
public delegate bool EnumLangProc(System.IntPtr mod, System.IntPtr type, System.IntPtr name, ushort lang, System.IntPtr lp);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern bool EnumResourceLanguages(System.IntPtr mod, System.IntPtr type, System.IntPtr name, EnumLangProc cb, System.IntPtr lp);
// the languages the RT_VERSION resource named 1 already exists in (none if it is absent)
public static ushort[] VersionLangs(System.IntPtr mod) {
    var l = new System.Collections.Generic.List<ushort>();
    EnumResourceLanguages(mod, (System.IntPtr)16, (System.IntPtr)1, (m, t, n, lang, lp) => { l.Add(lang); return true; }, System.IntPtr.Zero);
    return l.ToArray();
}
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern bool FreeLibrary(System.IntPtr module);
'@
}

# One VS_VERSIONINFO node: header (length, value length, type), key, padded value, children.
function New-TunedVersionNode {
    param([string]$Key, [byte[]]$Value = @(), [int]$ValueLen = 0, [int]$Type = 1, [byte[]]$Children = @())
    $ms = [IO.MemoryStream]::new()
    $w = [IO.BinaryWriter]::new($ms, [Text.Encoding]::Unicode)
    $w.Write([uint16]0); $w.Write([uint16]$ValueLen); $w.Write([uint16]$Type)
    $w.Write([Text.Encoding]::Unicode.GetBytes($Key + [char]0))
    while ($ms.Length % 4) { $w.Write([byte]0) }
    if ($Value.Count) { $w.Write($Value); while ($ms.Length % 4) { $w.Write([byte]0) } }
    $len = $ms.Length
    if ($Children.Count) { $w.Write($Children); $len = $ms.Length }
    $bytes = $ms.ToArray()
    if ($len -gt 65535) { throw "New-TunedVersionNode: '$Key' is $len bytes; a version resource node is limited to 65535." }
    [BitConverter]::GetBytes([uint16]$len).CopyTo($bytes, 0)
    # a following sibling starts on a 4-byte boundary; the padding is not part of this node's length
    $pad = (4 - $bytes.Length % 4) % 4
    ,($bytes + [byte[]]::new($pad))
}

function New-TunedVersionInfoBlob {
    param([System.Collections.IDictionary]$Strings)
    $entries = foreach ($k in $Strings.Keys) {
        $text = [Text.Encoding]::Unicode.GetBytes([string]$Strings[$k] + [char]0)
        New-TunedVersionNode -Key $k -Value $text -ValueLen ($text.Length / 2)
    }
    $table = New-TunedVersionNode -Key '040904b0' -Children ([byte[]]($entries | ForEach-Object { $_ }))
    $sfi = New-TunedVersionNode -Key 'StringFileInfo' -Children $table
    $var = New-TunedVersionNode -Key 'Translation' -Type 0 -ValueLen 4 -Value ([byte[]](0x09, 0x04, 0xb0, 0x04))
    $vfi = New-TunedVersionNode -Key 'VarFileInfo' -Children $var
    # VS_FIXEDFILEINFO: signature, struct version, then zeros (numeric versions stay 0.0.0.0)
    $fixed = [byte[]]::new(52)
    [BitConverter]::GetBytes(0xFEEF04BDu).CopyTo($fixed, 0)
    [BitConverter]::GetBytes([uint32]0x00010000).CopyTo($fixed, 4)
    [BitConverter]::GetBytes([uint32]0x0000003F).CopyTo($fixed, 20)   # dwFileFlagsMask
    [BitConverter]::GetBytes([uint32]0x00000004).CopyTo($fixed, 28)   # VOS_NT
    [BitConverter]::GetBytes([uint32]0x00000001).CopyTo($fixed, 32)   # VFT_APP
    $root = New-TunedVersionNode -Key 'VS_VERSION_INFO' -Type 0 -ValueLen 52 -Value $fixed -Children ([byte[]]($sfi + $vfi))
    ,[byte[]]$root
}

# Stamp <File> (a staged copy of an .exe or .dll) with the build-info JSON for the given fields plus
# the checkout's git fields. "release" is required: it is the identity (E5) and becomes FileVersion
# and ProductVersion. Replaces any earlier version resource, so it is idempotent.
function Set-TunedExeBuildInfo {
    param([string]$File, [string[]]$Field = @())
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { throw "Set-TunedExeBuildInfo: $File is not a file." }
    if (-not ($Field | Where-Object { $_ -like 'release=*' })) { throw 'Set-TunedExeBuildInfo: a release=<native tag or label> field is required.' }
    $json = New-TunedBuildInfoFull $Field
    $info = $json | ConvertFrom-Json -AsHashtable
    $strings = [ordered]@{
        ProductName     = [string]$(if ($info.Contains('package')) { $info.package } else { 'tuned build' })
        InternalName    = [IO.Path]::GetFileNameWithoutExtension($File)
        OriginalFilename = [IO.Path]::GetFileName($File)
        FileVersion     = [string]$info.release
        ProductVersion  = [string]$info.release
        Comments        = $json
    }
    $blob = New-TunedVersionInfoBlob $strings
    Initialize-TunedResourceApi
    $path = (Resolve-Path -LiteralPath $File).Path
    # Deleting a resource that is not there poisons the update handle (error 1359), so ask first.
    $existing = @()
    $mod = [TunedNative.Res]::LoadLibraryEx($path, [IntPtr]::Zero, 2)   # LOAD_LIBRARY_AS_DATAFILE
    if ($mod -ne [IntPtr]::Zero) {
        $existing = @([TunedNative.Res]::VersionLangs($mod))
        [void][TunedNative.Res]::FreeLibrary($mod)
    }
    $h = [TunedNative.Res]::BeginUpdateResource($path, $false)
    if ($h -eq [IntPtr]::Zero) { throw "Set-TunedExeBuildInfo: cannot open $File for update (error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))." }
    $ok = $false
    try {
        $type = [IntPtr]16; $name = [IntPtr]1
        # drop the existing version resource in every language it has, then add ours (US English)
        foreach ($lang in $existing) {
            if (-not [TunedNative.Res]::UpdateResource($h, $type, $name, [uint16]$lang, [IntPtr]::Zero, 0)) { throw "Set-TunedExeBuildInfo: cannot remove the existing version resource (error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))." }
        }
        $mem = [Runtime.InteropServices.Marshal]::AllocHGlobal($blob.Length)
        try {
            [Runtime.InteropServices.Marshal]::Copy($blob, 0, $mem, $blob.Length)
            $ok = [TunedNative.Res]::UpdateResource($h, $type, $name, 0x0409, $mem, [uint32]$blob.Length)
        } finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($mem) }
        if (-not $ok) { throw "Set-TunedExeBuildInfo: UpdateResource failed (error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))." }
    } finally {
        [void][TunedNative.Res]::EndUpdateResource($h, -not $ok)
    }
}

# gpu_tuned_read_build_info -- the build info of an .exe/.dll as one line of JSON, from the Comments
# string of its version resource. Throws if the file carries none or it is not tuned build info.
function Get-TunedBuildInfo {
    param([string]$File)
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { throw "Get-TunedBuildInfo: $File is not a file." }
    $c = [Diagnostics.FileVersionInfo]::GetVersionInfo((Resolve-Path -LiteralPath $File).Path).Comments
    if (-not $c -or $c -notmatch '^\{"schema":"tuned-build-info/') {
        throw "Get-TunedBuildInfo: $File has no tuned build-info version resource."
    }
    $null = $c | ConvertFrom-Json -AsHashtable
    $c
}

# gpu_tuned_verify_build_info_json -- the field check for a stamped .exe/.dll.
function Test-TunedBuildInfo {
    param([string]$File, [string[]]$Field = @())
    Test-TunedJsonFields (Get-TunedBuildInfo $File) $Field
}
