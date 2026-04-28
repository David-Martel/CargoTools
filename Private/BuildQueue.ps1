function Get-CargoQueueSettings {
    [CmdletBinding()]
    param()

    $mc = Get-MachineConfig

    $maxActiveBuilds = 1
    if ($env:CARGOTOOLS_MAX_ACTIVE_BUILDS) {
        $maxActiveBuilds = [Math]::Max(1, [int]$env:CARGOTOOLS_MAX_ACTIVE_BUILDS)
    } elseif ($mc['MaxConcurrentBuilds']) {
        $maxActiveBuilds = [Math]::Max(1, [int]$mc['MaxConcurrentBuilds'])
    }

    $pollIntervalMs = 500
    if ($env:CARGOTOOLS_QUEUE_POLL_MS) {
        $pollIntervalMs = [Math]::Max(100, [int]$env:CARGOTOOLS_QUEUE_POLL_MS)
    } elseif ($mc['QueuePollIntervalMs']) {
        $pollIntervalMs = [Math]::Max(100, [int]$mc['QueuePollIntervalMs'])
    }

    $staleMinutes = 240
    if ($env:CARGOTOOLS_QUEUE_STALE_MINUTES) {
        $staleMinutes = [Math]::Max(10, [int]$env:CARGOTOOLS_QUEUE_STALE_MINUTES)
    } elseif ($mc['QueueStaleMinutes']) {
        $staleMinutes = [Math]::Max(10, [int]$mc['QueueStaleMinutes'])
    }

    [PSCustomObject]@{
        MaxActiveBuilds = $maxActiveBuilds
        PollIntervalMs  = $pollIntervalMs
        StaleMinutes    = $staleMinutes
    }
}

function Get-CargoQueueRoot {
    [CmdletBinding()]
    param(
        [string]$CacheRoot
    )

    $resolvedCacheRoot = Resolve-CacheRoot -CacheRoot $CacheRoot
    $queueRoot = Join-Path $resolvedCacheRoot 'cargo-queue'
    Ensure-Directory -Path $queueRoot
    Ensure-Directory -Path (Join-Path $queueRoot 'tickets')
    return $queueRoot
}

function Test-CargoQueuePidActive {
    param([int]$Pid)

    if ($Pid -le 0) { return $false }
    return $null -ne (Get-Process -Id $Pid -ErrorAction SilentlyContinue)
}

function Read-CargoQueueTicket {
    param(
        [Parameter(Mandatory)]
        [System.IO.FileInfo]$File
    )

    try {
        $ticket = Get-Content -LiteralPath $File.FullName -Raw | ConvertFrom-Json
        [PSCustomObject]@{
            Path          = $File.FullName
            Name          = $File.Name
            CreatedUtc    = [datetime]$ticket.CreatedUtc
            Pid           = [int]$ticket.Pid
            Command       = [string]$ticket.Command
            WorkingDir    = [string]$ticket.WorkingDir
            Hostname      = [string]$ticket.Hostname
            Args          = @($ticket.Args)
            LastWriteTime = $File.LastWriteTimeUtc
        }
    } catch {
        $parts = $File.BaseName -split '_', 3
        $pid = if ($parts.Count -ge 2 -and ($parts[1] -as [int])) { [int]$parts[1] } else { 0 }
        [PSCustomObject]@{
            Path          = $File.FullName
            Name          = $File.Name
            CreatedUtc    = $File.CreationTimeUtc
            Pid           = $pid
            Command       = ''
            WorkingDir    = ''
            Hostname      = $env:COMPUTERNAME
            Args          = @()
            LastWriteTime = $File.LastWriteTimeUtc
        }
    }
}

function Remove-StaleCargoQueueTickets {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$QueueRoot,
        [int]$StaleMinutes = 240
    )

    $ticketDir = Join-Path $QueueRoot 'tickets'
    if (-not (Test-Path -LiteralPath $ticketDir)) { return 0 }

    $removedCount = 0
    $staleCutoff = (Get-Date).ToUniversalTime().AddMinutes(-$StaleMinutes)

    foreach ($file in (Get-ChildItem -LiteralPath $ticketDir -File -Filter '*.json' -ErrorAction SilentlyContinue)) {
        $ticket = Read-CargoQueueTicket -File $file
        $pidActive = Test-CargoQueuePidActive -Pid $ticket.Pid
        $isStale = $ticket.LastWriteTime.ToUniversalTime() -lt $staleCutoff

        if (-not $pidActive -or $isStale) {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
            $removedCount++
        }
    }

    return $removedCount
}

function Get-CargoQueueEntries {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$QueueRoot
    )

    $ticketDir = Join-Path $QueueRoot 'tickets'
    if (-not (Test-Path -LiteralPath $ticketDir)) { return @() }

    $entries = foreach ($file in (Get-ChildItem -LiteralPath $ticketDir -File -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object Name)) {
        Read-CargoQueueTicket -File $file
    }

    return @($entries | Sort-Object CreatedUtc, Name)
}

function Test-CargoCommandNeedsQueue {
    param([string]$PrimaryCommand)

    if ([string]::IsNullOrWhiteSpace($PrimaryCommand)) { return $false }
    return @('build', 'b', 'run', 'r', 'test', 't', 'bench', 'install', 'check', 'clippy', 'doc', 'rustc') -contains $PrimaryCommand
}

function Enter-CargoBuildQueue {
    [CmdletBinding()]
    param(
        [string[]]$ArgsList,
        [string]$WorkingDirectory = (Get-Location).Path,
        [string]$CacheRoot
    )

    $settings = Get-CargoQueueSettings
    if ($settings.MaxActiveBuilds -le 0) {
        return $null
    }

    $queueRoot = Get-CargoQueueRoot -CacheRoot $CacheRoot
    $ticketDir = Join-Path $queueRoot 'tickets'
    $createdUtc = (Get-Date).ToUniversalTime()
    $ticketName = '{0}_{1}_{2}.json' -f $createdUtc.ToString('yyyyMMddHHmmssfff'), $PID, ([guid]::NewGuid().ToString('N'))
    $ticketPath = Join-Path $ticketDir $ticketName
    $ticket = @{
        CreatedUtc = $createdUtc.ToString('o')
        Pid        = $PID
        Command    = (Get-PrimaryCommand $ArgsList)
        WorkingDir = $WorkingDirectory
        Hostname   = $env:COMPUTERNAME
        Args       = @($ArgsList)
    } | ConvertTo-Json -Depth 4
    Set-Content -LiteralPath $ticketPath -Value $ticket -Encoding UTF8

    $firstWaitNotice = $true
    $lastPosition = -1
    $waitStart = Get-Date
    $ticketState = $null

    while ($true) {
        $lock = $null
        try {
            if (([System.Management.Automation.PSTypeName]'CargoTools.ProcessMutex').Type) {
                $lock = [CargoTools.ProcessMutex]::TryAcquire('CargoTools_BuildQueueLock', 10000)
            }

            Remove-StaleCargoQueueTickets -QueueRoot $queueRoot -StaleMinutes $settings.StaleMinutes | Out-Null
            $entries = Get-CargoQueueEntries -QueueRoot $queueRoot
            $positionIndex = -1
            for ($i = 0; $i -lt $entries.Count; $i++) {
                if ($entries[$i].Path -eq $ticketPath) {
                    $positionIndex = $i
                    break
                }
            }

            if ($positionIndex -lt 0) {
                Set-Content -LiteralPath $ticketPath -Value $ticket -Encoding UTF8
                continue
            }

            if ($positionIndex -lt $settings.MaxActiveBuilds) {
                $ticketState = [PSCustomObject]@{
                    TicketPath       = $ticketPath
                    QueueRoot        = $queueRoot
                    Position         = $positionIndex + 1
                    QueueDepth       = $entries.Count
                    MaxActiveBuilds  = $settings.MaxActiveBuilds
                    WaitedMs         = [int]((Get-Date) - $waitStart).TotalMilliseconds
                }
                break
            }

            $queuePosition = $positionIndex + 1
            if ($firstWaitNotice -or $queuePosition -ne $lastPosition) {
                Write-CargoStatus -Phase 'Queue' -Message "Build queue active. Position $queuePosition of $($entries.Count); waiting for a build slot." -Type 'Info' -MinVerbosity 1
                $firstWaitNotice = $false
                $lastPosition = $queuePosition
            }
        } finally {
            if ($lock) { $lock.Dispose() }
        }

        Start-Sleep -Milliseconds $settings.PollIntervalMs
    }

    if ($ticketState.WaitedMs -gt 0) {
        $waitedSeconds = [Math]::Round($ticketState.WaitedMs / 1000.0, 2)
        Write-CargoStatus -Phase 'Queue' -Message "Build slot acquired after ${waitedSeconds}s." -Type 'Success' -MinVerbosity 1
    }

    return $ticketState
}

function Exit-CargoBuildQueue {
    [CmdletBinding()]
    param(
        [string]$TicketPath
    )

    if ([string]::IsNullOrWhiteSpace($TicketPath)) { return }

    $lock = $null
    try {
        if (([System.Management.Automation.PSTypeName]'CargoTools.ProcessMutex').Type) {
            $lock = [CargoTools.ProcessMutex]::TryAcquire('CargoTools_BuildQueueLock', 10000)
        }

        if (Test-Path -LiteralPath $TicketPath) {
            Remove-Item -LiteralPath $TicketPath -Force -ErrorAction SilentlyContinue
        }
    } finally {
        if ($lock) { $lock.Dispose() }
    }
}

function Get-CargoQueueStatusInternal {
    [CmdletBinding()]
    param(
        [string]$CacheRoot
    )

    $settings = Get-CargoQueueSettings
    $queueRoot = Get-CargoQueueRoot -CacheRoot $CacheRoot
    Remove-StaleCargoQueueTickets -QueueRoot $queueRoot -StaleMinutes $settings.StaleMinutes | Out-Null
    $entries = @(Get-CargoQueueEntries -QueueRoot $queueRoot)

    [PSCustomObject]@{
        QueueRoot        = $queueRoot
        MaxActiveBuilds  = $settings.MaxActiveBuilds
        QueueDepth       = $entries.Count
        Entries          = $entries
    }
}
