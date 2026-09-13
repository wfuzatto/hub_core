$Task='ValeMantiqueiraTefAgent'
Get-ScheduledTask -TaskName $Task -ErrorAction SilentlyContinue | Get-ScheduledTaskInfo
try { Invoke-RestMethod http://127.0.0.1:8766/health | ConvertTo-Json -Depth 5 } catch { Write-Warning $_ }
