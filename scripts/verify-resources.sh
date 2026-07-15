#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOURCE_DIR="${RESOURCE_DIR:-/resources}"
MANIFEST="${RESOURCE_MANIFEST:-${REPO_ROOT}/ansible/resources.sha256}"
EXCEPTIONS="${RESOURCE_EXCEPTIONS:-${REPO_ROOT}/ansible/resources-checksum-exceptions.txt}"

for command in awk sha256sum sort; do
  command -v "${command}" >/dev/null 2>&1 || {
    echo "Error: required command is missing: ${command}" >&2
    exit 1
  }
done

[[ -d "${RESOURCE_DIR}" ]] || {
  echo "Error: resource directory does not exist: ${RESOURCE_DIR}" >&2
  exit 1
}
[[ -r "${MANIFEST}" ]] || {
  echo "Error: checksum manifest is not readable: ${MANIFEST}" >&2
  exit 1
}
[[ -r "${EXCEPTIONS}" ]] || {
  echo "Error: checksum exception file is not readable: ${EXCEPTIONS}" >&2
  exit 1
}

mapfile -t manifest_files < <(
  awk '/^[0-9a-f]{64} [ *]/ { print substr($0, 67) }' "${MANIFEST}" | sort -u
)
if ! awk -F'|' '
  /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
  NF != 2 || $1 == "" || $2 == "" { exit 1 }
' "${EXCEPTIONS}"; then
  echo "Error: malformed checksum exception entry; expected filename|reason." >&2
  exit 1
fi
mapfile -t exception_files < <(
  awk -F'|' '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    NF != 2 || $1 == "" || $2 == "" { exit 2 }
    { print $1 }
  ' "${EXCEPTIONS}" | sort -u
)

contains() {
  local candidate="$1"
  shift
  local item
  for item in "$@"; do
    [[ "${candidate}" == "${item}" ]] && return 0
  done
  return 1
}

failures=0
for filename in "${manifest_files[@]}"; do
  if [[ "${filename}" == */* || ! -f "${RESOURCE_DIR}/${filename}" ]]; then
    echo "FAIL: manifest entry is unsafe or missing: ${filename}" >&2
    failures=$((failures + 1))
  fi
done

for filename in "${exception_files[@]}"; do
  if [[ "${filename}" == */* || ! -f "${RESOURCE_DIR}/${filename}" ]]; then
    echo "FAIL: exception entry is unsafe or missing: ${filename}" >&2
    failures=$((failures + 1))
  elif contains "${filename}" "${manifest_files[@]}"; then
    echo "FAIL: ${filename} is both checksummed and excepted." >&2
    failures=$((failures + 1))
  else
    echo "EXCEPTION: ${filename}"
  fi
done

while IFS= read -r filename; do
  case "${filename}" in
    *.sha256|cicd-artifacts.sha256)
      continue
      ;;
  esac
  if ! contains "${filename}" "${manifest_files[@]}" && ! contains "${filename}" "${exception_files[@]}"; then
    echo "FAIL: unlisted resource artifact: ${filename}" >&2
    failures=$((failures + 1))
  fi
done < <(find "${RESOURCE_DIR}" -maxdepth 1 -type f -printf '%f\n' | sort)

if [[ ${failures} -ne 0 ]]; then
  echo "Resource inventory validation failed with ${failures} finding(s)." >&2
  exit 1
fi

(
  cd "${RESOURCE_DIR}"
  sha256sum --check --strict "${MANIFEST}"
)

echo "Resource integrity verification passed: ${#manifest_files[@]} checksummed, ${#exception_files[@]} explicit exception(s)."
