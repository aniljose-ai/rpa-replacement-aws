#!/bin/bash
set -e

# Arguments passed from Terraform
PROJECT_NAME=$1
REGION=$2

echo "Starting CodeBuild for project: $PROJECT_NAME in region: $REGION"

# Start the build
BUILD_ID=$(aws codebuild start-build \
  --project-name "$PROJECT_NAME" \
  --region "$REGION" \
  --query 'build.id' \
  --output text)

echo "Build started with ID: $BUILD_ID"

# Wait for the build to complete by polling
echo "Waiting for build to complete..."
MAX_WAIT=3600  # 60 minutes — matches CodeBuild build_timeout
ELAPSED=0
SLEEP_TIME=10

while [ $ELAPSED -lt $MAX_WAIT ]; do
  BUILD_STATUS=$(aws codebuild batch-get-builds \
    --ids "$BUILD_ID" \
    --region "$REGION" \
    --query 'builds[0].buildStatus' \
    --output text)

  if [ "$BUILD_STATUS" = "SUCCEEDED" ]; then
    echo "Build succeeded!"
    exit 0
  elif [ "$BUILD_STATUS" = "FAILED" ] || [ "$BUILD_STATUS" = "FAULT" ] || [ "$BUILD_STATUS" = "TIMED_OUT" ] || [ "$BUILD_STATUS" = "STOPPED" ]; then
    echo "Build failed with status: $BUILD_STATUS"
    echo "Check CloudWatch logs at: /aws/codebuild/$PROJECT_NAME"
    exit 1
  fi

  echo "Build status: $BUILD_STATUS (elapsed: ${ELAPSED}s)"
  sleep $SLEEP_TIME
  ELAPSED=$((ELAPSED + SLEEP_TIME))
done

echo "Build timed out after ${MAX_WAIT}s"
exit 1
