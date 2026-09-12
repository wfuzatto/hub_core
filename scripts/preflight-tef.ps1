param([string]$Url=$env:TEF_AGENT_URL,[string]$Token=$env:TEF_AGENT_TOKEN)
if($env:TEF_ENABLED -ne 'true'){Write-Output 'TEF disabled'; exit 0}
if(!$Url -or !$Token){throw 'TEF_AGENT_URL and TEF_AGENT_TOKEN are required when TEF_ENABLED=true'}
$h=@{'Authorization'="Bearer $Token"}; $health=Invoke-RestMethod "$Url/health"; $device=Invoke-RestMethod "$Url/v1/device" -Headers $h; $status=Invoke-RestMethod "$Url/v1/status" -Headers $h
"TEF Agent.............. OK"; "PPC930 USB............. $([string]::Join('', $(if($device.detected){'OK'}else{'NOT DETECTED'})))"; "Driver................. $($status.driver)"; "Terminal............... $($status.terminal_id)"; "SDK TEF................ $($status.sdk)"; "Real payments.......... DISABLED"
