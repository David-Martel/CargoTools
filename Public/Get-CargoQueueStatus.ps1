function Get-CargoQueueStatus {
<#
.SYNOPSIS
Shows the current CargoTools build queue state.
.DESCRIPTION
Reports queued CargoTools-managed build requests, the queue root, and the
configured maximum number of concurrently active builds.
#>
    [CmdletBinding()]
    param(
        [string]$CacheRoot
    )

    return Get-CargoQueueStatusInternal -CacheRoot $CacheRoot
}
