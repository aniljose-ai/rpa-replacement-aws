param(
  [Parameter(Mandatory = $true)] [string]$ProjectName,
  [Parameter(Mandatory = $true)] [string]$Region
)

$ErrorActionPreference = "Stop"

Write-Host "Starting CodeBuild for project: $ProjectName in region: $Region"

# Start the build
$buildId = (aws codebuild start-build `
    --project-name $ProjectName `
    --region $Region `
    --query 'build.id' `
    --output text)

Write-Host "Build started with ID: $buildId"

# Poll until complete
Write-Host "Waiting for build to complete..."
$maxWait  = 3600  # 60 minutes — matches CodeBuild build_timeout
$elapsed  = 0
$sleep    = 10

while ($elapsed -lt $maxWait) {
  $status = (aws codebuild batch-get-builds `
      --ids $buildId `
      --region $Region `
      --query 'builds[0].buildStatus' `
      --output text)

  if ($status -eq "SUCCEEDED") {
    Write-Host "Build succeeded!"
    exit 0
  }

  if ($status -in @("FAILED", "FAULT", "TIMED_OUT", "STOPPED")) {
    Write-Host "Build failed with status: $status"
    Write-Host "Check CloudWatch logs at: /aws/codebuild/$ProjectName"
    exit 1
  }

  Write-Host "Build status: $status (elapsed: ${elapsed}s)"
  Start-Sleep -Seconds $sleep
  $elapsed += $sleep
}

Write-Host "Build timed out after ${maxWait}s"
exit 1
