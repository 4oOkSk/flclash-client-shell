param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Archive,
    [Parameter(Mandatory = $true, Position = 1)]
    [string]$SevenZipExtractor,
    [Parameter(Mandatory = $true, Position = 2)]
    [string]$SevenZipLicense,
    [Parameter(Mandatory = $true, Position = 3)]
    [string]$SourceRoot,
    [Parameter(Mandatory = $true, Position = 4)]
    [string]$Output
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$ExpectedExtractorBytes = [int64]602112
$ExpectedExtractorSha256 = '56b8cc9f4971cef253644fafe54063ed7fdca551d4dee0f8c6baa81b855acd72'
$ExpectedLicenseBytes = [int64]6190
$ExpectedLicenseSha256 = 'dac8389b6bc39339537bc351772106afe7951cb242cdf03e855b67c3a683deb1'
$Program = Join-Path $SourceRoot 'tool\windows_sfx\Program.cs'
$Manifest = Join-Path $SourceRoot 'tool\windows_sfx\app.manifest'

foreach ($Path in @(
    $Archive,
    $SevenZipExtractor,
    $SevenZipLicense,
    $Program,
    $Manifest
)) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or
        (Get-Item -LiteralPath $Path).Length -le 0) {
        throw "Required SFX input is missing: $Path"
    }
}
if ([IO.Path]::GetExtension($Archive) -ne '.zip') {
    throw 'SFX build input must be the verified Windows ZIP.'
}
if ([IO.Path]::GetExtension($Output) -ne '.exe') {
    throw 'SFX output must be an EXE.'
}

$ExtractorItem = Get-Item -LiteralPath $SevenZipExtractor
$ExtractorHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $SevenZipExtractor).Hash.ToLowerInvariant()
if ($ExtractorItem.Length -ne $ExpectedExtractorBytes -or
    $ExtractorHash -ne $ExpectedExtractorSha256) {
    throw 'Pinned official 7zr.exe verification failed.'
}
$LicenseItem = Get-Item -LiteralPath $SevenZipLicense
$LicenseHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $SevenZipLicense).Hash.ToLowerInvariant()
if ($LicenseItem.Length -ne $ExpectedLicenseBytes -or
    $LicenseHash -ne $ExpectedLicenseSha256) {
    throw 'Pinned official 7-Zip license verification failed.'
}

$CscCandidates = @(
    "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
    "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
)
$Csc = $CscCandidates | Where-Object { Test-Path -LiteralPath $_ } |
    Select-Object -First 1
if ($null -eq $Csc) { throw '.NET Framework C# compiler is missing.' }

$OutputDirectory = Split-Path -Parent $Output
if ([String]::IsNullOrEmpty($OutputDirectory)) {
    throw 'SFX output must have an explicit parent directory.'
}
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$Stage = Join-Path $OutputDirectory ('.harborproxy-sfx-' + [Guid]::NewGuid().ToString('N'))
$PayloadRoot = Join-Path $Stage 'payload'
$Payload7z = Join-Path $Stage 'HarborProxy.Payload.7z'

try {
    New-Item -ItemType Directory -Path $PayloadRoot | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $Zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        $Apps = @($Zip.Entries | Where-Object {
            (($_.FullName -replace '\\', '/') -eq 'HarborProxy.exe')
        })
        if ($Apps.Count -ne 1) {
            throw "Expected one root HarborProxy.exe in payload; found $($Apps.Count)."
        }
        foreach ($Entry in $Zip.Entries) {
            $Name = $Entry.FullName.Replace('\', '/')
            if ([String]::IsNullOrWhiteSpace($Name) -or
                $Name.StartsWith('/') -or
                $Name -match '^[A-Za-z]:' -or
                $Name.IndexOf([char]0) -ge 0) {
                throw 'Unsafe or empty ZIP entry name.'
            }
            $Segments = @($Name.Split('/') | Where-Object { $_ -ne '' })
            if (@($Segments | Where-Object { $_ -eq '.' -or $_ -eq '..' }).Count -ne 0) {
                throw 'Unsafe relative ZIP entry name.'
            }
        }
    } finally {
        $Zip.Dispose()
    }
    [IO.Compression.ZipFile]::ExtractToDirectory($Archive, $PayloadRoot)

    $InstalledLicense = Join-Path $PayloadRoot '7-Zip-LICENSE.txt'
    if (Test-Path -LiteralPath $InstalledLicense) {
        throw 'Payload already contains the reserved 7-Zip license path.'
    }
    Copy-Item -LiteralPath $SevenZipLicense -Destination $InstalledLicense

    Push-Location $PayloadRoot
    try {
        $Previous = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            & $SevenZipExtractor a '-t7z' '-mx=9' '-m0=lzma2' '-ms=on' '-mmt=on' `
                '-bb0' '-bd' $Payload7z '.\*' | Out-Null
            $ArchiveCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $Previous
        }
    } finally {
        Pop-Location
    }
    if ($ArchiveCode -ne 0 -or
        -not (Test-Path -LiteralPath $Payload7z -PathType Leaf) -or
        (Get-Item -LiteralPath $Payload7z).Length -le 0) {
        throw '7z payload creation failed.'
    }

    $Previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $SevenZipExtractor t '-bb0' '-bd' $Payload7z | Out-Null
        $TestCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $Previous
    }
    if ($TestCode -ne 0) { throw '7z payload integrity test failed.' }

    Remove-Item -LiteralPath $Output -Force -ErrorAction SilentlyContinue
    $Arguments = @(
        '/nologo',
        '/target:winexe',
        '/platform:x64',
        '/optimize+',
        "/out:$Output",
        "/win32manifest:$Manifest",
        "/resource:$Payload7z,HarborProxy.Payload.7z",
        "/resource:$SevenZipExtractor,HarborProxy.7zr.exe",
        '/reference:System.dll',
        '/reference:System.Core.dll',
        '/reference:System.Drawing.dll',
        '/reference:System.Windows.Forms.dll',
        $Program
    )

    $Previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $Csc @Arguments
        $Code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $Previous
    }
    if ($Code -ne 0) { throw "SFX compilation failed with exit code $Code." }
    if (-not (Test-Path -LiteralPath $Output -PathType Leaf) -or
        (Get-Item -LiteralPath $Output).Length -le 0) {
        throw 'SFX compiler produced no output.'
    }

    $Stream = [IO.File]::OpenRead($Output)
    $Reader = New-Object IO.BinaryReader($Stream)
    try {
        if ([Text.Encoding]::ASCII.GetString($Reader.ReadBytes(2)) -ne 'MZ') {
            throw 'SFX output has no DOS executable header.'
        }
        $Stream.Position = 0x3c
        $PeOffset = $Reader.ReadInt32()
        $Stream.Position = $PeOffset
        if ($Reader.ReadUInt32() -ne 0x00004550) {
            throw 'SFX output has no PE signature.'
        }
        if ($Reader.ReadUInt16() -ne 0x8664) {
            throw 'SFX output is not an amd64 Windows executable.'
        }
    } finally {
        $Reader.Dispose()
        $Stream.Dispose()
    }
    if ((Get-Item -LiteralPath $Output).Length -ge (Get-Item -LiteralPath $Archive).Length) {
        throw '7z SFX is not smaller than its ZIP build input.'
    }
    Write-Output ("windows_sfx=ok format=7z-lzma2 bytes={0}" -f `
        (Get-Item -LiteralPath $Output).Length)
} catch {
    Remove-Item -LiteralPath $Output -Force -ErrorAction SilentlyContinue
    throw
} finally {
    Remove-Item -LiteralPath $Stage -Recurse -Force -ErrorAction SilentlyContinue
}
