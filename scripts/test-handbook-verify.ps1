# Verbatim copy of the verify snippet now in deploy/AIPC-DEPLOYMENT-HANDBOOK.md
# Run this to prove the handbook instruction actually works.
$acc = "application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json"
$compose = "deploy/client-bundle/compose.prod.yaml"
$pins = Select-String -Path $compose -Pattern "image:\s*(ghcr\.io/[^\s]+)" -AllMatches |
        ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value } |
        Where-Object { $_ -notmatch "openviking" } | Sort-Object -Unique

foreach ($pin in $pins) {
  $repo = $pin -replace "^ghcr\.io/", ""
  $name = ($repo -split ":")[0]
  $tag  = ($repo -split ":")[1]
  $t = (Invoke-RestMethod "https://ghcr.io/token?scope=repository:$name`:pull").token
  try {
    $code = (Invoke-WebRequest -Uri "https://ghcr.io/v2/$name/manifests/$tag" `
              -Headers @{Authorization="Bearer $t"; Accept=$acc} `
              -Method Head -UseBasicParsing).StatusCode
  } catch {
    $code = $_.Exception.Response.StatusCode.value__
  }
  "{0,-58} => HTTP {1}" -f $pin, $code
}
