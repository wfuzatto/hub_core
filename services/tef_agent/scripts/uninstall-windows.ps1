$Task='ValeMantiqueiraTefAgent'
Unregister-ScheduledTask -TaskName $Task -Confirm:$false -ErrorAction SilentlyContinue
Write-Host "Autostart removido: $Task"
