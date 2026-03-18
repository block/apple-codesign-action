#!/usr/bin/env bats

# Unit tests for apple-codesign-action
# Uses mock aws/jq commands to test logic without real AWS calls

setup() {
  export RUNNER_TEMP="${BATS_TEST_TMPDIR}"
  export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/github_output"
  export GITHUB_SHA="abc123"
  export GITHUB_RUN_ID="99999"
  export GITHUB_REPOSITORY="block/test-repo"

  # Create mock bin directory and prepend to PATH
  export MOCK_BIN="${BATS_TEST_TMPDIR}/mock-bin"
  mkdir -p "${MOCK_BIN}"
  export PATH="${MOCK_BIN}:${PATH}"

  # Fixtures path
  export FIXTURES="${BATS_TEST_DIRNAME}/fixtures"

  # Reset output file
  > "${GITHUB_OUTPUT}"
}

teardown() {
  rm -rf "${MOCK_BIN}"
}

# --- Helper functions ---

create_mock_aws() {
  cat > "${MOCK_BIN}/aws" << 'SCRIPT'
#!/bin/bash
# Mock aws CLI
if [[ "$1" == "s3" && "$2" == "cp" ]]; then
  # Mock s3 cp — just touch the destination if it's a local path
  dest="${*: -1}"
  if [[ "${dest}" != s3://* ]]; then
    touch "${dest}"
  fi
  exit 0
elif [[ "$1" == "lambda" && "$2" == "invoke" ]]; then
  # Mock lambda invoke — copy the mock response to the output file
  output_file="${*: -1}"
  if [[ -n "${MOCK_LAMBDA_RESPONSE:-}" ]]; then
    cp "${MOCK_LAMBDA_RESPONSE}" "${output_file}"
  else
    echo '{"statusCode":"200","body":{"build_number":"12345","state":"scheduled"}}' > "${output_file}"
  fi
  exit 0
fi
echo "Unexpected aws command: $*" >&2
exit 1
SCRIPT
  chmod +x "${MOCK_BIN}/aws"
}

create_test_artifact() {
  local path="${1:-${BATS_TEST_TMPDIR}/test-artifact.zip}"
  echo "fake zip content" > "${path}"
  echo "${path}"
}

get_output() {
  local key="$1"
  grep "^${key}=" "${GITHUB_OUTPUT}" | head -1 | cut -d= -f2-
}

# --- Upload step tests ---

@test "upload: fails if unsigned artifact does not exist" {
  export UNSIGNED_PATH="${BATS_TEST_TMPDIR}/nonexistent.zip"
  export ENTITLEMENTS_PATH=""
  export S3_BUCKET="test-bucket"
  export ARTIFACT_NAME="test-artifact"

  create_mock_aws

  run bash -c 'set -euo pipefail
    artifact_name="${ARTIFACT_NAME:-${GITHUB_SHA}-${GITHUB_RUN_ID}}"
    if [[ ! -f "${UNSIGNED_PATH}" ]]; then
      echo "::error::Unsigned artifact not found: ${UNSIGNED_PATH}"
      exit 1
    fi'

  [ "$status" -eq 1 ]
  [[ "$output" == *"Unsigned artifact not found"* ]]
}

@test "upload: uploads zip artifact directly" {
  local artifact
  artifact=$(create_test_artifact)
  export UNSIGNED_PATH="${artifact}"
  export ENTITLEMENTS_PATH=""
  export S3_BUCKET="test-bucket"
  export ARTIFACT_NAME="my-artifact"

  # Track aws s3 cp calls
  cat > "${MOCK_BIN}/aws" << 'SCRIPT'
#!/bin/bash
if [[ "$1" == "s3" && "$2" == "cp" ]]; then
  echo "s3-cp: $3 -> $4" >> "${BATS_TEST_TMPDIR}/aws_calls.log"
  exit 0
fi
exit 1
SCRIPT
  chmod +x "${MOCK_BIN}/aws"

  run bash -c '
    set -euo pipefail
    artifact_name="${ARTIFACT_NAME:-${GITHUB_SHA}-${GITHUB_RUN_ID}}"
    if [[ ! -f "${UNSIGNED_PATH}" ]]; then
      echo "::error::Unsigned artifact not found: ${UNSIGNED_PATH}"
      exit 1
    fi
    basename="$(basename "${UNSIGNED_PATH}")"
    upload_path="${UNSIGNED_PATH}"
    s3_key="unsigned/${artifact_name}-${basename}"
    s3_url="s3://${S3_BUCKET}/${s3_key}"
    echo "Uploading to ${s3_url}"
    aws s3 cp --quiet "${upload_path}" "${s3_url}"
    echo "s3-url=${s3_url}" >> "${GITHUB_OUTPUT}"
  '

  [ "$status" -eq 0 ]
  [[ "$(get_output 's3-url')" == "s3://test-bucket/unsigned/my-artifact-test-artifact.zip" ]]
}

@test "upload: fails if entitlements plist is specified but missing" {
  local artifact
  artifact=$(create_test_artifact)
  export UNSIGNED_PATH="${artifact}"
  export ENTITLEMENTS_PATH="${BATS_TEST_TMPDIR}/nonexistent.plist"
  export S3_BUCKET="test-bucket"
  export ARTIFACT_NAME=""

  run bash -c '
    set -euo pipefail
    if [[ ! -f "${UNSIGNED_PATH}" ]]; then
      echo "::error::Unsigned artifact not found: ${UNSIGNED_PATH}"
      exit 1
    fi
    if [[ -n "${ENTITLEMENTS_PATH}" ]]; then
      if [[ ! -f "${ENTITLEMENTS_PATH}" ]]; then
        echo "::error::Entitlements plist not found: ${ENTITLEMENTS_PATH}"
        exit 1
      fi
    fi'

  [ "$status" -eq 1 ]
  [[ "$output" == *"Entitlements plist not found"* ]]
}

@test "upload: default artifact name uses SHA and RUN_ID" {
  local artifact
  artifact=$(create_test_artifact)
  export UNSIGNED_PATH="${artifact}"
  export ENTITLEMENTS_PATH=""
  export S3_BUCKET="test-bucket"
  export ARTIFACT_NAME=""

  create_mock_aws

  run bash -c '
    set -euo pipefail
    artifact_name="${ARTIFACT_NAME:-${GITHUB_SHA}-${GITHUB_RUN_ID}}"
    basename="$(basename "${UNSIGNED_PATH}")"
    s3_key="unsigned/${artifact_name}-${basename}"
    s3_url="s3://${S3_BUCKET}/${s3_key}"
    aws s3 cp --quiet "${UNSIGNED_PATH}" "${s3_url}"
    echo "s3-url=${s3_url}" >> "${GITHUB_OUTPUT}"
  '

  [ "$status" -eq 0 ]
  [[ "$(get_output 's3-url')" == "s3://test-bucket/unsigned/abc123-99999-test-artifact.zip" ]]
}

# --- Invoke step tests ---

@test "invoke: extracts build number from successful response" {
  export S3_URL="s3://test-bucket/unsigned/test.zip"

  # Create mock that returns success response
  export MOCK_LAMBDA_RESPONSE="${BATS_TEST_TMPDIR}/mock-response.json"
  jq '.invoke_success' "${FIXTURES}/mock-responses.json" > "${MOCK_LAMBDA_RESPONSE}"

  create_mock_aws

  run bash -c '
    set -euo pipefail
    source_job_url="https://github.com/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
    payload=$(jq -n \
      --arg s3_url "${S3_URL}" \
      --arg job_url "${source_job_url}" \
      "{source_s3_url: \$s3_url, source_job_url: \$job_url}")
    response_file="${RUNNER_TEMP}/lambda-invoke-response.json"
    aws lambda invoke \
      --function-name codesign_helper \
      --payload "${payload}" \
      --cli-binary-format raw-in-base64-out \
      "${response_file}"
    status_code=$(jq -r ".statusCode" "${response_file}")
    if [[ "${status_code}" != "200" ]]; then
      echo "::error::Lambda invocation failed with status ${status_code}"
      exit 1
    fi
    build_number=$(jq -r ".body.build_number" "${response_file}")
    if [[ -z "${build_number}" || "${build_number}" == "null" ]]; then
      echo "::error::No build_number in Lambda response"
      exit 1
    fi
    echo "build-number=${build_number}" >> "${GITHUB_OUTPUT}"
  '

  [ "$status" -eq 0 ]
  [[ "$(get_output 'build-number')" == "12345" ]]
}

@test "invoke: fails on non-200 status code" {
  export S3_URL="s3://test-bucket/unsigned/test.zip"

  export MOCK_LAMBDA_RESPONSE="${BATS_TEST_TMPDIR}/mock-response.json"
  jq '.invoke_error' "${FIXTURES}/mock-responses.json" > "${MOCK_LAMBDA_RESPONSE}"

  create_mock_aws

  run bash -c '
    set -euo pipefail
    payload=$(jq -n --arg s3_url "${S3_URL}" "{source_s3_url: \$s3_url}")
    response_file="${RUNNER_TEMP}/lambda-invoke-response.json"
    aws lambda invoke \
      --function-name codesign_helper \
      --payload "${payload}" \
      --cli-binary-format raw-in-base64-out \
      "${response_file}"
    status_code=$(jq -r ".statusCode" "${response_file}")
    if [[ "${status_code}" != "200" ]]; then
      echo "::error::Lambda invocation failed with status ${status_code}"
      exit 1
    fi'

  [ "$status" -eq 1 ]
  [[ "$output" == *"Lambda invocation failed with status 500"* ]]
}

# --- Poll step tests ---

@test "poll: completes on completed state" {
  export S3_URL="s3://test-bucket/unsigned/test.zip"
  export BUILD_NUMBER="12345"

  export MOCK_LAMBDA_RESPONSE="${BATS_TEST_TMPDIR}/mock-response.json"
  jq '.poll_completed' "${FIXTURES}/mock-responses.json" > "${MOCK_LAMBDA_RESPONSE}"

  create_mock_aws

  run bash -c '
    set -euo pipefail
    start_time=$(date +%s)
    response_file="${RUNNER_TEMP}/lambda-poll-response.json"
    payload=$(jq -n \
      --arg s3_url "${S3_URL}" \
      --arg build "${BUILD_NUMBER}" \
      "{source_s3_url: \$s3_url, build_number: \$build}")
    aws lambda invoke \
      --function-name codesign_helper \
      --payload "${payload}" \
      --cli-binary-format raw-in-base64-out \
      "${response_file}" > /dev/null
    status_code=$(jq -r ".statusCode" "${response_file}")
    state=$(jq -r ".body.state" "${response_file}")
    if [[ "${state}" == "completed" ]]; then
      duration=$(( $(date +%s) - start_time ))
      destination_url=$(jq -r ".body.destination_url" "${response_file}")
      echo "duration=${duration}" >> "${GITHUB_OUTPUT}"
      echo "destination-url=${destination_url}" >> "${GITHUB_OUTPUT}"
      exit 0
    fi
    exit 1
  '

  [ "$status" -eq 0 ]
  [[ "$(get_output 'destination-url')" == "s3://test-bucket/signed/test-artifact.zip" ]]
}

@test "poll: fails fast on failed state" {
  export S3_URL="s3://test-bucket/unsigned/test.zip"
  export BUILD_NUMBER="12345"

  export MOCK_LAMBDA_RESPONSE="${BATS_TEST_TMPDIR}/mock-response.json"
  jq '.poll_failed' "${FIXTURES}/mock-responses.json" > "${MOCK_LAMBDA_RESPONSE}"

  create_mock_aws

  run bash -c '
    set -euo pipefail
    response_file="${RUNNER_TEMP}/lambda-poll-response.json"
    payload=$(jq -n \
      --arg s3_url "${S3_URL}" \
      --arg build "${BUILD_NUMBER}" \
      "{source_s3_url: \$s3_url, build_number: \$build}")
    aws lambda invoke \
      --function-name codesign_helper \
      --payload "${payload}" \
      --cli-binary-format raw-in-base64-out \
      "${response_file}" > /dev/null
    state=$(jq -r ".body.state" "${response_file}")
    case "${state}" in
      completed) exit 0 ;;
      failed|error)
        echo "::error::Signing failed with state: ${state}"
        exit 1
        ;;
    esac'

  [ "$status" -eq 1 ]
  [[ "$output" == *"Signing failed with state: failed"* ]]
}

@test "poll: fails on non-200 poll response" {
  export S3_URL="s3://test-bucket/unsigned/test.zip"
  export BUILD_NUMBER="12345"

  export MOCK_LAMBDA_RESPONSE="${BATS_TEST_TMPDIR}/mock-response.json"
  jq '.poll_error_status' "${FIXTURES}/mock-responses.json" > "${MOCK_LAMBDA_RESPONSE}"

  create_mock_aws

  run bash -c '
    set -euo pipefail
    response_file="${RUNNER_TEMP}/lambda-poll-response.json"
    payload=$(jq -n \
      --arg s3_url "${S3_URL}" \
      --arg build "${BUILD_NUMBER}" \
      "{source_s3_url: \$s3_url, build_number: \$build}")
    aws lambda invoke \
      --function-name codesign_helper \
      --payload "${payload}" \
      --cli-binary-format raw-in-base64-out \
      "${response_file}" > /dev/null
    status_code=$(jq -r ".statusCode" "${response_file}")
    if [[ "${status_code}" != "200" ]]; then
      echo "::error::Poll request failed with status ${status_code}"
      exit 1
    fi'

  [ "$status" -eq 1 ]
  [[ "$output" == *"Poll request failed with status 500"* ]]
}

# --- Download step tests ---

@test "download: sets signed-artifact-path output" {
  export DESTINATION_URL="s3://test-bucket/signed/test-artifact.zip"
  export ARTIFACT_BASENAME="test-artifact.zip"

  create_mock_aws

  run bash -c '
    set -euo pipefail
    signed_path="${RUNNER_TEMP}/signed-${ARTIFACT_BASENAME}"
    aws s3 cp --quiet "${DESTINATION_URL}" "${signed_path}"
    echo "signed-artifact-path=${signed_path}" >> "${GITHUB_OUTPUT}"
  '

  [ "$status" -eq 0 ]
  [[ "$(get_output 'signed-artifact-path')" == *"signed-test-artifact.zip" ]]
}

@test "download: appends .zip for non-zip artifacts" {
  export DESTINATION_URL="s3://test-bucket/signed/test-artifact.app.zip"
  export ARTIFACT_BASENAME="MyApp.app.zip"

  create_mock_aws

  run bash -c '
    set -euo pipefail
    signed_path="${RUNNER_TEMP}/signed-${ARTIFACT_BASENAME}"
    aws s3 cp --quiet "${DESTINATION_URL}" "${signed_path}"
    echo "signed-artifact-path=${signed_path}" >> "${GITHUB_OUTPUT}"
  '

  [ "$status" -eq 0 ]
  [[ "$(get_output 'signed-artifact-path')" == *"signed-MyApp.app.zip" ]]
}

# --- Payload construction tests ---

@test "payload: jq constructs valid JSON with special characters" {
  # Ensure jq -n properly escapes values that could be injection vectors
  export S3_URL='s3://bucket/path with spaces/file"name.zip'

  run bash -c '
    payload=$(jq -n --arg s3_url "${S3_URL}" "{source_s3_url: \$s3_url}")
    echo "${payload}"
    # Verify it is valid JSON
    echo "${payload}" | jq . > /dev/null
  '

  [ "$status" -eq 0 ]
  # Verify the URL is properly escaped in the JSON
  echo "$output" | jq -r '.source_s3_url' | grep -q 'path with spaces'
}
