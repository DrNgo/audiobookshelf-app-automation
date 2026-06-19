#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
upstream_directory="${repository_root}/upstream"
upstream_version_file="${repository_root}/.upstream-version"
upstream_repository_url="${UPSTREAM_REPOSITORY_URL:-https://github.com/advplyr/audiobookshelf-app.git}"

read_upstream_tag() {
  if [[ ! -f "${upstream_version_file}" ]]; then
    echo "error: ${upstream_version_file} not found" >&2
    exit 1
  fi
  local upstream_tag
  upstream_tag="$(tr -d '[:space:]' < "${upstream_version_file}")"
  if [[ -z "${upstream_tag}" ]]; then
    echo "error: ${upstream_version_file} is empty" >&2
    exit 1
  fi
  printf '%s' "${upstream_tag}"
}

clone_upstream() {
  local upstream_tag
  upstream_tag="$(read_upstream_tag)"
  echo "==> cloning ${upstream_repository_url} at ${upstream_tag}"
  rm -rf "${upstream_directory}"
  git clone --depth 1 --branch "${upstream_tag}" "${upstream_repository_url}" "${upstream_directory}"
}

build_web_bundle() {
  echo "==> installing npm dependencies"
  (cd "${upstream_directory}" && npm ci)

  echo "==> generating Nuxt web bundle"
  (cd "${upstream_directory}" && npm run generate)

  echo "==> syncing Capacitor iOS project"
  (cd "${upstream_directory}" && npx cap sync ios)
}

mark_encryption_exempt() {
  local info_plist_path="${upstream_directory}/ios/App/App/Info.plist"
  if [[ ! -f "${info_plist_path}" ]]; then
    echo "error: ${info_plist_path} not found" >&2
    exit 1
  fi

  echo "==> declaring ITSAppUsesNonExemptEncryption=false so testflight skips the export compliance prompt"
  plutil -remove ITSAppUsesNonExemptEncryption "${info_plist_path}" 2>/dev/null || true
  plutil -insert ITSAppUsesNonExemptEncryption -bool NO "${info_plist_path}"
}

prepare_ios_pods() {
  local podfile="${upstream_directory}/ios/App/Podfile"
  local anchor="assertDeploymentTarget(installer)"
  local marker="# audiobookshelf-app: pin pod deployment target"

  if [[ ! -f "${podfile}" ]]; then
    echo "error: ${podfile} not found" >&2
    exit 1
  fi

  echo "==> pinning pod deployment target so xcode 26 doesn't bake the sdk version into swiftmodules"

  if grep -qF "${marker}" "${podfile}"; then
    echo "==> deployment-target pin already present; skipping injection"
  else
    # Fail loudly rather than silently no-op if upstream changed the Podfile —
    # otherwise pod install runs without the pin and the build fails later with
    # a confusing code-signing/swiftmodule error instead of a clear cause.
    if ! grep -qF "${anchor}" "${podfile}"; then
      echo "error: anchor '${anchor}' not found in ${podfile}." >&2
      echo "       Upstream changed its Podfile; update the deployment-target pin in scripts/prepare-upstream.sh." >&2
      exit 1
    fi

    ruby -i -pe '
      if $_.include?("assertDeploymentTarget(installer)")
        $_ << "  # audiobookshelf-app: pin pod deployment target\n"
        $_ << "  installer.pods_project.targets.each do |target|\n"
        $_ << "    target.build_configurations.each do |config|\n"
        $_ << "      config.build_settings[\"IPHONEOS_DEPLOYMENT_TARGET\"] = \"14.0\"\n"
        $_ << "    end\n"
        $_ << "  end\n"
      end
    ' "${podfile}"

    if ! grep -qF "${marker}" "${podfile}"; then
      echo "error: failed to inject the deployment-target pin into ${podfile}" >&2
      exit 1
    fi
  fi

  echo "==> running pod install"
  (cd "${upstream_directory}/ios/App" && pod install)
}

phase="${1:-all}"
case "${phase}" in
  clone) clone_upstream ;;
  web)   build_web_bundle ;;
  ios)
    mark_encryption_exempt
    prepare_ios_pods
    ;;
  all)
    clone_upstream
    build_web_bundle
    mark_encryption_exempt
    prepare_ios_pods
    ;;
  *)
    echo "unknown phase: ${phase} (valid: clone, web, ios, all)" >&2
    exit 1
    ;;
esac

echo "==> upstream ready at ${upstream_directory}"
