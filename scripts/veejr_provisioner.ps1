[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $SourceUrl,
  [Parameter(Mandatory)] [string] $TokenFile,
  [Parameter(Mandatory)] [string] $EnvironmentTemplate,
  [Parameter(Mandatory)] [string] $Caddyfile,
  [string] $StateRoot = "C:\ProgramData\Veejr\instances",
  [string] $CaddyContainer = "veej_caddy",
  [string] $ElixirImage = "elixir:1.20-otp-28",
  [string] $Repository = "https://github.com/veejr/veejr-server.git",
  [int] $FirstPort = 4001,
  [int] $PollSeconds = 15,
  [switch] $Once
)

$ErrorActionPreference = "Stop"
$SourceUrl = $SourceUrl.TrimEnd("/")
$Token = (Get-Content -Raw -LiteralPath $TokenFile).Trim()
if ($Token.Length -lt 32) { throw "The provisioner token must contain at least 32 characters." }
$Headers = @{ Authorization = "Bearer $Token" }

function Invoke-Docker([string[]] $Arguments) {
  $previousPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $output = & docker @Arguments 2>&1
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousPreference
  }
  if ($exitCode -ne 0) { throw "docker $($Arguments[0]) failed:`n$($output -join "`n")" }
  return $output
}

function Get-SafeName([string] $HostName) {
  $name = "veejr_" + ($HostName.ToLowerInvariant() -replace "[^a-z0-9]+", "_").Trim("_")
  if ($name.Length -gt 55) { $name = $name.Substring(0, 55).Trim("_") }
  return $name
}

function Get-FreePort([int] $Start) {
  for ($port = $Start; $port -lt 65000; $port++) {
    $listener = $null
    try {
      $listener = [System.Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $port)
      $listener.Start()
      return $port
    } catch {
      continue
    } finally {
      if ($listener) { $listener.Stop() }
    }
  }
  throw "No free TCP port was found."
}

function New-SecretKeyBase {
  $bytes = [byte[]]::new(64)
  $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
  try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
  return [Convert]::ToBase64String($bytes)
}

function Write-Utf8NoBom([string] $Path, [string[]] $Lines) {
  [IO.File]::WriteAllLines($Path, $Lines, [Text.UTF8Encoding]::new($false))
}

function Write-InstanceEnvironment($Job, [string] $Path, [int] $Port) {
  $values = [ordered]@{}
  foreach ($line in Get-Content -LiteralPath $EnvironmentTemplate) {
    if ($line -match '^\s*([^#][^=]*)=(.*)$') { $values[$matches[1].Trim()] = $matches[2] }
  }
  $values["MIX_ENV"] = "prod"
  $values["PHX_HOST"] = $Job.target_host
  $values["PORT"] = "$Port"
  $values["VEEJR_MODE"] = $Job.instance_mode
  $values["DATABASE_PATH"] = "/var/lib/veejr/veejr_prod.db"
  $values["VEEJR_BLOB_DIR"] = "/var/lib/veejr/uploads"
  $values["VEEJR_MIGRATION_DIR"] = "/var/lib/veejr/migrations"
  $values["SECRET_KEY_BASE"] = New-SecretKeyBase
  $values.Remove("VEEJR_PROVISIONER_TOKEN")
  $lines = @($values.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" })
  Write-Utf8NoBom $Path $lines
}

function Read-ImportReceipt([string[]] $Output, [string] $PackageSha) {
  $line = $Output | Where-Object { $_ -match '^VEEJR_IMPORT_RECEIPT=' } | Select-Object -Last 1
  if (-not $line) { throw "The importer did not emit a receipt." }
  $encoded = ($line -split '=', 2)[1].Replace('-', '+').Replace('_', '/')
  while (($encoded.Length % 4) -ne 0) { $encoded += '=' }
  $receipt = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded)) | ConvertFrom-Json
  $receipt | Add-Member -NotePropertyName package_sha256 -NotePropertyValue $PackageSha
  return $receipt
}

function Invoke-Import(
  [string] $RepoPath,
  [string] $DataPath,
  [string] $EnvPath,
  [string] $PackagePath,
  [bool] $BuildAssets = $true
) {
  New-Item -ItemType Directory -Force -Path $DataPath, (Join-Path $DataPath "uploads") | Out-Null
  $prepare = "mix deps.get --only prod && mix compile"
  if ($BuildAssets) { $prepare += " && mix assets.deploy" }
  $args = @(
    "run", "--rm", "--env-file", $EnvPath,
    "--mount", "type=bind,source=$RepoPath,target=/app",
    "--mount", "type=bind,source=$DataPath,target=/var/lib/veejr",
    "--mount", "type=bind,source=$PackagePath,target=/move.zip,readonly",
    "--workdir", "/app", $ElixirImage, "bash", "-lc",
    "mix local.hex --force >/dev/null && mix local.rebar --force >/dev/null && $prepare && mix ecto.create && mix ecto.migrate && mix veejr.import /move.zip --no-reconnect --receipt"
  )
  return @(Invoke-Docker $args)
}

function Add-CaddyRoute([string] $HostName, [int] $Port, [string] $ServiceName) {
  if (-not (Test-Path -LiteralPath $Caddyfile)) { throw "Shared Caddyfile not found: $Caddyfile" }
  $caddy = Get-Content -Raw -LiteralPath $Caddyfile
  if ($caddy -match [regex]::Escape("# veejr-managed:$ServiceName")) { return }
  $block = "`r`n# veejr-managed:$ServiceName`r`n$HostName {`r`n  reverse_proxy host.docker.internal:$Port`r`n}`r`n"
  [IO.File]::AppendAllText($Caddyfile, $block, [Text.UTF8Encoding]::new($false))
  try {
    Invoke-Docker @("run", "--rm", "-v", "${Caddyfile}:/etc/caddy/Caddyfile:ro", "caddy:2", "caddy", "validate", "--config", "/etc/caddy/Caddyfile") | Out-Null
    Invoke-Docker @("exec", $CaddyContainer, "caddy", "reload", "--config", "/etc/caddy/Caddyfile") | Out-Null
  } catch {
    [IO.File]::WriteAllText($Caddyfile, $caddy, [Text.UTF8Encoding]::new($false))
    throw
  }
}

function Wait-PublicEndpoint([string] $HostName, [int] $Attempts = 24) {
  for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
    $status = & curl.exe --silent --output NUL --write-out "%{http_code}" `
      --resolve "${HostName}:443:127.0.0.1" "https://${HostName}/" 2>$null
    if ($LASTEXITCODE -eq 0 -and [int]$status -ge 200 -and [int]$status -lt 400) {
      return
    }
    if ($attempt -eq $Attempts) {
      throw "The new HTTPS endpoint did not become ready through local Caddy (last status: $status)."
    }
    Start-Sleep -Seconds 5
  }
}

function Send-Result($Job, [bool] $Success, $Receipt, [string] $ErrorMessage) {
  $body = @{ phase = $Job.phase; success = $Success }
  if ($Receipt) { $body.receipt = $Receipt }
  if ($ErrorMessage) {
    $start = [Math]::Max(0, $ErrorMessage.Length - 2000)
    $body.error = $ErrorMessage.Substring($start)
  }
  Invoke-RestMethod -Method Post -Uri "$SourceUrl/api/provisioner/v1/moves/$($Job.id)/result" -Headers $Headers -ContentType "application/json" -Body ($body | ConvertTo-Json -Depth 8) | Out-Null
}

function Remove-TestWorkspace([string] $Path) {
  $root = [IO.Path]::GetFullPath($StateRoot).TrimEnd('\') + '\'
  $resolved = [IO.Path]::GetFullPath($Path)
  if (-not $resolved.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -or
      -not [IO.Path]::GetFileName($resolved).StartsWith("test-")) {
    throw "Refusing to remove an unexpected test workspace: $resolved"
  }
  if (Test-Path -LiteralPath $resolved) { Remove-Item -Recurse -Force -LiteralPath $resolved }
}

function Invoke-TestJob($Job, [string] $PackagePath, [string] $PackageSha) {
  $scratch = Join-Path $StateRoot ("test-" + $Job.id)
  try {
    New-Item -ItemType Directory -Force -Path $scratch | Out-Null
    $repo = Join-Path $scratch "repo"
    Invoke-Docker @("run", "--rm", "-v", "${scratch}:/work", "alpine/git:2.47.2", "clone", "--depth", "1", $Repository, "/work/repo") | Out-Null
    $env = Join-Path $scratch "veejr.env"
    Write-InstanceEnvironment $Job $env 4000
    $output = Invoke-Import $repo (Join-Path $scratch "data") $env $PackagePath $false
    $receipt = Read-ImportReceipt $output $PackageSha
    Send-Result $Job $true $receipt $null
  } catch {
    Write-Warning "Test job $($Job.id) failed: $($_.Exception.Message)"
    Send-Result $Job $false $null $_.Exception.Message
  } finally {
    Remove-TestWorkspace $scratch
  }
}

function Invoke-FinalJob($Job, [string] $PackagePath, [string] $PackageSha) {
  $service = Get-SafeName $Job.target_host
  $instance = Join-Path $StateRoot $service
  try {
    $receiptFile = Join-Path $instance "import-receipt.json"
    if (Test-Path -LiteralPath $instance) {
      if (-not (Test-Path -LiteralPath $receiptFile)) {
        throw "A partial instance directory exists without an import receipt. Inspect and remove it before retrying: $instance"
      }
      & docker service inspect $service *> $null
      if ($LASTEXITCODE -ne 0) {
        throw "Imported instance data exists but its Docker service does not. Inspect and remove it before retrying: $instance"
      }
      $receipt = Get-Content -Raw -LiteralPath $receiptFile | ConvertFrom-Json
      $env = Join-Path $instance "veejr.env"
      $portLine = Get-Content -LiteralPath $env | Where-Object { $_ -match '^PORT=' } | Select-Object -Last 1
      if (-not $portLine) { throw "The existing instance environment has no PORT value." }
      $port = [int](($portLine -split '=', 2)[1])
      Add-CaddyRoute $Job.target_host $port $service
      Wait-PublicEndpoint $Job.target_host
      $receipt | Add-Member -NotePropertyName service -NotePropertyValue $service -Force
      $receipt | Add-Member -NotePropertyName port -NotePropertyValue $port -Force
      $receipt | Add-Member -NotePropertyName url -NotePropertyValue ("https://" + $Job.target_host) -Force
      Send-Result $Job $true $receipt $null
      return
    }
    New-Item -ItemType Directory -Force -Path $instance | Out-Null
    $repo = Join-Path $instance "repo"
    Invoke-Docker @("run", "--rm", "-v", "${instance}:/work", "alpine/git:2.47.2", "clone", "--depth", "1", $Repository, "/work/repo") | Out-Null
    $port = Get-FreePort $FirstPort
    $env = Join-Path $instance "veejr.env"
    Write-InstanceEnvironment $Job $env $port
    $data = Join-Path $instance "data"
    $output = Invoke-Import $repo $data $env $PackagePath
    $receipt = Read-ImportReceipt $output $PackageSha
    [IO.File]::WriteAllText(
      $receiptFile,
      ($receipt | ConvertTo-Json -Depth 8),
      [Text.UTF8Encoding]::new($false)
    )

    Invoke-Docker @(
      "service", "create", "--name", $service, "--replicas", "1", "--env-file", $env,
      "--mount", "type=bind,source=$repo,target=/app",
      "--mount", "type=bind,source=$data,target=/var/lib/veejr",
      "--publish", "published=$port,target=$port,protocol=tcp,mode=host",
      "--restart-condition", "any", "--workdir", "/app", $ElixirImage,
      "bash", "-lc", "mix local.hex --force >/dev/null && mix local.rebar --force >/dev/null && mix phx.server"
    ) | Out-Null

    Add-CaddyRoute $Job.target_host $port $service
    Wait-PublicEndpoint $Job.target_host
    $receipt | Add-Member -NotePropertyName service -NotePropertyValue $service
    $receipt | Add-Member -NotePropertyName port -NotePropertyValue $port
    $receipt | Add-Member -NotePropertyName url -NotePropertyValue ("https://" + $Job.target_host)
    Send-Result $Job $true $receipt $null
  } catch {
    Write-Warning "Final job $($Job.id) failed: $($_.Exception.Message)"
    Send-Result $Job $false $null $_.Exception.Message
  }
}

New-Item -ItemType Directory -Force -Path $StateRoot | Out-Null
do {
  $response = $null
  try {
    $response = Invoke-RestMethod -Method Post -Uri "$SourceUrl/api/provisioner/v1/jobs/claim" -Headers $Headers
  } catch {
    Write-Warning $_.Exception.Message
  }

  if ($response.job) {
    $job = $response.job
    $download = Join-Path $StateRoot ("move-" + $job.id + ".zip")
    try {
      Invoke-WebRequest -Uri ($SourceUrl + $job.package_path) -Headers $Headers -OutFile $download
      $sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $download).Hash.ToLowerInvariant()
      if ($sha -ne $job.package_sha256) { throw "Downloaded package checksum does not match the job." }
      if ($job.phase -eq "test") { Invoke-TestJob $job $download $sha } else { Invoke-FinalJob $job $download $sha }
    } catch {
      Send-Result $job $false $null $_.Exception.Message
    } finally {
      if (Test-Path -LiteralPath $download) { Remove-Item -Force -LiteralPath $download }
    }
  }

  if (-not $Once) { Start-Sleep -Seconds $PollSeconds }
} while (-not $Once)
