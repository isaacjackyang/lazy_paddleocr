$ErrorActionPreference = "Stop"

function Get-ScriptDirectory {
    if ($PSScriptRoot -and (Test-Path -LiteralPath $PSScriptRoot)) {
        return $PSScriptRoot
    }

    if ($MyInvocation.MyCommand.Path) {
        return (Split-Path -Parent $MyInvocation.MyCommand.Path)
    }

    return (Get-Location).Path
}

function Get-StrictEncoding {
    param(
        [int]$CodePage
    )

    return [System.Text.Encoding]::GetEncoding(
        $CodePage,
        [System.Text.EncoderExceptionFallback]::new(),
        [System.Text.DecoderExceptionFallback]::new()
    )
}

function Get-FileEncoding {
    param(
        [string]$Path
    )

    $bytes = [System.IO.File]::ReadAllBytes($Path)

    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return [System.Text.Encoding]::UTF8
    }

    if ($bytes.Length -ge 4 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE -and $bytes[2] -eq 0x00 -and $bytes[3] -eq 0x00) {
        return [System.Text.Encoding]::UTF32
    }

    if ($bytes.Length -ge 4 -and $bytes[0] -eq 0x00 -and $bytes[1] -eq 0x00 -and $bytes[2] -eq 0xFE -and $bytes[3] -eq 0xFF) {
        return [System.Text.Encoding]::GetEncoding("utf-32BE")
    }

    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        return [System.Text.Encoding]::Unicode
    }

    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        return [System.Text.Encoding]::BigEndianUnicode
    }

    try {
        [void]([System.Text.UTF8Encoding]::new($false, $true).GetString($bytes))
        return [System.Text.UTF8Encoding]::new($false)
    }
    catch {
    }

    try {
        $big5 = Get-StrictEncoding -CodePage 950
        [void]($big5.GetString($bytes))
        return [System.Text.Encoding]::GetEncoding(950)
    }
    catch {
    }

    return [System.Text.Encoding]::Default
}

function Read-TextFileSafely {
    param(
        [string]$Path
    )

    $encoding = Get-FileEncoding -Path $Path
    return [System.IO.File]::ReadAllText($Path, $encoding)
}

function Get-FileSortInfo {
    param(
        [System.IO.FileInfo]$File
    )

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($File.Name)
    $trimmedName = $baseName.Trim()
    $startMatch = [System.Text.RegularExpressions.Regex]::Match($trimmedName, '^\s*(\d+)')
    $endMatch = [System.Text.RegularExpressions.Regex]::Match($trimmedName, '(\d+)\s*$')

    $hasSerial = $false
    $serialValue = [Int64]::MaxValue

    if ($startMatch.Success) {
        $hasSerial = $true
        $serialValue = [Int64]::Parse($startMatch.Groups[1].Value)
    }
    elseif ($endMatch.Success) {
        $hasSerial = $true
        $serialValue = [Int64]::Parse($endMatch.Groups[1].Value)
    }

    $firstCharKey = ""
    if ($trimmedName.Length -gt 0) {
        $firstCharKey = $trimmedName.Substring(0, 1).ToUpperInvariant()
    }

    return [PSCustomObject]@{
        File         = $File
        HasSerial    = $hasSerial
        SerialValue  = $serialValue
        FirstCharKey = $firstCharKey
        NameKey      = $trimmedName.ToUpperInvariant()
    }
}

function Merge-TextFiles {
    param(
        [string]$DirectoryPath,
        [string]$OutputFileName
    )

    $outputPath = Join-Path $DirectoryPath $OutputFileName
    $files = Get-ChildItem -LiteralPath $DirectoryPath -File -Filter *.txt |
        Where-Object { $_.FullName -ne $outputPath }

    if (-not $files) {
        throw "No .txt files were found in: $DirectoryPath"
    }

    $orderedFiles = $files |
        ForEach-Object { Get-FileSortInfo -File $_ } |
        Sort-Object `
            @{ Expression = { if ($_.HasSerial) { 0 } else { 1 } } }, `
            @{ Expression = { $_.SerialValue } }, `
            @{ Expression = { $_.FirstCharKey } }, `
            @{ Expression = { $_.NameKey } }, `
            @{ Expression = { $_.File.Name.ToUpperInvariant() } }

    $utf8Bom = [System.Text.UTF8Encoding]::new($true)
    $writer = [System.IO.StreamWriter]::new($outputPath, $false, $utf8Bom)

    try {
        for ($index = 0; $index -lt $orderedFiles.Count; $index++) {
            $item = $orderedFiles[$index]
            $content = Read-TextFileSafely -Path $item.File.FullName

            $writer.Write($content)

            if ($index -lt ($orderedFiles.Count - 1)) {
                if ($content.Length -eq 0) {
                    $writer.WriteLine()
                }
                elseif (-not ($content.EndsWith("`r") -or $content.EndsWith("`n"))) {
                    $writer.WriteLine()
                }
            }
        }
    }
    finally {
        $writer.Dispose()
    }

    return $orderedFiles
}

try {
    $scriptDirectory = Get-ScriptDirectory
    $outputFileName = "merged_txt_output.txt"
    $orderedFiles = Merge-TextFiles -DirectoryPath $scriptDirectory -OutputFileName $outputFileName
    $outputPath = Join-Path $scriptDirectory $outputFileName

    Write-Host ""
    Write-Host "Merged TXT created successfully." -ForegroundColor Green
    Write-Host "Output : $outputPath"
    Write-Host "Order  :"

    foreach ($item in $orderedFiles) {
        if ($item.HasSerial) {
            Write-Host ("  [Serial {0}] {1}" -f $item.SerialValue, $item.File.Name)
        }
        else {
            Write-Host ("  [Alpha ] {0}" -f $item.File.Name)
        }
    }
}
catch {
    Write-Host ""
    Write-Host "MERGE FAILED" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
