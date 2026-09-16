# Reproduce the CI step "Verify image manifest (anonymous HEAD)" exactly as it is
# written in .github/workflows/build-ghcr.yml, then compare against the same
# request sent WITH the OCI manifest Accept header.
#
# This isolates whether the CI verification failure is caused by the missing
# Accept header (GHCR returns 404 for manifest requests without it, even when
# the package is public) or by the package actually being private.
param(
    [string]$Ns = 'pacgate-ai',
    [string]$Img = 'pacgate-api',
    [string]$Tag = '0.1.9'
)

$token = (Invoke-RestMethod "https://ghcr.io/token?scope=repository:$Ns/${Img}:pull").token
$url = "https://ghcr.io/v2/$Ns/$Img/manifests/$Tag"

Write-Output "namespace/image/tag : $Ns/$Img`:$Tag"
Write-Output "anon token acquired : $([bool]$token)"
Write-Output "manifest url        : $url"
Write-Output ""

# 1) Exactly as the workflow does it today: no Accept header.
$ciCode = & curl.exe -s -o NUL -w '%{http_code}' -H "Authorization: Bearer $token" $url
Write-Output "CI as written (no Accept header) => HTTP $ciCode"

# 2) Corrected: with the OCI/Docker manifest Accept header.
$accept = 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json'
$fixCode = & curl.exe -s -o NUL -w '%{http_code}' -H "Authorization: Bearer $token" -H $accept $url
Write-Output "Corrected (with Accept header)   => HTTP $fixCode"

Write-Output ""
if ($ciCode -ne '200' -and $fixCode -eq '200') {
    Write-Output "ROOT CAUSE CONFIRMED: CI fails because it omits the Accept header."
    Write-Output "The image is genuinely public; the verification logic is wrong."
}
elseif ($ciCode -eq '200') {
    Write-Output "CI step would pass now (package is public); no Accept-header bug here."
}
else {
    Write-Output "Both requests failed - investigate token scope / tag existence."
}
