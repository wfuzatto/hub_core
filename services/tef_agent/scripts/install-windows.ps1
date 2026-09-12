$ErrorActionPreference='Stop'
$Root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Python=(Get-Command python -ErrorAction SilentlyContinue).Source
if(-not $Python){ throw 'Python 3 nao encontrado no PATH' }
if(-not (Test-Path (Join-Path $Root '.env'))){ Copy-Item (Join-Path $Root '.env.example') (Join-Path $Root '.env') }
$Task='ValeMantiqueiraTefAgent'
$Action=New-ScheduledTaskAction -Execute $Python -Argument ('"'+(Join-Path $Root 'tef_agent.py')+'"') -WorkingDirectory $Root
$Trigger=New-ScheduledTaskTrigger -AtStartup
$Principal=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$Settings=New-ScheduledTaskSettingsSet -RestartCount 20 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
Register-ScheduledTask -TaskName $Task -Action $Action -Trigger $Trigger -Principal $Principal -Settings $Settings -Force | Out-Null
Start-ScheduledTask -TaskName $Task
Write-Host "Autostart instalado: $Task"
Write-Host 'Observacao: esta primeira versao usa uma Scheduled Task nativa do Windows para hospedar o agente Python; nao instala DLL/SDK TEF.'
