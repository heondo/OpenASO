#!/bin/sh

set -eu

template_path="${PROJECT_DIR}/OpenASO/Resources/OpenASORefreshAgent.plist.template"
output_directory="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Library/LaunchAgents"
output_path="${output_directory}/${PRODUCT_BUNDLE_IDENTIFIER}.refresh-agent.plist"

mkdir -p "${output_directory}"
sed \
  -e "s|@BUNDLE_IDENTIFIER@|${PRODUCT_BUNDLE_IDENTIFIER}|g" \
  -e "s|@EXECUTABLE_NAME@|${EXECUTABLE_NAME}|g" \
  "${template_path}" > "${output_path}"

plutil -lint "${output_path}"

expected_label="${PRODUCT_BUNDLE_IDENTIFIER}.refresh-agent"
expected_bundle_program="Contents/MacOS/${EXECUTABLE_NAME}"
executable_path="${TARGET_BUILD_DIR}/${EXECUTABLE_PATH}"

actual_label="$(plutil -extract Label raw -o - "${output_path}")"
actual_bundle_program="$(plutil -extract BundleProgram raw -o - "${output_path}")"
argument_zero="$(plutil -extract ProgramArguments.0 raw -o - "${output_path}")"
argument_one="$(plutil -extract ProgramArguments.1 raw -o - "${output_path}")"

test "${actual_label}" = "${expected_label}"
test "${actual_bundle_program}" = "${expected_bundle_program}"
test -f "${executable_path}"
test -x "${executable_path}"
test "${argument_zero}" = "${EXECUTABLE_NAME}"
test "${argument_one}" = "--daily-refresh-once"

if plutil -extract ProgramArguments.2 raw -o - "${output_path}" >/dev/null 2>&1; then
  echo "Refresh agent must contain exactly one --daily-refresh-once argument" >&2
  exit 1
fi
