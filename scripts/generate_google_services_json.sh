#!/usr/bin/env bash
# Generate android/app/google-services.json from rotate_api_keys output.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/generate_google_services_json.sh <rotated_keys_file>

Reads the output file from scripts/rotate_api_keys.sh, grabs the latest Android
API key, and writes android/app/google-services.json (or OUTPUT_PATH).

Env vars:
  ROTATED_KEYS_FILE         Path to rotated keys file (if not passed as arg)
  GOOGLE_SERVICES_TEMPLATE  Base JSON to update (default: existing google-services.json, else .example)
  OUTPUT_PATH               Output path (default: android/app/google-services.json)
  API_KEY                   Override API key instead of parsing the rotated file
  PROJECT_NUMBER            Optional override for project_info.project_number
  PROJECT_ID                Optional override for project_info.project_id
  STORAGE_BUCKET            Optional override for project_info.storage_bucket
  MOBILESDK_APP_ID          Optional override for client[].client_info.mobilesdk_app_id
  PACKAGE_NAME              Optional override for client[].client_info.android_client_info.package_name
  CONFIG_VERSION            Optional override for configuration_version
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 1
fi

keys_file="${1:-${ROTATED_KEYS_FILE:-}}"
if [[ -z "${keys_file}" ]]; then
  usage >&2
  exit 1
fi

if [[ ! -f "${keys_file}" ]]; then
  echo "Keys file not found: ${keys_file}" >&2
  exit 1
fi

template="${GOOGLE_SERVICES_TEMPLATE:-}"
if [[ -z "${template}" ]]; then
  if [[ -f "android/app/google-services.json" ]]; then
    template="android/app/google-services.json"
  else
    template="android/app/google-services.json.example"
  fi
fi

if [[ ! -f "${template}" ]]; then
  echo "Template not found: ${template}" >&2
  exit 1
fi

output="${OUTPUT_PATH:-android/app/google-services.json}"

if [[ -n "${API_KEY:-}" ]]; then
  api_key="${API_KEY}"
else
  android_line="$(grep -E '^Android key' "${keys_file}" | tail -n 1 || true)"
  if [[ -z "${android_line}" ]]; then
    echo "No Android key line found in ${keys_file}" >&2
    exit 1
  fi
  api_key="$(printf '%s' "${android_line}" | sed -E 's/.* -> ([A-Za-z0-9_-]+).*/\1/')"
  if [[ -z "${api_key}" ]]; then
    echo "Failed to parse API key from line: ${android_line}" >&2
    exit 1
  fi
fi

jq_args=(--arg key "${api_key}")
jq_filter='if (.client | length == 0) then error("client array missing in template") else . end'
jq_filter+=' | .client = (.client | map(.api_key = [ { current_key: $key } ]))'

if [[ -n "${PROJECT_NUMBER:-}" ]]; then
  jq_args+=(--arg project_number "${PROJECT_NUMBER}")
  jq_filter+=' | .project_info.project_number = $project_number'
fi

if [[ -n "${PROJECT_ID:-}" ]]; then
  jq_args+=(--arg project_id "${PROJECT_ID}")
  jq_filter+=' | .project_info.project_id = $project_id'
fi

if [[ -n "${STORAGE_BUCKET:-}" ]]; then
  jq_args+=(--arg storage_bucket "${STORAGE_BUCKET}")
  jq_filter+=' | .project_info.storage_bucket = $storage_bucket'
fi

if [[ -n "${MOBILESDK_APP_ID:-}" ]]; then
  jq_args+=(--arg app_id "${MOBILESDK_APP_ID}")
  jq_filter+=' | .client = (.client | map(.client_info.mobilesdk_app_id = $app_id))'
fi

if [[ -n "${PACKAGE_NAME:-}" ]]; then
  jq_args+=(--arg package_name "${PACKAGE_NAME}")
  jq_filter+=' | .client = (.client | map(.client_info.android_client_info.package_name = $package_name))'
fi

if [[ -n "${CONFIG_VERSION:-}" ]]; then
  jq_args+=(--arg config_version "${CONFIG_VERSION}")
  jq_filter+=' | .configuration_version = $config_version'
fi

new_json="$(jq --indent 2 "${jq_args[@]}" "${jq_filter}" "${template}")"

placeholder_fields=()
check_placeholder() {
  local jq_path="$1"
  local label="$2"
  if jq -e -r "${jq_path} | select(type==\"string\" and startswith(\"YOUR_\"))" <<<"${new_json}" >/dev/null; then
    placeholder_fields+=("${label}")
  fi
}

check_placeholder '.project_info.project_number' 'project_number'
check_placeholder '.project_info.project_id' 'project_id'
check_placeholder '.project_info.storage_bucket' 'storage_bucket'
check_placeholder '.client[0].client_info.mobilesdk_app_id' 'mobilesdk_app_id'
check_placeholder '.client[0].client_info.android_client_info.package_name' 'package_name'

if (( ${#placeholder_fields[@]} > 0 )); then
  echo "Refusing to write ${output}; template still has placeholder values: ${placeholder_fields[*]}" >&2
  echo "Provide real values via env vars (PROJECT_NUMBER, PROJECT_ID, etc.) or point GOOGLE_SERVICES_TEMPLATE at a valid config." >&2
  exit 1
fi

mkdir -p "$(dirname "${output}")"
printf '%s\n' "${new_json}" > "${output}"

echo "Updated ${output} using Android API key from ${keys_file} and template ${template}."
