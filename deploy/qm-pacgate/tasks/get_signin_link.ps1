$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$msg = Invoke-RestMethod -Uri 'http://localhost:8025/api/v1/messages?limit=1'
$id = $msg.messages[0].ID
Write-Host "Newest message ID: $id"
$detail = Invoke-RestMethod -Uri "http://localhost:8025/api/v1/message/$id"
$text = $detail.Text
$m = [regex]::Match($text, 'http://localhost:8181/idp/verify#token=\S+')
if ($m.Success) {
  $link = $m.Value.Trim()
  Write-Host "LINK:"
  Write-Host $link
  # Save link to a file for later use
  [System.IO.File]::WriteAllText("$env:TEMP\qm_signin_link.txt", $link)
} else {
  Write-Host "NO LINK FOUND in message text"
}