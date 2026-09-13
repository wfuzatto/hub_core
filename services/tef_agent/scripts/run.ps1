$Root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $Root
if(Test-Path '.env'){ Get-Content '.env' | Where-Object {$_ -match '^[A-Za-z_][A-Za-z0-9_]*='} | ForEach-Object { $p=$_.Split('=',2); [Environment]::SetEnvironmentVariable($p[0],$p[1],'Process') } }
python .\tef_agent.py
