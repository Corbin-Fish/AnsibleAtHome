#this is a script for asynchronous remote PS
#use cases are simple, anything you can do with powershell you can do with this across many devices at once
#this is not the most effective or secure way to do this i am however locked to powershell 5 and this is the best i could come up with

# "we have ansible at home"

#variables to define what we are targeting where psexec is and how many connections we can create
#you can change the device list away from txt but i prefer it over CSV
$devices = Get-Content "C:\Temp\Devices.txt" | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() }    
$psexec = "C:\Software\SysInternals\PsExec64.exe"                                                              
$throttle = 50                                                                                                      

# TrustedHosts / Remoting Management
# combined into a single upfront batch write to avoid parallel thread collision/registry locks.
# https://learn.microsoft.com/en-us/powershell/module/microsoft.wsman.management/about/about_wsman_provider?view=powershell-7.6
try {
    #this pulls everything from a virtual powershell file location for wsman
    $current = (Get-Item WSMan:\localhost\Client\TrustedHosts).Value        
    $existing = @()
    if ($current) {                                                        
        $existing = $current -split ',' |                                  
        ForEach-Object { $_.Trim() } |                                      
        Where-Object { $_ } }                                              
    #creates $combined and then adds the values from $existing and $devices together, adding our devices in the txt file
    $combined = ($existing + $devices |                                      
    Select-Object -Unique) -join ','                                        
    #rewrite the virtual file location with our new data from $combined
    Set-Item WSMan:\localhost\Client\TrustedHosts -Value $combined -Force  
} catch {
    throw "Failed to update TrustedHosts: $($_.Exception.Message)"          
}

# defines the object and script to perform when creating the threads
$worker = {
    param(
        [string]$Device,
        [string]$PsExecPath
    )

    #basically a hash table which is easily exported to csv
    $result = [pscustomobject]@{
        Device = $Device
        Status = "Unknown"
        Payload = $null
        Detail = $null
    }
    try {
        & $PsExecPath -accepteula "\\$Device" -s powershell Enable-PSRemoting -Force *>$null
        #create the native WSMan Session
        $session = New-PSSession -ComputerName $Device -ErrorAction Stop
        Write-Host -ForegroundColor Cyan "Successful Connection to $Device"
        try {
            #execute payload
            $output = Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
                # Example:
                # Get-Service | Where-Object { $_.Status -eq 'Running' }
            }
            $result.Status = "Success"
            $result.Payload = $output
            $result.Detail = "Completed successfully"
        }
        finally {
            # ensure the session is torn down to preserve local ephemeral ports
            if ($session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
        }
    }
    catch {
        $result.Status = "Failed"
        $result.Detail = $_.Exception.Message
    }
    return $result
}

# This is for creating runspace / basically a lightweight wrapper for PowerShell
# https://learn.microsoft.com/en-us/dotnet/api/system.management.automation.runspaces.runspacepool?view=powershellsdk-7.6.0
$iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
$pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $throttle, $iss, $Host)
$pool.Open()
$threads = New-Object System.Collections.Generic.List[object]

# prime and delegate to the .NET Runspace Engine
foreach ($device in $devices) {
    #this creates the runspace and defines function
    $ps = [PowerShell]::Create().AddScript($worker).AddArgument($device).AddArgument($psexec)
    $ps.RunspacePool = $pool
    $threads.Add([pscustomobject]@{
        Device = $device
        Pipe = $ps
        Handle = $ps.BeginInvoke()
    })
}

$results = New-Object System.Collections.Generic.List[object]

while ($threads.Count -gt 0) {
    for ($i = $threads.Count - 1; $i -ge 0; $i--) {
        if ($threads[$i].Handle.IsCompleted) {
            try {
                $outputData = $threads[$i].Pipe.EndInvoke($threads[$i].Handle)
                if ($outputData) { $results.AddRange($outputData) }
            } catch {
                $results.Add([pscustomobject]@{
                    Device = $threads[$i].Device
                    Status = "Failed"
                    Payload = $null
                    Detail = $_.Exception.Message
                })
            } finally {
                $threads[$i].Pipe.Dispose()
                $threads.RemoveAt($i)
                Write-Host -ForegroundColor Green "Successful Disconnection from $($threads[$i].Device)"
            }
        }
    }
    # tight sleep loop to minimize CPU spinning while waiting for network IO responses
    Start-Sleep -Milliseconds 100
}
# clean shutdown of the main pool
$pool.Close()
$pool.Dispose()

# returns results in the form of csv i prefer txt but i answer to a change advisory board so this is easier
$results | Sort-Object Device | Export-Csv "C:\Temp\RemoteRunResults.csv" -NoTypeInformation
$results | Group-Object Status | Select-Object Name, Count
