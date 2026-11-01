#Requires -Version 7.1
<#
.SYNOPSIS
  Creates cyberlab-mirror's two hand-made Secrets in the cluster.

.DESCRIPTION
  -AuthKey     cyberlab-mirror-auth-key: AUTH_ENCRYPTION_KEY, 32 random bytes (base64)
               that encrypt users' 2FA secrets. Generated here, never shown, and backed
               up age-encrypted next to the cyberlab-backup archives. Losing it means
               every user with 2FA has to set it up again.
  -ApiSecrets  cyberlab-mirror-api: GITHUB_TOKEN, RESEND_API_KEY, MAIL_FROM, and
               ALLOWED_EMAILS. Secret values are typed with hidden input.

  Values never appear on a command line or in shell history: they go through temporary
  files that are deleted afterwards. An existing Secret is never replaced unless
  -Replace is given (rotating the GitHub or Resend token, for example).

.EXAMPLE
  cyberlab                                   # sets KUBECONFIG
  ./scripts/cyberlab-mirror-secrets.ps1 -AuthKey
  ./scripts/cyberlab-mirror-secrets.ps1 -ApiSecrets
  ./scripts/cyberlab-mirror-secrets.ps1 -ApiSecrets -Replace
#>
[CmdletBinding()]
param(
    [switch]$AuthKey,
    [switch]$ApiSecrets,
    [switch]$Replace
)
$ErrorActionPreference = 'Stop'
$namespace = 'cyberlab-mirror'
# The same age recipient and folder as cyberlab-backup
$recipient = 'age1dsfy9yvdp64tcdhwkgm87vjwyu3g3xuua5mrl55y8ywj3v8wjucqyqlydg'
$backupDir = "$env:OneDrive\Backups\cyberlab"

if (-not ($AuthKey -or $ApiSecrets)) { throw 'Pass -AuthKey, -ApiSecrets, or both.' }
if (-not $env:KUBECONFIG) { throw 'KUBECONFIG is not set; run "cyberlab" first.' }

function Test-Secret([string]$name) {
    [bool](kubectl -n $namespace get secret $name --ignore-not-found -o name)
}

# New-SecretFromFiles creates (or with -Replace, replaces) a Secret whose keys are the
# files in $dir, named after them.
function New-SecretFromFiles([string]$name, [string]$dir) {
    $kargs = @('-n', $namespace, 'create', 'secret', 'generic', $name)
    foreach ($f in Get-ChildItem $dir -File) { $kargs += "--from-file=$($f.FullName)" }
    if ($Replace) {
        # Render and apply, so the Secret is updated in place, never missing
        kubectl @kargs --dry-run=client -o yaml | kubectl apply -f - | Out-Null
    } else {
        kubectl @kargs | Out-Null
    }
    if ($LASTEXITCODE -ne 0) { throw "creating Secret $name failed" }
}

function New-TempDir {
    $d = Join-Path $env:TEMP ("cm-secrets-" + [Guid]::NewGuid())
    New-Item -ItemType Directory $d | Out-Null
    $d
}

function Read-Plain([string]$prompt) {
    $s = Read-Host -MaskInput $prompt
    if ([string]::IsNullOrWhiteSpace($s)) { throw "$prompt is required" }
    $s.Trim()
}

if ($AuthKey) {
    if (Test-Secret 'cyberlab-mirror-auth-key') {
        if ($Replace) {
            throw 'Refusing to replace cyberlab-mirror-auth-key: that would lock every 2FA user out. Delete it by hand if you really mean to.'
        }
        Write-Host 'cyberlab-mirror-auth-key already exists; leaving it alone.' -ForegroundColor Yellow
    } else {
        if (-not (Get-Command age -ErrorAction SilentlyContinue)) { throw 'age not found on PATH' }
        $tmp = New-TempDir
        try {
            $bytes = [byte[]]::new(32)
            [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
            [IO.File]::WriteAllText("$tmp\AUTH_ENCRYPTION_KEY", [Convert]::ToBase64String($bytes))
            [Array]::Clear($bytes, 0, $bytes.Length)

            New-Item -ItemType Directory -Force $backupDir | Out-Null
            $backup = Join-Path $backupDir ("cyberlab-mirror-auth-key-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".age")
            & age -r $recipient -o $backup "$tmp\AUTH_ENCRYPTION_KEY"
            if ($LASTEXITCODE -ne 0) { throw 'age encryption failed' }

            New-SecretFromFiles 'cyberlab-mirror-auth-key' $tmp
            Write-Host "Created cyberlab-mirror-auth-key; encrypted backup: $backup" -ForegroundColor Green
        } finally {
            Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

if ($ApiSecrets) {
    if ((Test-Secret 'cyberlab-mirror-api') -and -not $Replace) {
        Write-Host 'cyberlab-mirror-api already exists; pass -Replace to update it.' -ForegroundColor Yellow
    } else {
        $tmp = New-TempDir
        try {
            # Hidden input for the two tokens; the other two aren't secret but stay out
            # of the public repo
            foreach ($k in 'GITHUB_TOKEN', 'RESEND_API_KEY') {
                [IO.File]::WriteAllText("$tmp\$k", (Read-Plain $k))
            }
            $from = (Read-Host 'MAIL_FROM (e.g. Cyberlab Mirror <mirror@mail.example.com>)').Trim()
            $allowed = (Read-Host 'ALLOWED_EMAILS (comma-separated)').Trim()
            if (-not $from -or -not $allowed) { throw 'MAIL_FROM and ALLOWED_EMAILS are required' }
            [IO.File]::WriteAllText("$tmp\MAIL_FROM", $from)
            [IO.File]::WriteAllText("$tmp\ALLOWED_EMAILS", $allowed)

            New-SecretFromFiles 'cyberlab-mirror-api' $tmp
            Write-Host 'Created cyberlab-mirror-api. The API pod starts once both Secrets exist.' -ForegroundColor Green
        } finally {
            Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
