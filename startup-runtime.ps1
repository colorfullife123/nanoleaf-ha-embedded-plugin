function Invoke-NhaStartupCheck {
    [CmdletBinding()]
    param(
        [string]$TaskName = 'Nanoleaf HA Plugin Repair',
        [ValidateRange(1, 180)][int]$TimeoutSeconds = 120
    )

    $Scheduler = New-Object -ComObject 'Schedule.Service'
    $Scheduler.Connect()
    $Task = $Scheduler.GetFolder('\').GetTask($TaskName)
    $Instance = $Task.Run($null)
    $InstanceId = $Instance.InstanceGuid
    $Deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $Active = $false
        foreach ($RunningTask in $Task.GetInstances(0)) {
            if ($RunningTask.InstanceGuid -eq $InstanceId) { $Active = $true; break }
        }
        if (-not $Active) { return [int]$Task.LastTaskResult }
        if ([DateTime]::UtcNow -ge $Deadline) { throw 'Startup repair task timed out; Desktop was not launched.' }
        Start-Sleep -Milliseconds 200
    } while ($true)
}
