$ErrorActionPreference='Continue'
Write-Host '=== Sistema ==='
Get-ComputerInfo | Select-Object WindowsProductName,WindowsVersion,OsArchitecture | Format-List
Write-Host '=== Dispositivos candidatos ==='
Get-PnpDevice -PresentOnly | Where-Object { $_.FriendlyName -match 'Gertec|PPC|PIN.?Pad|USB Serial|COM' -or $_.InstanceId -match 'USB' } | Select-Object Status,Class,FriendlyName,InstanceId | Format-Table -AutoSize
Write-Host '=== Portas seriais ==='
Get-CimInstance Win32_SerialPort | Select-Object DeviceID,Name,Description,PNPDeviceID | Format-Table -AutoSize
Write-Host '=== USB PnP ==='
Get-CimInstance Win32_PnPEntity | Where-Object { $_.Name -match 'Gertec|PPC|PIN.?Pad' } | Select-Object Name,Manufacturer,DeviceID,Status | Format-List
