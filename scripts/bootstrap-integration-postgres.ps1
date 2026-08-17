[CmdletBinding()]
param(
    [string]$ContainerName = "pacgate-test-postgres",
    [int]$HostPort = 5435,
    [string]$Database = "pacgate_test",
    [string]$User = "hermes",
    [string]$Password = "changeme",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host "[pacgate] $Message"
}

function Test-DockerServer {
    $null = docker version --format '{{.Server.Version}}' 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Get-PortBoundContainer {
    docker ps --format '{{.Names}}|{{.Image}}|{{.Ports}}' |
    Where-Object {
        $_ -match ":$HostPort->5432/tcp"
    } |
    Select-Object -First 1
}

function Ensure-Database {
    param([string]$Name)

    $exists = docker exec $Name psql -U $User -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '$Database';"
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to inspect databases in container '$Name'."
    }

    if ($exists.Trim() -ne "1") {
        Write-Step "Creating database '$Database' in container '$Name'"
        docker exec $Name psql -U $User -d postgres -c "CREATE DATABASE $Database;" | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create database '$Database' in container '$Name'."
        }
    }
}

function Enable-VectorIfAvailable {
    param([string]$Name)

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $outputLines = docker exec $Name psql -U $User -d $Database -c "CREATE EXTENSION IF NOT EXISTS vector;" 2>&1 |
        ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) {
                $_.Exception.Message
            }
            else {
                $_.ToString()
            }
        }
        $output = ($outputLines | Where-Object { $_ -and $_.Trim() -ne "" }) -join " `n"
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }

    if ($LASTEXITCODE -ne 0) {
        Write-Warning "pgvector is not available in container '$Name'. Continuing because the current pacgate-api integration tests no longer require RAG migrations to succeed. Details: $output"
        return $false
    }

    Write-Step "pgvector extension is available in '$Database'"
    return $true
}

function Wait-ForPostgres {
    param([string]$Name)

    for ($attempt = 1; $attempt -le 30; $attempt++) {
        docker exec $Name psql -U $User -d $Database -tAc "SELECT 1;" | Out-Null
        if ($LASTEXITCODE -eq 0) {
            return
        }

        Start-Sleep -Seconds 1
    }

    throw "Container '$Name' started but Postgres is not ready yet."
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "docker CLI not found. Install Docker Desktop first."
}

if (-not (Test-DockerServer)) {
    $dockerDesktop = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
    if (Test-Path $dockerDesktop) {
        if ($DryRun) {
            Write-Step "Would start Docker Desktop: $dockerDesktop"
            return
        }

        Write-Step "Starting Docker Desktop"
        Start-Process -FilePath $dockerDesktop | Out-Null
    }

    if (-not (Test-DockerServer)) {
        throw "Docker engine is not reachable yet. Re-run this script after Docker Desktop finishes starting."
    }
}

$existing = Get-PortBoundContainer
if ($existing) {
    $parts = $existing.Split('|', 3)
    $name = $parts[0]
    $image = $parts[1]
    Write-Step "Reusing existing port $HostPort listener: $name ($image)"
    Ensure-Database -Name $name
    $null = Enable-VectorIfAvailable -Name $name
}
else {
    $containerExists = docker ps -a --format '{{.Names}}' | Where-Object { $_ -eq $ContainerName }

    if ($DryRun) {
        if ($containerExists) {
            Write-Step "Would start existing container '$ContainerName'"
        }
        else {
            Write-Step "Would create pgvector/pgvector:pg16 container '$ContainerName' on localhost:$HostPort"
        }
        return
    }

    if ($containerExists) {
        Write-Step "Starting existing container '$ContainerName'"
        docker start $ContainerName | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to start container '$ContainerName'."
        }
    }
    else {
        Write-Step "Creating pgvector-backed Postgres container '$ContainerName' on localhost:$HostPort"
        docker run -d --name $ContainerName -e "POSTGRES_USER=$User" -e "POSTGRES_PASSWORD=$Password" -e "POSTGRES_DB=$Database" -p ${HostPort}:5432 pgvector/pgvector:pg16 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create container '$ContainerName'. If port $HostPort is already in use, free it and rerun."
        }
    }

    Write-Step "Checking database readiness in '$ContainerName'"
    Wait-ForPostgres -Name $ContainerName

    $null = Enable-VectorIfAvailable -Name $ContainerName
}

Write-Step "Integration-test Postgres is ready at postgres://${User}:${Password}@localhost:${HostPort}/${Database}"
Write-Step "Next command: cargo test -p pacgate-api --test integration -- --ignored --nocapture"