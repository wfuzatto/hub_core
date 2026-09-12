$Root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $Root
python -m unittest -v test_tef_agent.py
