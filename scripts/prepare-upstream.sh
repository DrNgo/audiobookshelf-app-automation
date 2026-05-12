#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
upstream_directory="${repository_root}/upstream"
upstream_version_file="${repository_root}/.upstream-version"
upstream_repository_url="${UPSTREAM_REPOSITORY_URL:-https://github.com/advplyr/audiobookshelf-app.git}"

if [[ ! -f "${upstream_version_file}" ]]; then
  echo "error: ${upstream_version_file} not found" >&2
  exit 1
fi

upstream_tag="$(tr -d '[:space:]' < "${upstream_version_file}")"
if [[ -z "${upstream_tag}" ]]; then
  echo "error: ${upstream_version_file} is empty" >&2
  exit 1
fi

echo "==> cloning ${upstream_repository_url} at ${upstream_tag}"
rm -rf "${upstream_directory}"
git clone --depth 1 --branch "${upstream_tag}" "${upstream_repository_url}" "${upstream_directory}"

echo "==> installing npm dependencies"
(cd "${upstream_directory}" && npm ci)

echo "==> generating Nuxt web bundle"
(cd "${upstream_directory}" && npm run generate)

echo "==> syncing Capacitor iOS project"
(cd "${upstream_directory}" && npx cap sync ios)

echo "==> running pod install"
(cd "${upstream_directory}/ios/App" && pod install)

echo "==> upstream ready at ${upstream_directory}"
