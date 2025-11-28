#!/usr/bin/env bash
# Clone and rotate all API keys in a GCP project, preserving restrictions.
# Requires: gcloud (logged in), curl, jq.

set -euo pipefail

if ! command -v gcloud >/dev/null 2>&1; then
  echo "gcloud is required" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required" >&2
  exit 1
fi

: "${PROJECT_ID:?Set PROJECT_ID (e.g., export PROJECT_ID=my-project-id)}"

timestamp="$(date +%Y%m%d-%H%M%S)"
out_file="${OUT_FILE:-rotated_api_keys_${timestamp}.txt}"

project_number="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
token="$(gcloud auth print-access-token)"
api_base="https://apikeys.googleapis.com/v2"
parent="projects/${PROJECT_ID}/locations/global"
base="${api_base}/${parent}/keys"
operations_base="${api_base}"
max_attempts=30
sleep_seconds=1

echo "Project: ${PROJECT_ID} (${project_number})"

auth_header=(-H "Authorization: Bearer ${token}")

curl_json() {
  local url="$1"
  shift
  local out http_code body

  if ! out="$(curl -sS "$@" -w $'\n%{http_code}' "${url}")"; then
    echo "curl failed for ${url}" >&2
    return 1
  fi

  http_code="${out##*$'\n'}"
  body="${out%$'\n'"${http_code}"}"

  if [[ "${http_code}" != 2* ]]; then
    echo "Request ${url} failed (${http_code}): ${body}" >&2
    return 1
  fi

  printf '%s' "${body}"
}

keys_json="$(curl_json "${base}" "${auth_header[@]}")"
key_names="$(echo "${keys_json}" | jq -r '.keys[]?.name')"

if [[ -z "${key_names}" ]]; then
  echo "No API keys found to rotate."
  exit 0
fi

: > "${out_file}"

poll_for_key_string() {
  local op_name="$1"
  local attempt=1
  local op_path="${op_name#${api_base}/}"
  op_path="${op_path#/}"

  while (( attempt <= max_attempts )); do
    op="$(curl_json "${operations_base}/${op_path}" "${auth_header[@]}")"
    if [[ "$(echo "${op}" | jq -r '.done')" == "true" ]]; then
      local ks name
      ks="$(echo "${op}" | jq -r '.response.keyString // empty')"
      name="$(echo "${op}" | jq -r '.response.name // empty')"
      if [[ -z "${ks}" ]]; then
        echo "Operation ${op_name} finished without keyString" >&2
        return 1
      fi
      echo "${ks}|${name}"
      return 0
    fi
    sleep "${sleep_seconds}"
    attempt=$((attempt + 1))
  done

  echo "Operation ${op_name} did not complete after ${max_attempts} attempts" >&2
  return 1
}

for key_name in ${key_names}; do
  key_id="${key_name##*/}"
  echo "Cloning ${key_id}..."

  key_detail="$(curl_json "${api_base}/${key_name}" "${auth_header[@]}")"
  display_name="$(echo "${key_detail}" | jq -r '.displayName')"
  restrictions="$(echo "${key_detail}" | jq '.restrictions // {}')"

  suffix="-rot-${timestamp}"
  max_len=63
  avail=$((max_len - ${#suffix}))
  if (( avail <= 0 )); then
    echo "Suffix too long (${suffix}); aborting" >&2
    exit 1
  fi
  if (( ${#display_name} > avail )); then
    new_display="${display_name:0:${avail}}${suffix}"
  else
    new_display="${display_name}${suffix}"
  fi

  create_body="$(jq -nc --arg dn "${new_display}" --argjson r "${restrictions}" '{displayName:$dn, restrictions:$r}')"
  new_key="$(curl_json "${base}" "${auth_header[@]}" -X POST -H "Content-Type: application/json" -d "${create_body}")"

  key_string="$(echo "${new_key}" | jq -r '.keyString // empty')"
  new_name="$(echo "${new_key}" | jq -r '.name // empty')"

  if [[ -z "${key_string}" && "${new_name}" == operations/* ]]; then
    echo "Waiting for ${new_name}..."
    if result="$(poll_for_key_string "${new_name}")"; then
      key_string="${result%%|*}"
      new_name="${result#*|}"
    else
      echo "Failed to retrieve key string for ${display_name}" >&2
      exit 1
    fi
  fi

  if [[ -z "${key_string}" ]]; then
    echo "Failed to create key for ${display_name}" >&2
    exit 1
  fi

  echo "${display_name} -> ${key_string} (${new_name})" | tee -a "${out_file}"
done

echo "New key strings saved to ${out_file} (keep it local and delete after updating configs)."
echo "Validate clients with new keys, then delete the old keys manually to avoid breaking traffic."
