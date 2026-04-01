param(
    [ValidateSet("cpu", "gpu")]
    [string]$Mode = "gpu",

    [ValidateSet("cu118", "cu126", "cu129", "cu130")]
    [string]$Cuda = "cu129",

    [string]$VenvDir = ".venv",

    [int]$PipInstallTimeoutSeconds = 600
)

$installer = Join-Path $PSScriptRoot "install_paddle_doc_parser_component.ps1"
& $installer `
    -Target "paddleocr-vl" `
    -Mode $Mode `
    -Cuda $Cuda `
    -VenvDir $VenvDir `
    -PipInstallTimeoutSeconds $PipInstallTimeoutSeconds
