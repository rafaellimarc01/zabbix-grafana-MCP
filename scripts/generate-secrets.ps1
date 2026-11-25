# Versão para Windows (PowerShell) do generate-secrets.sh: gera o arquivo de
# segredos a partir do exemplo, preenchendo toda variável *_PASSWORD vazia com
# uma senha aleatória de 24 caracteres. Funciona no Windows PowerShell 5.1 e no
# PowerShell 7 (Windows, macOS e Linux).
#   powershell -ExecutionPolicy Bypass -File scripts\generate-secrets.ps1          -> .env (Docker Compose)
#   powershell -ExecutionPolicy Bypass -File scripts\generate-secrets.ps1 -Target k8s -> kubernetes\base\secrets.env
# Nunca sobrescreve um arquivo existente.
# Este arquivo é salvo em UTF-8 com BOM de propósito: sem o BOM, o Windows
# PowerShell 5.1 lê o script como ANSI e estraga os acentos das mensagens.
param(
    [ValidateSet('compose', 'k8s')]
    [string]$Target = 'compose'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$root = Split-Path -Parent $PSScriptRoot

if ($Target -eq 'k8s') {
    $src = Join-Path $root 'kubernetes/base/secrets.env.example'
    $dest = Join-Path $root 'kubernetes/base/secrets.env'
    $destName = 'kubernetes/base/secrets.env'
} else {
    $src = Join-Path $root '.env.example'
    $dest = Join-Path $root '.env'
    $destName = '.env'
}

if (Test-Path -LiteralPath $dest) {
    Write-Output "$destName já existe; nada foi alterado."
    exit 0
}

# Senha aleatória só com letras e números (sem problemas de escape no .env),
# gerada pelo gerador criptográfico do sistema. Descarta bytes acima de 247
# para todos os 62 caracteres terem a mesma chance. Evita "admin" e "zabbix",
# que o Zabbix proíbe na senha do Admin.
$chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
function New-RandomPassword {
    while ($true) {
        $sb = New-Object System.Text.StringBuilder
        $buf = New-Object byte[] 64
        while ($sb.Length -lt 24) {
            $rng.GetBytes($buf)
            foreach ($b in $buf) {
                if ($b -lt 248 -and $sb.Length -lt 24) {
                    [void]$sb.Append($chars[$b % 62])
                }
            }
        }
        $p = $sb.ToString()
        if ($p -notmatch '(?i)admin|zabbix') { return $p }
    }
}

# Lê o exemplo como UTF-8 e grava em UTF-8 sem BOM e com fim de linha LF,
# o formato que o Docker Compose e os scripts dos containers Linux esperam
# (o Windows PowerShell 5.1 gravaria com BOM e CRLF por padrão).
$utf8 = New-Object System.Text.UTF8Encoding($false)
$lines = [System.IO.File]::ReadAllText($src, $utf8) -split "`r?`n"
if ($lines.Count -gt 0 -and $lines[-1] -eq '') { $lines = $lines[0..($lines.Count - 2)] }
$out = foreach ($line in $lines) {
    if ($line -cmatch '^[A-Z][A-Z0-9_]*_PASSWORD=$') { $line + (New-RandomPassword) } else { $line }
}
$tmp = "$dest.tmp"
[System.IO.File]::WriteAllText($tmp, (($out -join "`n") + "`n"), $utf8)
Move-Item -LiteralPath $tmp -Destination $dest

# No Windows, deixa o arquivo acessível só para o usuário atual (equivalente
# ao chmod 600 do generate-secrets.sh). Em macOS/Linux, usa chmod.
if ($env:OS -eq 'Windows_NT') {
    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    & icacls.exe $dest /inheritance:r /grant:r "${me}:(R,W)" | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Warning "não foi possível restringir as permissões de $destName" }
} else {
    & chmod 600 $dest
}
Write-Output "$destName criado com senhas aleatórias (só o seu usuário lê). Guarde as senhas em um cofre."
