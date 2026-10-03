#!/usr/bin/env bash

# Requires git, jq, and curl

KEY_AVB=${KEY_AVB:-avb.key}
KEY_OTA=${KEY_OTA:-ota.key}
CERT_OTA=${CERT_OTA:-ota.crt}
# Or else, set these env vars
KEY_AVB_BASE64=${KEY_AVB_BASE64:-''}
KEY_OTA_BASE64=${KEY_OTA_BASE64:-''}
CERT_OTA_BASE64=${CERT_OTA_BASE64:-''}

# Set these env vars, or else these params will be queries interactively
# PASSPHRASE_AVB
# PASSPHRASE_OTA

# Enable debug output only after sensitive vars have been set, to reduce risk of leak
DEBUG=${DEBUG:-''}
if [[ -n "${DEBUG}" ]]; then set -x; fi

# Mandatory params
DEVICE_ID=${DEVICE_ID:-} # See here for device IDs https://grapheneos.org/releases
GITHUB_TOKEN=${GITHUB_TOKEN:-''}
GITHUB_REPO=${GITHUB_REPO:-''}

# Optional
# If you want an OTA patched with magisk, set the preinit for your device
MAGISK_PREINIT_DEVICE=${MAGISK_PREINIT_DEVICE:-}
# Skip creation of rootless OTA by setting to "true"
SKIP_ROOTLESS=${SKIP_ROOTLESS:-'false'}
# Skip creation of magisk OTA by setting to "true".
SKIP_MAGISK=${SKIP_MAGISK:-'false'}
# In addition to upstream magisk, an OTA can be patched with pixincreate's magisk fork,
# which contains patches that make zygisk work on GrapheneOS.
# https://github.com/pixincreate/Magisk
# Note that modules verifying magisk's signature won't work with this fork.
# Enable by setting to "false".
SKIP_PIXINCREATE=${SKIP_PIXINCREATE:-'true'}
# APatch patches the kernel in boot.img. It is kept as a separate flavor and is
# disabled by default until explicitly requested.
SKIP_APATCH=${SKIP_APATCH:-'true'}
# A RAM-booted KernelPatch image is not enough to establish that a flashed,
# verified image works. mustang remains blocked after both 0.13.3 and 0.13.9
# bootlooped when installed persistently. This escape hatch is intentionally
# not exposed by the GitHub workflows.
ALLOW_UNVERIFIED_APATCH=${ALLOW_UNVERIFIED_APATCH:-'false'}
# APatch OTAs are never published (no release assets, no OTA feed, test feed
# included) while the KernelPatch bootloop is unresolved. APatch can still be
# built with SKIP_RELEASE. This escape hatch is intentionally not exposed by
# the GitHub workflows.
ALLOW_APATCH_RELEASE=${ALLOW_APATCH_RELEASE:-'false'}
# https://grapheneos.org/releases#stable-channel
OTA_VERSION=${OTA_VERSION:-'latest'}

# It's recommended to pin magisk version in combination with AVB_ROOT_VERSION.
# Breaking changes in magisk might need to be adapted in new avbroot version
# Find latest magisk version here: https://github.com/topjohnwu/Magisk/releases, or:
# curl --fail -sL -I -o /dev/null -w '%{url_effective}' https://github.com/topjohnwu/Magisk/releases/latest | sed 's/.*\/tag\///;'
# renovate: datasource=github-releases packageName=topjohnwu/Magisk versioning=semver-coerced
DEFAULT_MAGISK_VERSION=v30.7
MAGISK_VERSION=${MAGISK_VERSION:-${DEFAULT_MAGISK_VERSION}}

# Pixincreate's fork publishes versions and APK names independently from upstream Magisk.
# renovate: datasource=github-releases packageName=pixincreate/Magisk versioning=loose
DEFAULT_PIXINCREATE_VERSION=v31.0-3
PIXINCREATE_VERSION=${PIXINCREATE_VERSION:-${DEFAULT_PIXINCREATE_VERSION}}
PIXINCREATE_APK_NAME=${PIXINCREATE_APK_NAME:-''}
PIXINCREATE_APK_PATH=''
PIXINCREATE_APK_URL=''
PIXINCREATE_APK_SHA256=''

# APatch and its matching KernelPatch tools are resolved from their official
# GitHub releases. "latest" always means the newest stable APatch release.
# renovate: datasource=github-releases packageName=bmax121/APatch versioning=loose
DEFAULT_APATCH_VERSION=11224
APATCH_VERSION=${APATCH_VERSION:-${DEFAULT_APATCH_VERSION}}
APATCH_MANAGER_URL=''
APATCH_MANAGER_SHA256=''
# Preinstall the official signed APatch manager APK into the OTA's system image
# (as a system app under /system/app) so it is present and root-capable on first
# boot. Set to 'false' to ship the OTA without it and install the APK by hand.
APATCH_PREINSTALL_MANAGER=${APATCH_PREINSTALL_MANAGER:-'true'}
# Embed the built KPM(s) into the patched boot so they auto-load at kernel init.
# Default off: on mustang an embedded KPM bootloops early (stuck at the Google
# logo, not fixable by disabling verity), and an embedded module is not
# reboot-recoverable. Build KPMs with the standalone APatch KPM build workflow
# and load them via the manager instead. Set to 'true' only to test embedding.
APATCH_EMBED_KPMS=${APATCH_EMBED_KPMS:-'false'}
# APatch 11224 pins KernelPatch 0.13.3, but that image does not boot on
# mustang. KernelPatch 0.13.9 has been verified with a nonpersistent
# `fastboot boot` test on mustang. Keep this independently pinned so Renovate
# can propose later KernelPatch releases without silently changing builds.
# renovate: datasource=github-releases packageName=bmax121/KernelPatch versioning=loose
DEFAULT_KERNELPATCH_VERSION=0.13.9
KERNELPATCH_VERSION=${KERNELPATCH_VERSION:-${DEFAULT_KERNELPATCH_VERSION}}
# Optional immutable source commit in KERNELPATCH_SOURCE_REPO. When set, kpimg
# and kptools are both built from this exact commit. This is intended for
# fixes not contained in the latest release.
KERNELPATCH_COMMIT=${KERNELPATCH_COMMIT:-''}
KERNELPATCH_DISPLAY_VERSION=''
KERNELPATCH_KPIMG_URL=''
KERNELPATCH_KPIMG_SHA256=''
KERNELPATCH_KPTOOLS_URL=''
KERNELPATCH_KPTOOLS_SHA256=''
APATCH_BOOT_IMAGE=''

# Fork of bmax121/KernelPatch carrying fixes not yet upstream.
KERNELPATCH_SOURCE_REPO=${KERNELPATCH_SOURCE_REPO:-'https://github.com/david568303/KernelPatch.git'}
KERNELPATCH_TOOLCHAIN_URL='https://armkeil.blob.core.windows.net/developer/Files/downloads/gnu/12.2.rel1/binrel/arm-gnu-toolchain-12.2.rel1-x86_64-aarch64-none-elf.tar.xz'
KERNELPATCH_TOOLCHAIN_SHA256='62d66e0ad7bd7f2a183d236ee301a5c73c737c886c7944aa4f39415aab528daf'
# fix/arm64-image-size in the fork: upstream a308d88 (GrapheneOS arm64
# inlined-kCFI fix #311, boot-image padding fix #316) plus:
# - kptools reserves the region KernelPatch copies its start image to, so the
#   bootloader cannot place the ramdisk/DTB there
# - cred offset scans stay inside the slab object; GrapheneOS enables MTE with
#   kasan.fault=panic, and the out-of-bounds read was the mustang "Early
#   Kernel PANIC" (reproduced in QEMU with mte=on)
# - the official APatch manager (signed v1+v2+v3) is trusted again; upstream
#   accepted only a lone v2 signature, so root was always refused
MUSTANG_KERNELPATCH_TEST_COMMIT='9a9e876da4bde8047b234561120d46c5db19128e'

SKIP_CLEANUP=${SKIP_CLEANUP:-''}

# For committing to GH pages in different repo, clone it to a different folder and set this var
PAGES_REPO_FOLDER=${PAGES_REPO_FOLDER:-''}

# Set asset released by this script to latest version, even when OTA_VERSION already exists for this device
FORCE_OTA_SERVER_UPLOAD=${FORCE_OTA_SERVER_UPLOAD:-'false'}
# Forces the artifacts to be built (and uploaded to a release)
# even it a release already contains the combination of device and flavor.
# This will lead to multiple artifacts with different commits on the release (that are not linked in the OTA server and thus are likely never used).
# However, except for test builds, we want the changes to be rolled out with new version.
# So these artifacts are just a waste of storage resources. Example
# shiba-2025020500-3e0add9-rootless.zip
# shiba-2025020500-6718632-rootless.zip
FORCE_BUILD=${FORCE_BUILD:-'false'}
# Skip setting asset released by this script to latest version, even when OTA_VERSION is latest for this device
# Takes precedence over FORCE_OTA_SERVER_UPLOAD
SKIP_OTA_SERVER_UPLOAD=${SKIP_OTA_SERVER_UPLOAD:-'false'}
# Skip patching modules (custota and oemunlockunboot) into OTA
SKIP_MODULES=${SKIP_MODULES:-'false'}
# Upload OTA to test folder on OTA server
UPLOAD_TEST_OTA=${UPLOAD_TEST_OTA:-false}

OTA_CHANNEL=${OTA_CHANNEL:-stable-security-preview} # Alternative: 'stable' or 'alpha'
NO_COLOR=${NO_COLOR:-''}
OTA_BASE_URL="https://releases.grapheneos.org"

# renovate: datasource=github-releases packageName=chenxiaolong/avbroot versioning=semver
AVB_ROOT_VERSION=3.34.1
# renovate: datasource=github-releases packageName=chenxiaolong/Custota versioning=semver-coerced
CUSTOTA_VERSION=6.6
# renovate: datasource=git-refs packageName=https://github.com/chenxiaolong/my-avbroot-setup currentValue=master
PATCH_PY_COMMIT=9161b3e13416790d7e6da21d9dac5a14bc724504
# renovate: datasource=docker packageName=python
PYTHON_VERSION=3.14.8-alpine
# renovate: datasource=github-releases packageName=chenxiaolong/OEMUnlockOnBoot versioning=semver-coerced
OEMUNLOCKONBOOT_VERSION=1.4
# renovate: datasource=github-releases packageName=chenxiaolong/afsr versioning=semver
AFSR_VERSION=2.0.0

CHENXIAOLONG_PK='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDOe6/tBnO7xZhAWXRj3ApUYgn+XZ0wnQiXM8B7tPgv4'
GIT_PUSH_RETRIES=10

set -o nounset -o pipefail -o errexit

declare -A POTENTIAL_ASSETS

function generateKeys() {
  downloadAvBroot
  # https://github.com/chenxiaolong/avbroot/tree/077a80f4ce7233b0e93d4a1477d09334af0da246#generating-keys
  # Generate the AVB and OTA signing keys.
  .tmp/avbroot key generate-key -o $KEY_AVB
  .tmp/avbroot key generate-key -o $KEY_OTA

  # Convert the public key portion of the AVB signing key to the AVB public key metadata format.
  # This is the format that the bootloader requires when setting the custom root of trust.
  .tmp/avbroot key extract-avb -k $KEY_AVB -o avb_pkmd.bin

  # Generate a self-signed certificate for the OTA signing key. This is used by recovery to verify OTA updates when sideloading.
  .tmp/avbroot key generate-cert -k $KEY_OTA -o $CERT_OTA

  echo Upload these to your CI server, if necessary.
  echo The script takes these values as env or file
  key2base64
}

function key2base64() {
  KEY_AVB_BASE64=$(base64 -w0 "$KEY_AVB") && echo "KEY_AVB_BASE64=$KEY_AVB_BASE64"
  KEY_OTA_BASE64=$(base64 -w0 "$KEY_OTA") && echo "KEY_OTA_BASE64=$KEY_OTA_BASE64"
  CERT_OTA_BASE64=$(base64 -w0 "$CERT_OTA") && echo "CERT_OTA_BASE64=$CERT_OTA_BASE64"
  export KEY_AVB_BASE64 KEY_OTA_BASE64 CERT_OTA_BASE64
}

function createAndReleaseRootedOta() {
  if [[ "$SKIP_APATCH" != 'true' && "$ALLOW_APATCH_RELEASE" != 'true' ]]; then
    printRed 'APatch OTAs are not published while the KernelPatch bootloop is unresolved.'
    printRed 'Set SKIP_APATCH=true to release the other flavors, or SKIP_RELEASE to build APatch without publishing.'
    exit 1
  fi

  createRootedOta
  releaseOta

  createOtaServerData
  uploadOtaServerData
}

function createRootedOta() {
  [[ "$SKIP_CLEANUP" != 'true' ]] && trap cleanup EXIT ERR

  findLatestVersion
  checkBuildNecessary
  downloadAndroidDependencies
  patchOTAs
}

function cleanup() {
  print "Cleaning up..."
  rm -rf .tmp
  unset KEY_AVB_BASE64 KEY_OTA_BASE64 CERT_OTA_BASE64
  print "Cleanup complete."
}

function checkBuildNecessary() {
  local currentCommit
  currentCommit=$(git rev-parse --short HEAD)
  POTENTIAL_ASSETS=()
    
  if [[ -n "$MAGISK_PREINIT_DEVICE" ]]; then
    if [[ "$SKIP_MAGISK" != 'true' ]]; then
      # e.g. oriole-2023121200-magisk-v26.4-4647f74-dirty.zip
      POTENTIAL_ASSETS['magisk']="${DEVICE_ID}-${OTA_VERSION}-${currentCommit}-magisk-${MAGISK_VERSION}$(createAssetSuffix).zip"
    else
      printGreen "SKIP_MAGISK set, not creating upstream magisk OTA"
    fi

    if [[ "$SKIP_PIXINCREATE" != 'true' ]]; then
      resolvePixincreateApk
      # e.g. oriole-2023121200-pixincreate-v31.0-3-4647f74-dirty.zip
      POTENTIAL_ASSETS['pixincreate']="${DEVICE_ID}-${OTA_VERSION}-${currentCommit}-pixincreate-${PIXINCREATE_VERSION}$(createAssetSuffix).zip"
    else
      printGreen "SKIP_PIXINCREATE set, not creating pixincreate OTA"
    fi
  else 
    printGreen "MAGISK_PREINIT_DEVICE not set for device, not creating magisk OTA"
  fi

  if [[ "$SKIP_APATCH" != 'true' ]]; then
    resolveAPatchRelease
    # e.g. mustang-2026092501-4647f74-apatch-11224-kp0.13.3-test.zip
    POTENTIAL_ASSETS['apatch']="${DEVICE_ID}-${OTA_VERSION}-${currentCommit}-apatch-${APATCH_VERSION}-kp${KERNELPATCH_DISPLAY_VERSION}$(createAssetSuffix).zip"
  else
    printGreen "SKIP_APATCH set, not creating APatch OTA"
  fi
  
  if [[ "$SKIP_ROOTLESS" != 'true' ]]; then
    POTENTIAL_ASSETS['rootless']="${DEVICE_ID}-${OTA_VERSION}-${currentCommit}-rootless$(createAssetSuffix).zip"
  else
    printGreen "SKIP_ROOTLESS set, not creating rootless OTA"
  fi

  RELEASE_ID=''
  local response

  if [[ -z "$GITHUB_REPO" ]]; then print "Env Var GITHUB_REPO not set, skipping check for existing release" && return; fi

  print "Potential release: ${OTA_VERSION}"

  local params=()
  local url="https://api.github.com/repos/${GITHUB_REPO}/releases"

  if [ -n "${GITHUB_TOKEN}" ]; then
    params+=("-H" "Authorization: token ${GITHUB_TOKEN}")
  fi

  params+=("-H" "Accept: application/vnd.github.v3+json")
  response=$(
    curl --fail -sL "${params[@]}" "${url}" |
      jq --arg release_tag "${OTA_VERSION}" '.[] | select(.tag_name == $release_tag) | {id, tag_name, name, published_at, assets}'
  )

  if [[ -n ${response} ]]; then
    RELEASE_ID=$(echo "${response}" | jq -r '.id')
    print "Release ${OTA_VERSION} exists. ID=$RELEASE_ID"
    
    for flavor in "${!POTENTIAL_ASSETS[@]}"; do
      local selectedAsset POTENTIAL_ASSET_NAME="${POTENTIAL_ASSETS[$flavor]}"
      print "Checking if asset exists ${POTENTIAL_ASSET_NAME}"
      
      # Save some storage by not building and uploading every new commit as asset
      selectedAsset=$(echo "${response}" | jq -r --arg assetPrefix "${DEVICE_ID}-${OTA_VERSION}" \
        '.assets[] | select(.name | startswith($assetPrefix)) | .name' \
          | grep "${flavor}" || true)
  
      if [[ -n "${selectedAsset}" ]] && [[ "$FORCE_BUILD" != 'true' ]] && [[ "$UPLOAD_TEST_OTA" != 'true' ]]; then
        printGreen "Skipping build of asset name '$POTENTIAL_ASSET_NAME'. Because this flavor already is released with a different commit." \
          "Set FORCE_BUILD or UPLOAD_TEST_OTA to force. Assets found on release: ${selectedAsset//$'\n'/ }"
        unset "POTENTIAL_ASSETS[$flavor]"
      else
        print "No asset found with name '$POTENTIAL_ASSET_NAME'."
      fi
    done
    
    if [ "${#POTENTIAL_ASSETS[@]}" -eq 0 ]; then
      printGreen "All potential assets already exist. Exiting"
      exit 0
    fi
  else
    print "Release ${OTA_VERSION} does not exist."
  fi
}

function checkMandatoryVariable() {
  for var_name in "$@"; do
    local var_value="${!var_name}"

    if [[ -z "$var_value" ]]; then
      printRed "Missing mandatory param $var_name"
      exit 1
    fi
  done
}

function createAssetSuffix() {
  local suffix=''
  if [[ "${SKIP_MODULES}" == 'true' ]]; then
    suffix+='-minimal'
  fi 
  if [[ "${UPLOAD_TEST_OTA}" == 'true' ]]; then
    suffix+='-test'
  fi
  if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
    suffix+='-dirty'
  fi
  echo "$suffix"
}

function downloadAndroidDependencies() {
  checkMandatoryVariable 'MAGISK_VERSION' 'OTA_TARGET'

  mkdir -p .tmp
  if ! ls ".tmp/magisk-$MAGISK_VERSION.apk" >/dev/null 2>&1 && [[ "${POTENTIAL_ASSETS['magisk']+isset}" ]]; then
    curl --fail -sLo ".tmp/magisk-$MAGISK_VERSION.apk" "https://github.com/topjohnwu/Magisk/releases/download/$MAGISK_VERSION/Magisk-$MAGISK_VERSION.apk"
  fi

  if [[ "${POTENTIAL_ASSETS['pixincreate']+isset}" ]]; then
    checkMandatoryVariable 'PIXINCREATE_VERSION'
    downloadPixincreateApk
  fi

  if [[ "${POTENTIAL_ASSETS['apatch']+isset}" ]]; then
    downloadAPatchDependencies
  fi

  if ! ls ".tmp/$OTA_TARGET.zip" >/dev/null 2>&1; then
    curl --fail -sLo ".tmp/$OTA_TARGET.zip" "$OTA_URL"
  fi
}

function findLatestVersion() {
  checkMandatoryVariable DEVICE_ID

  if [[ "$MAGISK_VERSION" == 'latest' ]]; then
    MAGISK_VERSION=$(curl --fail -sL -I -o /dev/null -w '%{url_effective}' https://github.com/topjohnwu/Magisk/releases/latest | sed 's/.*\/tag\///;')
  fi
  print "Magisk version: $MAGISK_VERSION"

  if [[ -n "$MAGISK_PREINIT_DEVICE" && "$SKIP_PIXINCREATE" != 'true' ]]; then
    resolvePixincreateRelease
    print "Pixincreate version: $PIXINCREATE_VERSION; APK: $PIXINCREATE_APK_NAME"
  fi

  if [[ "$SKIP_APATCH" != 'true' ]]; then
    resolveAPatchRelease
    print "APatch version: $APATCH_VERSION; KernelPatch version: $KERNELPATCH_DISPLAY_VERSION"
    print "Install the matching official APatch manager after flashing: $APATCH_MANAGER_URL"
  fi

  # Search for a new version grapheneos.
  # e.g. https://releases.grapheneos.org/shiba-stable

  if [[ "$OTA_VERSION" == 'latest' ]]; then
    OTA_VERSION=$(curl --fail -sL "$OTA_BASE_URL/$DEVICE_ID-$OTA_CHANNEL" | head -n1 | awk '{print $1;}')
  fi
  GRAPHENE_TYPE=${GRAPHENE_TYPE:-'ota_update'} # Other option: factory
  OTA_TARGET="$DEVICE_ID-$GRAPHENE_TYPE-$OTA_VERSION"
  OTA_URL="$OTA_BASE_URL/$OTA_TARGET.zip"
  # e.g.  shiba-ota_update-2023121200
  print "OTA target: $OTA_TARGET; OTA URL: $OTA_URL"
}

function downloadPixincreateApk() {
  resolvePixincreateApk
  local targetFile="$PIXINCREATE_APK_PATH"
  local downloadFile="$targetFile.download"

  if [[ -f "$targetFile" ]]; then
    if echo "$PIXINCREATE_APK_SHA256  $targetFile" | sha256sum --check --status; then
      return
    fi
    printRed "Cached pixincreate APK failed SHA-256 verification; downloading it again"
    rm -f "$targetFile"
  fi

  rm -f "$downloadFile"
  curl --fail --retry 3 -sLo "$downloadFile" "$PIXINCREATE_APK_URL"
  echo "$PIXINCREATE_APK_SHA256  $downloadFile" | sha256sum --check --status
  mv "$downloadFile" "$targetFile"
}

function githubApiGet() {
  local url="$1"
  local params=(--fail --retry 3 --retry-all-errors -sL \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28')

  if [[ -n "$GITHUB_TOKEN" ]]; then
    params+=(-H "Authorization: Bearer $GITHUB_TOKEN")
  fi

  curl "${params[@]}" "$url"
}

function resolvePixincreateRelease() {
  local endpoint releaseJson assetJson digest preferredApkName requestedApkName
  checkMandatoryVariable 'PIXINCREATE_VERSION'

  requestedApkName="$PIXINCREATE_APK_NAME"
  if [[ "$PIXINCREATE_VERSION" == 'latest' ]]; then
    endpoint='https://api.github.com/repos/pixincreate/Magisk/releases/latest'
  else
    validatePixincreateVersion
    endpoint="https://api.github.com/repos/pixincreate/Magisk/releases/tags/$PIXINCREATE_VERSION"
  fi

  releaseJson=$(githubApiGet "$endpoint")
  if [[ "$(jq -er '.draft' <<< "$releaseJson")" != 'false' ]]; then
    printRed "Refusing to use a draft pixincreate release"
    exit 1
  fi

  PIXINCREATE_VERSION=$(jq -er '.tag_name' <<< "$releaseJson")
  validatePixincreateVersion
  preferredApkName="Magisk-$PIXINCREATE_VERSION.apk"

  if [[ -n "$requestedApkName" ]]; then
    PIXINCREATE_APK_NAME="$requestedApkName"
    validatePixincreateApkName
    assetJson=$(jq -cer --arg name "$PIXINCREATE_APK_NAME" \
      '([.assets[] | select(.name == $name)] | first) // error("requested APK asset not found")' \
      <<< "$releaseJson")
  else
    assetJson=$(jq -cer --arg preferred "$preferredApkName" \
      '([.assets[] | select(.name == $preferred)] + [.assets[] | select(.name == "app-release.apk")] | first) // error("no supported APK asset found")' \
      <<< "$releaseJson")
    PIXINCREATE_APK_NAME=$(jq -er '.name' <<< "$assetJson")
    validatePixincreateApkName
  fi

  PIXINCREATE_APK_URL=$(jq -er '.browser_download_url' <<< "$assetJson")
  digest=$(jq -er '.digest' <<< "$assetJson")
  if [[ "$digest" != sha256:* ]]; then
    printRed "GitHub did not provide a SHA-256 digest for $PIXINCREATE_APK_NAME"
    exit 1
  fi
  PIXINCREATE_APK_SHA256=${digest#sha256:}
  if [[ ! "$PIXINCREATE_APK_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
    printRed "Invalid SHA-256 digest for $PIXINCREATE_APK_NAME"
    exit 1
  fi
}

function resolvePixincreateApk() {
  if [[ -z "$PIXINCREATE_APK_URL" || -z "$PIXINCREATE_APK_SHA256" || -z "$PIXINCREATE_APK_NAME" ]]; then
    resolvePixincreateRelease
  fi
  validatePixincreateVersion
  PIXINCREATE_APK_PATH=".tmp/pixincreate-$PIXINCREATE_VERSION-$PIXINCREATE_APK_NAME"
}

function validatePixincreateVersion() {
  if [[ ! "$PIXINCREATE_VERSION" =~ ^[A-Za-z0-9._+-]+$ ]]; then
    printRed "Invalid PIXINCREATE_VERSION: $PIXINCREATE_VERSION"
    exit 1
  fi
}

function validatePixincreateApkName() {
  if [[ "$PIXINCREATE_APK_NAME" == */* || "$PIXINCREATE_APK_NAME" == '.' || "$PIXINCREATE_APK_NAME" == '..' ]]; then
    printRed "PIXINCREATE_APK_NAME must be a release asset file name, not a path: $PIXINCREATE_APK_NAME"
    exit 1
  fi
}

function validateReleaseVersion() {
  local name="$1"
  local value="$2"
  if [[ ! "$value" =~ ^[A-Za-z0-9._+-]+$ ]]; then
    printRed "Invalid $name: $value"
    exit 1
  fi
}

function githubAssetMetadata() {
  local releaseJson="$1"
  local assetName="$2"
  local assetJson digest

  assetJson=$(jq -cer --arg name "$assetName" \
    '([.assets[] | select(.name == $name)] | first) // error("release asset not found: " + $name)' \
    <<< "$releaseJson")
  digest=$(jq -er '.digest' <<< "$assetJson")
  if [[ "$digest" != sha256:* || ! "${digest#sha256:}" =~ ^[0-9a-f]{64}$ ]]; then
    printRed "GitHub did not provide a valid SHA-256 digest for $assetName"
    exit 1
  fi

  jq -cn \
    --arg url "$(jq -er '.browser_download_url' <<< "$assetJson")" \
    --arg sha256 "${digest#sha256:}" \
    '{url: $url, sha256: $sha256}'
}

function resolveAPatchRelease() {
  local endpoint releaseJson managerJson source kernelPatchLine apatchKernelPatchVersion
  local kernelReleaseJson='' kpimgJson kptoolsJson

  if [[ -n "$APATCH_MANAGER_URL" && -n "$KERNELPATCH_KPIMG_URL" && -n "$KERNELPATCH_KPTOOLS_URL" ]]; then
    return
  fi

  if [[ "$APATCH_VERSION" == 'latest' ]]; then
    endpoint='https://api.github.com/repos/bmax121/APatch/releases/latest'
  else
    validateReleaseVersion 'APATCH_VERSION' "$APATCH_VERSION"
    endpoint="https://api.github.com/repos/bmax121/APatch/releases/tags/$APATCH_VERSION"
  fi

  releaseJson=$(githubApiGet "$endpoint")
  if [[ "$(jq -er '.draft' <<< "$releaseJson")" != 'false' || "$(jq -er '.prerelease' <<< "$releaseJson")" != 'false' ]]; then
    printRed "Refusing to use a draft or prerelease APatch release"
    exit 1
  fi

  APATCH_VERSION=$(jq -er '.tag_name' <<< "$releaseJson")
  validateReleaseVersion 'APATCH_VERSION' "$APATCH_VERSION"

  managerJson=$(jq -cer --arg prefix "APatch_${APATCH_VERSION}_" \
    '([.assets[] | select(.name | startswith($prefix)) | select(.name | endswith("-release-signed.apk"))] | first) // error("official signed APatch manager asset not found")' \
    <<< "$releaseJson")
  APATCH_MANAGER_URL=$(jq -er '.browser_download_url' <<< "$managerJson")
  APATCH_MANAGER_SHA256=$(jq -er '.digest' <<< "$managerJson")
  APATCH_MANAGER_SHA256=${APATCH_MANAGER_SHA256#sha256:}
  if [[ ! "$APATCH_MANAGER_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
    printRed "GitHub did not provide a valid SHA-256 digest for the APatch manager"
    exit 1
  fi

  source=$(curl --fail --retry 3 -sL \
    "https://raw.githubusercontent.com/bmax121/APatch/$APATCH_VERSION/build.gradle.kts")
  kernelPatchLine=$(grep -E 'project\.ext\.set\("kernelPatchVersion", "[A-Za-z0-9._+-]+"\)' <<< "$source" | head -n1)
  apatchKernelPatchVersion=$(sed -E 's/.*"kernelPatchVersion", "([A-Za-z0-9._+-]+)".*/\1/' <<< "$kernelPatchLine")
  validateReleaseVersion 'APATCH_KERNELPATCH_VERSION' "$apatchKernelPatchVersion"

  if [[ -z "$KERNELPATCH_VERSION" || "$KERNELPATCH_VERSION" == 'apatch' ]]; then
    KERNELPATCH_VERSION="$apatchKernelPatchVersion"
  elif [[ "$KERNELPATCH_VERSION" == 'latest' ]]; then
    kernelReleaseJson=$(githubApiGet \
      'https://api.github.com/repos/bmax121/KernelPatch/releases/latest')
    KERNELPATCH_VERSION=$(jq -er '.tag_name' <<< "$kernelReleaseJson")
  fi
  validateReleaseVersion 'KERNELPATCH_VERSION' "$KERNELPATCH_VERSION"

  if [[ -n "$KERNELPATCH_COMMIT" ]]; then
    if [[ ! "$KERNELPATCH_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
      printRed 'KERNELPATCH_COMMIT must be a full 40-character lowercase commit SHA.'
      exit 1
    fi
    KERNELPATCH_DISPLAY_VERSION="${KERNELPATCH_VERSION}-g${KERNELPATCH_COMMIT:0:7}"
  else
    KERNELPATCH_DISPLAY_VERSION="$KERNELPATCH_VERSION"
  fi

  if [[ -z "$kernelReleaseJson" ]]; then
    kernelReleaseJson=$(githubApiGet \
      "https://api.github.com/repos/bmax121/KernelPatch/releases/tags/$KERNELPATCH_VERSION")
  fi
  kpimgJson=$(githubAssetMetadata "$kernelReleaseJson" 'kpimg-android')
  kptoolsJson=$(githubAssetMetadata "$kernelReleaseJson" 'kptools-linux')
  KERNELPATCH_KPIMG_URL=$(jq -er '.url' <<< "$kpimgJson")
  KERNELPATCH_KPIMG_SHA256=$(jq -er '.sha256' <<< "$kpimgJson")
  KERNELPATCH_KPTOOLS_URL=$(jq -er '.url' <<< "$kptoolsJson")
  KERNELPATCH_KPTOOLS_SHA256=$(jq -er '.sha256' <<< "$kptoolsJson")
}

function downloadVerifiedFile() {
  local targetFile="$1"
  local url="$2"
  local sha256="$3"
  local downloadFile="${targetFile}.download"

  if [[ -f "$targetFile" ]] && echo "$sha256  $targetFile" | sha256sum --check --status; then
    return
  fi

  rm -f "$targetFile" "$downloadFile"
  curl --fail --retry 3 -sLo "$downloadFile" "$url"
  echo "$sha256  $downloadFile" | sha256sum --check --status
  mv "$downloadFile" "$targetFile"
}

function downloadAPatchDependencies() {
  resolveAPatchRelease

  if [[ -n "$KERNELPATCH_COMMIT" ]]; then
    buildPinnedKernelPatch
  else
    downloadVerifiedFile '.tmp/kptools-linux' "$KERNELPATCH_KPTOOLS_URL" "$KERNELPATCH_KPTOOLS_SHA256"
    chmod +x '.tmp/kptools-linux'
    downloadVerifiedFile '.tmp/kpimg-android' "$KERNELPATCH_KPIMG_URL" "$KERNELPATCH_KPIMG_SHA256"
  fi
}

# Checks out the pinned KernelPatch commit and extracts the pinned aarch64
# toolchain, both idempotent so repeated calls in one job reuse them. Sets
# KERNELPATCH_SOURCE_DIR and KERNELPATCH_COMPILE_PREFIX.
KERNELPATCH_SOURCE_DIR='.tmp/kernelpatch-source'
KERNELPATCH_COMPILE_PREFIX=''
function prepareKernelPatchSource() {
  local sourceDir="$KERNELPATCH_SOURCE_DIR"
  local toolchainArchive='.tmp/kernelpatch-aarch64-toolchain.tar.xz'
  local toolchainDir='.tmp/kernelpatch-toolchain'

  if [[ ! "$KERNELPATCH_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
    printRed 'KERNELPATCH_COMMIT must be a full 40-character commit SHA to build from source.'
    exit 1
  fi

  if [[ "$(git -C "$sourceDir" rev-parse HEAD 2>/dev/null)" != "$KERNELPATCH_COMMIT" ]]; then
    rm -rf "$sourceDir"
    git init -q "$sourceDir"
    git -C "$sourceDir" remote add origin "$KERNELPATCH_SOURCE_REPO"
    git -C "$sourceDir" fetch --depth 1 origin "$KERNELPATCH_COMMIT"
    git -C "$sourceDir" checkout -q --detach FETCH_HEAD
    if [[ "$(git -C "$sourceDir" rev-parse HEAD)" != "$KERNELPATCH_COMMIT" ]]; then
      printRed 'KernelPatch checkout did not resolve to the requested commit.'
      exit 1
    fi
  fi

  if [[ ! -x "$toolchainDir/bin/aarch64-none-elf-gcc" ]]; then
    downloadVerifiedFile "$toolchainArchive" "$KERNELPATCH_TOOLCHAIN_URL" "$KERNELPATCH_TOOLCHAIN_SHA256"
    rm -rf "$toolchainDir"
    mkdir -p "$toolchainDir"
    tar -xJf "$toolchainArchive" -C "$toolchainDir" --strip-components=1
  fi
  KERNELPATCH_COMPILE_PREFIX="$(pwd)/$toolchainDir/bin/aarch64-none-elf-"
}

function buildPinnedKernelPatch() {
  prepareKernelPatchSource
  local sourceDir="$KERNELPATCH_SOURCE_DIR"
  local compilerPrefix="$KERNELPATCH_COMPILE_PREFIX"

  make -C "$sourceDir/kernel" clean
  make -C "$sourceDir/kernel" hdr kpimg ANDROID=1 TARGET_COMPILE="$compilerPrefix"
  cp "$sourceDir/kernel/kpimg" '.tmp/kpimg-android'
  if [[ ! -s '.tmp/kpimg-android' ]]; then
    printRed 'Pinned KernelPatch build did not produce kpimg-android.'
    exit 1
  fi
  print "Built KernelPatch kpimg from commit $KERNELPATCH_COMMIT ($(sha256sum '.tmp/kpimg-android' | awk '{print $1}'))"

  # kptools must come from the same patched source: some fixes are in the
  # patch tool, not in kpimg.
  ANDROID=1 cmake -S "$sourceDir/tools" -B "$sourceDir/tools/build" -DCMAKE_BUILD_TYPE=Release
  ANDROID=1 cmake --build "$sourceDir/tools/build" -j "$(nproc)"
  cp "$sourceDir/tools/build/kptools" '.tmp/kptools-linux'
  chmod +x '.tmp/kptools-linux'
  print "Built KernelPatch kptools from commit $KERNELPATCH_COMMIT ($(sha256sum '.tmp/kptools-linux' | awk '{print $1}'))"
}

# Builds the APatch kernel modules (KPMs) under kernelpatch-modules/ against the
# pinned KernelPatch headers and toolchain, and collects the .kpm files. These
# are loaded at runtime via APatch (kpm load) after boot, so a faulty module is
# recoverable with a reboot; they are intentionally not embedded into kpimg.
KPM_SOURCE_DIR=${KPM_SOURCE_DIR:-'kernelpatch-modules'}
function buildAPatchKpm() {
  if [[ -z "$KERNELPATCH_COMMIT" && "$DEVICE_ID" == 'mustang' ]]; then
    KERNELPATCH_COMMIT="$MUSTANG_KERNELPATCH_TEST_COMMIT"
  fi
  mkdir -p .tmp
  prepareKernelPatchSource
  # generated headers (uapi copy etc.) the module tree may include
  make -C "$KERNELPATCH_SOURCE_DIR/kernel" hdr ANDROID=1 \
    TARGET_COMPILE="$KERNELPATCH_COMPILE_PREFIX" >/dev/null

  local outDir='.tmp/apatch-kpm'
  rm -rf "$outDir"
  mkdir -p "$outDir"

  local built=0 mod name
  for mod in "$KPM_SOURCE_DIR"/*/; do
    [[ -f "${mod}Makefile" ]] || continue
    name="$(basename "$mod")"
    make -C "$mod" clean >/dev/null 2>&1 || true
    make -C "$mod" KP_DIR="$(pwd)/$KERNELPATCH_SOURCE_DIR" \
      TARGET_COMPILE="$KERNELPATCH_COMPILE_PREFIX"
    if ! ls "$mod"*.kpm >/dev/null 2>&1; then
      printRed "KPM $name did not produce a .kpm"
      exit 1
    fi
    # fail closed if the module references anything KernelPatch does not export
    local undef
    undef=$("${KERNELPATCH_COMPILE_PREFIX}nm" -u "$mod"*.kpm | awk '{print $2}' |
      grep -vE '^(printk|hook_wrap|hook_wrap[0-9]|unhook|fp_hook|kallsyms_lookup_name|compat_copy_to_user|kfunc_def_|kvmalloc|kvfree|vmalloc|kfree|logkd|logke)$' || true)
    if [[ -n "$undef" ]]; then
      printRed "KPM $name has unresolved symbols not exported by KernelPatch:"
      printRed "$undef"
      exit 1
    fi
    cp "$mod"*.kpm "$outDir/"
    built=$((built + 1))
    print "Built KPM $name from KernelPatch $KERNELPATCH_COMMIT ($(sha256sum "$mod"*.kpm | awk '{print $1}'))"
  done

  if (( built == 0 )); then
    printRed "No KPMs found under $KPM_SOURCE_DIR/"
    exit 1
  fi
  (cd "$outDir" && sha256sum ./*.kpm > SHA256SUMS)
  printGreen "APatch KPM(s) in $outDir (load with APatch after boot: kpm load <file>)"
}

# Builds only the KernelPatch-patched boot.img for hardware testing, without
# signing keys, avbroot OTA patching or any release. Flash it with
# `fastboot flash boot` on stock GrapheneOS of the same OTA_VERSION with an
# unlocked bootloader.
function createAPatchTestBootImage() {
  SKIP_APATCH='false'
  APATCH_BOOT_TEST='true'
  if [[ -z "$KERNELPATCH_COMMIT" && "$DEVICE_ID" == 'mustang' ]]; then
    KERNELPATCH_COMMIT="$MUSTANG_KERNELPATCH_TEST_COMMIT"
  fi

  findLatestVersion
  mkdir -p .tmp
  downloadAPatchDependencies
  if ! ls ".tmp/$OTA_TARGET.zip" >/dev/null 2>&1; then
    curl --fail -sLo ".tmp/$OTA_TARGET.zip" "$OTA_URL"
  fi
  downloadAvBroot
  patchAPatchBootImage

  local outDir='.tmp/apatch-test'
  local name="${DEVICE_ID}-${OTA_VERSION}-apatch-boot-kp${KERNELPATCH_DISPLAY_VERSION}"
  local workDir=".tmp/apatch-${DEVICE_ID}-${OTA_VERSION}"
  mkdir -p "$outDir"
  cp "$APATCH_BOOT_IMAGE" "$outDir/$name.img"
  cp "$workDir/extracted/boot.img" "$outDir/${DEVICE_ID}-${OTA_VERSION}-stock-boot.img"
  cp "$workDir/kptools-patch.log" "$outDir/$name.log"
  (cd "$outDir" && sha256sum ./*.img > SHA256SUMS)
  printGreen "APatch test boot image: $outDir/$name.img"
}

# Builds the full APatch OTA the normal way (KernelPatch-patched boot.img fed
# to avbroot as a prepatched image, signed with the repo keys, patched=true
# re-verified), but produces a workflow artifact instead of a release and never
# touches the OTA feed. Install it the normal README way (extract, flashall,
# custom AVB key, sideload). Needs the signing secrets.
function createAPatchTestOta() {
  SKIP_CLEANUP='true' # keep .tmp so the artifact survives for upload
  SKIP_APATCH='false'
  SKIP_ROOTLESS='true'
  SKIP_MAGISK='true'
  SKIP_PIXINCREATE='true'
  FORCE_BUILD='true'      # always build, ignore any existing release asset
  APATCH_FULL_TEST='true' # artifact-only; allowed on mustang, never released/fed
  if [[ -z "$KERNELPATCH_COMMIT" && "$DEVICE_ID" == 'mustang' ]]; then
    KERNELPATCH_COMMIT="$MUSTANG_KERNELPATCH_TEST_COMMIT"
  fi

  createRootedOta

  local asset="${POTENTIAL_ASSETS['apatch']}"
  if [[ -z "$asset" || ! -s ".tmp/$asset" ]]; then
    printRed 'APatch test OTA was not produced.'
    exit 1
  fi
  # Prove the signed OTA matches the published avb_pkmd.bin (the custom AVB key
  # users flash and lock against). avbroot was fetched by patchOTAs.
  if [[ -f 'avb_pkmd.bin' ]]; then
    print "Verifying signed OTA against published avb_pkmd.bin"
    if ! .tmp/avbroot ota verify --input ".tmp/$asset" --public-key-avb 'avb_pkmd.bin'; then
      printRed 'Signed OTA does not verify against the published avb_pkmd.bin.'
      exit 1
    fi
    printGreen 'Signed OTA verifies against published avb_pkmd.bin'
  else
    printRed 'avb_pkmd.bin not found; cannot confirm the OTA matches the published AVB key.'
    exit 1
  fi

  local outDir='.tmp/apatch-test-ota'
  mkdir -p "$outDir"
  cp ".tmp/$asset" "$outDir/"
  (cd "$outDir" && sha256sum "$asset" > "$asset.sha256")
  writeApatchInstallScripts "$outDir" "$asset"
  printGreen "APatch test OTA (signed): $outDir/$asset"
  printGreen "To install, run flash-all.sh (Linux/macOS) or flash-all.bat (Windows) from $outDir."
}

# Writes a self-contained installer (flash-all.sh / flash-all.bat) plus this
# repo's custom AVB public key next to the OTA. The installer flashes the OTA
# the correct way (dynamic partitions via fastbootd, which `fastboot flashall`
# enters on its own) and then registers our avb_pkmd.bin. It deliberately does
# not sideload, which is unreliable as a first install on some devices.
function writeApatchInstallScripts() {
  local outDir="$1" otaName="$2"

  cp 'avb_pkmd.bin' "$outDir/avb_pkmd.bin"

  cat > "$outDir/flash-all.sh" <<'EOF'
#!/usr/bin/env bash
# Auto-generated installer for the rooted (APatch) GrapheneOS OTA.
#
# Dynamic partitions (system, product, vendor, ...) live in `super` and must be
# written through fastbootd, which `fastboot flashall` enters automatically.
# This then registers this repo's custom AVB key. Do NOT `adb sideload` as a
# first install; that fails with kPostInstallMountError on some devices.
#
# Requires `avbroot` and a recent `fastboot` on PATH, the device in bootloader
# (fastboot) mode with the bootloader unlocked. Run from this folder.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"
OTA='__OTA__'

echo "==> Extracting partition images from $OTA"
avbroot ota extract --input "$OTA" --directory extracted --fastboot
export ANDROID_PRODUCT_OUT="$here/extracted"

echo "==> Flashing (reboots into fastbootd automatically)"
fastboot flashall --skip-reboot

echo "==> Registering custom AVB key"
fastboot reboot-bootloader
fastboot erase avb_custom_key
fastboot flash avb_custom_key avb_pkmd.bin

echo "==> Done. Rebooting."
fastboot reboot
EOF
  chmod +x "$outDir/flash-all.sh"

  cat > "$outDir/flash-all.bat" <<'EOF'
@echo off
REM Auto-generated installer for the rooted (APatch) GrapheneOS OTA.
REM Requires avbroot and a recent fastboot on PATH, device in bootloader mode,
REM bootloader unlocked. Run from this folder. Do NOT adb sideload as a first
REM install.
setlocal enableextensions
cd /d "%~dp0"
set "OTA=__OTA__"

echo ==^> Extracting partition images from %OTA%
avbroot ota extract --input "%OTA%" --directory extracted --fastboot || goto :err
set "ANDROID_PRODUCT_OUT=%cd%\extracted"

echo ==^> Flashing (reboots into fastbootd automatically)
fastboot flashall --skip-reboot || goto :err

echo ==^> Registering custom AVB key
fastboot reboot-bootloader || goto :err
fastboot erase avb_custom_key || goto :err
fastboot flash avb_custom_key avb_pkmd.bin || goto :err

echo ==^> Done. Rebooting.
fastboot reboot
goto :eof

:err
echo Flashing FAILED. See the output above.
exit /b 1
EOF

  sed -i "s/__OTA__/${otaName}/g" "$outDir/flash-all.sh" "$outDir/flash-all.bat"
  print "Wrote flash-all.sh and flash-all.bat (with repo avb_pkmd.bin) to $outDir"
}

function patchAPatchBootImage() {
  local workDir=".tmp/apatch-${DEVICE_ID}-${OTA_VERSION}"
  local extractedDir="$workDir/extracted"

  if [[ "$DEVICE_ID" == 'mustang' && "$ALLOW_UNVERIFIED_APATCH" != 'true' && "${APATCH_BOOT_TEST:-}" != 'true' && "${APATCH_FULL_TEST:-}" != 'true' ]]; then
    if [[ "$UPLOAD_TEST_OTA" != 'true' || "$KERNELPATCH_COMMIT" != "$MUSTANG_KERNELPATCH_TEST_COMMIT" ]]; then
      printRed 'APatch production builds are blocked for mustang: released KernelPatch 0.13.3 and 0.13.9 bootloop.'
      printRed 'Only the pinned post-0.13.9 candidate may be published to the isolated test feed before hardware validation.'
      exit 1
    fi
  fi

  APATCH_BOOT_IMAGE="$workDir/new-boot.img"
  if [[ -f "$APATCH_BOOT_IMAGE" ]]; then
    printGreen "File $APATCH_BOOT_IMAGE already exists locally, not patching it again."
    return
  fi

  rm -rf "$workDir"
  mkdir -p "$workDir"
  .tmp/avbroot ota extract \
    --input ".tmp/$OTA_TARGET.zip" \
    --directory "$extractedDir" \
    --partition boot

  cp '.tmp/kptools-linux' "$workDir/kptools"
  cp '.tmp/kpimg-android' "$workDir/kpimg"

  # Embed the APatch kernel modules into the patched boot image so they load
  # automatically during kernel init (production path), instead of requiring a
  # manual `kpm load` after every boot. The modules are built from the same
  # pinned KernelPatch source as kpimg, so their ABI matches. Set
  # APATCH_EMBED_KPMS=false to leave them out and load them by hand instead.
  # Note: an embedded KPM runs on every boot, so a faulty one is no longer
  # reboot-recoverable; the nm gate in buildAPatchKpm guards against that.
  local -a embedArgs=()
  if [[ "$APATCH_EMBED_KPMS" == 'true' ]]; then
    if [[ -z "$KERNELPATCH_COMMIT" ]]; then
      # Embedding needs KPMs built from the same pinned source as kpimg so their
      # ABI matches. The released-kpimg path has no source commit, so skip it
      # (load KPMs by hand there) rather than embed an ABI-mismatched module.
      print 'APATCH_EMBED_KPMS: no pinned KERNELPATCH_COMMIT, skipping KPM embed; load KPMs manually instead.'
    else
      buildAPatchKpm
      mkdir -p "$workDir/kpms"
      local kpm
      for kpm in .tmp/apatch-kpm/*.kpm; do
        [[ -e "$kpm" ]] || continue
        cp "$kpm" "$workDir/kpms/"
        embedArgs+=(-M "kpms/$(basename "$kpm")" -T kpm)
        print "Embedding KPM $(basename "$kpm") into the boot image (auto-loads at boot)."
      done
      if [[ ${#embedArgs[@]} -eq 0 ]]; then
        printRed 'APATCH_EMBED_KPMS=true but no .kpm modules were built to embed.'
        exit 1
      fi
    fi
  fi

  (
    cd "$workDir"
    ./kptools unpack 'extracted/boot.img'

    if ! ./kptools -i kernel -f | grep -q 'CONFIG_KALLSYMS=y'; then
      printRed 'APatch requires CONFIG_KALLSYMS=y, but it was not found in the boot kernel.'
      exit 1
    fi

    mv kernel kernel.ori
    # Omitting -S uses APatch 11219+'s signature-authorized manager mode. This
    # avoids putting a reusable, root-equivalent SuperKey into CI or the image.
    # Each -M/-T pair embeds a KPM (EXTRA_TYPE_KPM) that KernelPatch loads at boot.
    ./kptools -p -i kernel.ori -k kpimg "${embedArgs[@]}" -o kernel 2>&1 | tee kptools-patch.log

    # KernelPatch can exit successfully and mark an image as patched even when
    # it failed to locate the arm64 relocation table. Such an image is not
    # bootable (observed on the Android 17 Pixel kernel used by mustang). Do not
    # let a syntactically patched but known-bad image reach a release.
    if grep -Eqi \
      "can'?t find arm64 relocation table|arm64 relocation kernel_va: 0xffffffffffffffff" \
      kptools-patch.log; then
      printRed 'Warning: KernelPatch could not resolve the arm64 relocation table and used its relative-base kallsyms path.'
    fi

    # memblock_alloc_try_nid changed from a three-argument physical allocator
    # to a five-argument virtual allocator in Linux 4.20. KernelPatch 0.13.3
    # can select it as the physical fallback and then call it through the old
    # prototype, which is an early-boot ABI violation (KernelPatch #300/#303).
    if grep -Fq 'use memblock_alloc_try_nid as map phys alloc' kptools-patch.log; then
      printRed 'KernelPatch selected the ABI-ambiguous memblock_alloc_try_nid physical fallback; refusing to publish the image.'
      exit 1
    fi

    ./kptools repack 'extracted/boot.img'

    if [[ ! -s new-boot.img ]]; then
      printRed 'APatch did not produce new-boot.img'
      exit 1
    fi
  )
}

function verifyAPatchOta() {
  local otaFile="$1"
  local verifyDir=".tmp/apatch-verify-${DEVICE_ID}-${OTA_VERSION}"

  rm -rf "$verifyDir"
  mkdir -p "$verifyDir"
  .tmp/avbroot ota extract \
    --input "$otaFile" \
    --directory "$verifyDir/extracted" \
    --partition boot
  cp '.tmp/kptools-linux' "$verifyDir/kptools"

  (
    cd "$verifyDir"
    ./kptools unpack 'extracted/boot.img'
    if ! ./kptools -i kernel -l | grep -q 'patched=true'; then
      printRed 'Final OTA verification failed: boot kernel is not patched with KernelPatch.'
      exit 1
    fi
  )

  printGreen "Verified APatch in final OTA boot image: $otaFile"
}

function downloadAvBroot() {
  downloadAndVerifyFromChenxiaolong 'avbroot' "$AVB_ROOT_VERSION"
}

function downloadAndVerifyFromChenxiaolong() {
  local repo="$1"
  local version="$2"
  local artifact="${3:-$1}" # optional: If not set, use repo name
  
  local url="https://github.com/chenxiaolong/${repo}/releases/download/v${version}/${artifact}-${version}-x86_64-unknown-linux-gnu.zip"
  local downloadedZipFile
  downloadedZipFile="$(mktemp)"
  
  mkdir -p .tmp

  if ! ls ".tmp/${artifact}" >/dev/null 2>&1; then
    curl --fail -sL "${url}" > "${downloadedZipFile}"
    curl --fail -sL "${url}.sig" > "${downloadedZipFile}.sig"
    
    # Validate against author's public key
    ssh-keygen -Y verify -I chenxiaolong -f <(echo "chenxiaolong $CHENXIAOLONG_PK") -n file \
      -s "${downloadedZipFile}.sig" < "${downloadedZipFile}"
    
    echo N | unzip "${downloadedZipFile}" -d .tmp
    rm "${downloadedZipFile}"*
    chmod +x ".tmp/${artifact}" # e.g. .tmp/custota-tool
  fi
}

# Downloads the official signed APatch manager APK (verified by the SHA-256
# digest GitHub publishes) and registers our system-app injection module into
# the pinned my-avbroot-setup clone so patch.py can preinstall it. The clone is
# pinned by PATCH_PY_COMMIT, so the all_modules() text is stable; registration
# is grep-guarded to stay idempotent across re-runs.
function installApatchManagerModule() {
  resolveAPatchRelease
  checkMandatoryVariable 'APATCH_MANAGER_URL' 'APATCH_MANAGER_SHA256'
  downloadVerifiedFile '.tmp/apatch-manager.apk' "$APATCH_MANAGER_URL" "$APATCH_MANAGER_SHA256"

  local modulesDir='.tmp/my-avbroot-setup/lib/modules'
  if [[ ! -d "$modulesDir" ]]; then
    printRed "my-avbroot-setup modules dir not found at $modulesDir"
    exit 1
  fi
  cp 'patch-modules/apatch_manager.py' "$modulesDir/apatch_manager.py"
  if ! grep -q 'APatchManagerModule' "$modulesDir/__init__.py"; then
    sed -i \
      -e '/from lib.modules.oemunlockonboot import OEMUnlockOnBootModule/a\    from lib.modules.apatch_manager import APatchManagerModule' \
      -e '/^        OEMUnlockOnBootModule,$/a\        APatchManagerModule,' \
      "$modulesDir/__init__.py"
    if ! grep -q 'APatchManagerModule' "$modulesDir/__init__.py"; then
      printRed 'Failed to register APatch manager module in my-avbroot-setup all_modules().'
      exit 1
    fi
  fi
  print "Preinstalling APatch manager $APATCH_VERSION into the OTA system image."
}

function patchOTAs() {

  downloadAvBroot
  downloadAndVerifyFromChenxiaolong 'afsr' "$AFSR_VERSION"
  if ! ls ".tmp/custota.zip" >/dev/null 2>&1; then
    curl --fail -sL "https://github.com/chenxiaolong/Custota/releases/download/v${CUSTOTA_VERSION}/Custota-${CUSTOTA_VERSION}-release.zip" > .tmp/custota.zip
    curl --fail -sL "https://github.com/chenxiaolong/Custota/releases/download/v${CUSTOTA_VERSION}/Custota-${CUSTOTA_VERSION}-release.zip.sig" > .tmp/custota.zip.sig
  fi
  if ! ls ".tmp/oemunlockonboot.zip" >/dev/null 2>&1; then
    curl --fail -sL "https://github.com/chenxiaolong/OEMUnlockOnBoot/releases/download/v${OEMUNLOCKONBOOT_VERSION}/OEMUnlockOnBoot-${OEMUNLOCKONBOOT_VERSION}-release.zip" > .tmp/oemunlockonboot.zip
    curl --fail -sL "https://github.com/chenxiaolong/OEMUnlockOnBoot/releases/download/v${OEMUNLOCKONBOOT_VERSION}/OEMUnlockOnBoot-${OEMUNLOCKONBOOT_VERSION}-release.zip.sig" > .tmp/oemunlockonboot.zip.sig
  fi
  if ! ls ".tmp/my-avbroot-setup" >/dev/null 2>&1; then
    git clone https://github.com/chenxiaolong/my-avbroot-setup .tmp/my-avbroot-setup
    (cd .tmp/my-avbroot-setup && git checkout ${PATCH_PY_COMMIT})
  fi

  base642key

  if [[ "${POTENTIAL_ASSETS['apatch']+isset}" ]]; then
    patchAPatchBootImage
    if [[ "$APATCH_PREINSTALL_MANAGER" == 'true' ]]; then
      installApatchManagerModule
    fi
  fi

  for flavor in "${!POTENTIAL_ASSETS[@]}"; do
    local targetFile=".tmp/${POTENTIAL_ASSETS[$flavor]}"

    if ls "$targetFile" >/dev/null 2>&1; then
      printGreen "File $targetFile already exists locally, not patching."
    else
      local args=()
      local dockerEnvArgs=()

      args+=("--output" "$targetFile")
      args+=("--input" ".tmp/$OTA_TARGET.zip")
      args+=("--sign-key-avb" "$KEY_AVB")
      args+=("--sign-key-ota" "$KEY_OTA")
      args+=("--sign-cert-ota" "$CERT_OTA")
      if [[ "$flavor" == 'magisk' ]]; then
        args+=("--patch-arg=--magisk" "--patch-arg" ".tmp/magisk-$MAGISK_VERSION.apk")
        args+=("--patch-arg=--magisk-preinit-device" "--patch-arg" "$MAGISK_PREINIT_DEVICE")
      fi
      if [[ "$flavor" == 'pixincreate' ]]; then
        resolvePixincreateApk
        args+=("--patch-arg=--magisk" "--patch-arg" "$PIXINCREATE_APK_PATH")
        args+=("--patch-arg=--magisk-preinit-device" "--patch-arg" "$MAGISK_PREINIT_DEVICE")
      fi
      if [[ "$flavor" == 'apatch' ]]; then
        args+=("--patch-arg=--prepatched" "--patch-arg" "$APATCH_BOOT_IMAGE")
        if [[ "$APATCH_PREINSTALL_MANAGER" == 'true' ]]; then
          args+=("--module-apatch-manager" ".tmp/apatch-manager.apk")
        fi
      fi

      # If env vars not set, passphrases will be queried interactively
      if [ -v PASSPHRASE_AVB ]; then
        args+=("--pass-avb-env-var" "PASSPHRASE_AVB")
        export PASSPHRASE_AVB
        dockerEnvArgs+=("--env" "PASSPHRASE_AVB")
      fi

      if [ -v PASSPHRASE_OTA ]; then
        args+=("--pass-ota-env-var" "PASSPHRASE_OTA")
        export PASSPHRASE_OTA
        dockerEnvArgs+=("--env" "PASSPHRASE_OTA")
      fi

      if [[ "${SKIP_MODULES}" != 'true' ]]; then
        args+=("--module-custota" ".tmp/custota.zip")
        args+=("--module-oemunlockonboot" ".tmp/oemunlockonboot.zip")
      fi
      # We create csig and device JSON for OTA later if necessary
      args+=("--skip-custota-tool")

      # We need to add .tmp to PATH, but we can't use $PATH: because this would be the PATH of the host not the container
      # Python image is designed to run as root, so chown the files it creates back at the end
      # ... room for improvement 😐️
      # shellcheck disable=SC2046
      docker run --rm -i $(tty &>/dev/null && echo '-t') \
    -v "$PWD:/app" \
    -w /app \
    -e PATH='/bin:/usr/local/bin:/sbin:/usr/bin:/app/.tmp' \
    "${dockerEnvArgs[@]}" \
    python:${PYTHON_VERSION} sh -c "set -e && \
        apk add --no-cache openssh uv && \
        uv sync --locked --project .tmp/my-avbroot-setup && \
        uv run --project .tmp/my-avbroot-setup \
            .tmp/my-avbroot-setup/patch.py ${args[*]} && \
        chown -R $(id -u):$(id -g) .tmp"

      if [[ "$flavor" == 'apatch' ]]; then
        verifyAPatchOta "$targetFile"
      fi

      printGreen "Finished patching file ${targetFile}"
    fi
    
  done
}

function base642key() {
  set +x # Don't expose secrets to log
  if [ -n "$KEY_AVB_BASE64" ]; then
    echo "$KEY_AVB_BASE64" | base64 -d >.tmp/$KEY_AVB
    KEY_AVB=.tmp/$KEY_AVB
  fi

  if [ -n "$KEY_OTA_BASE64" ]; then
    echo "$KEY_OTA_BASE64" | base64 -d >.tmp/$KEY_OTA
    KEY_OTA=.tmp/$KEY_OTA
  fi

  if [ -n "$CERT_OTA_BASE64" ]; then
    echo "$CERT_OTA_BASE64" | base64 -d >.tmp/$CERT_OTA
    CERT_OTA=.tmp/$CERT_OTA
  fi

  if [[ -n "${DEBUG}" ]]; then set -x; fi
}

function releaseOta() {

  createReleaseIfNecessary
  
  for flavor in "${!POTENTIAL_ASSETS[@]}"; do
    local assetName="${POTENTIAL_ASSETS[$flavor]}"
    uploadFile ".tmp/$assetName" "$assetName" "application/zip"
  done
}

function createReleaseIfNecessary() {
  checkMandatoryVariable 'GITHUB_REPO' 'GITHUB_TOKEN'

  local response changelog src_repo current_commit 

  if [[ -z "$RELEASE_ID" ]]; then
    src_repo=$(extractGithubRepo "$(git config --get remote.origin.url)")

    # Security-preview releases end in suffix 01,but anchor links on release page always end in 00
    # e.g. 25092501 -> 25092500
    OTA_VERSION_ANCHOR="${OTA_VERSION/%01/00}"
    if [[ "${GITHUB_REPO}" == "${src_repo}" ]]; then
      changelog=$(curl -sL -X POST -H "Authorization: token $GITHUB_TOKEN" \
        -d "{
                \"tag_name\": \"$OTA_VERSION\",
                \"target_commitish\": \"main\"
              }" \
        "https://api.github.com/repos/$GITHUB_REPO/releases/generate-notes" | jq -r '.body // empty')
      # Replace \n by \\n to keep them as chars
      changelog="Update to [GrapheneOS ${OTA_VERSION}](https://grapheneos.org/releases#${OTA_VERSION_ANCHOR}).\n\n$(echo "${changelog}" | sed ':a;N;$!ba;s/\n/\\n/g')"
    else 
      # When pushing to different repo's GH pages, generating notes does not make too much sense. Refer to the used repo's "version" instead. 
      current_commit=$(git rev-parse --short HEAD)
      changelog="Update to [GrapheneOS ${OTA_VERSION}](https://grapheneos.org/releases#${OTA_VERSION_ANCHOR}).\n\nRelease created using ${src_repo}@${current_commit}. See [Changelog](https://github.com/${src_repo}/blob/${current_commit}/README.md#notable-changelog)."
    fi
    
    response=$(curl -sL -X POST -H "Authorization: token $GITHUB_TOKEN" \
      -d "{
              \"tag_name\": \"$OTA_VERSION\",
              \"target_commitish\": \"main\",
              \"name\": \"$OTA_VERSION\",
              \"body\": \"${changelog}\"
            }" \
      "https://api.github.com/repos/$GITHUB_REPO/releases")
    RELEASE_ID=$(echo "${response}" | jq -r '.id // empty')
    if [[ -n "${RELEASE_ID}" ]]; then
      printGreen "Release created successfully with ID: ${RELEASE_ID}"
    elif echo "${response}" | jq -e '.status == "422"' > /dev/null; then
      # In case release has been created in the meantime (e.g. matrix job for multiple devices concurrently)
      RELEASE_ID=$(curl -sL \
        -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
            "https://api.github.com/repos/${GITHUB_REPO}/releases" | \
            jq -r --arg release_tag "${OTA_VERSION}" '.[] | select(.tag_name == $release_tag) | .id // empty')
      if [[ -n "${RELEASE_ID}" ]]; then
        printGreen "Cannot create release but found existing release for ${OTA_VERSION}. ID=$RELEASE_ID"
      else
        printRed "Cannot create release for ${OTA_VERSION} because it seems to exist but still cannot find ID."
        exit 1
      fi
    else
      errors=$(echo "${response}" | jq -r '.errors')
      printRed "Failed to create release for ${OTA_VERSION}. Errors: ${errors}"
      exit 1
    fi
  fi
}

function uploadFile() {
  local sourceFileName="$1"
  local targetFileName="$2"
  local contentType="$3"

  # Note that --data-binary might lead to out of memory
  curl --fail -X POST -H "Authorization: token $GITHUB_TOKEN" \
    -H "Content-Type: $contentType" \
    --upload-file "$sourceFileName" \
    "https://uploads.github.com/repos/$GITHUB_REPO/releases/$RELEASE_ID/assets?name=$targetFileName"
}

function createOtaServerData() {
  downloadCusotaTool

  for flavor in "${!POTENTIAL_ASSETS[@]}"; do
    local POTENTIAL_ASSET_NAME="${POTENTIAL_ASSETS[$flavor]}"
    local targetFile=".tmp/${POTENTIAL_ASSET_NAME}"
    
    local args=()
  
    args+=("--input" "${targetFile}")
    args+=("--output" "${targetFile}.csig")
    args+=("--key" "$KEY_OTA")
    args+=("--cert" "$CERT_OTA")
  
    # If env vars not set, passphrases will be queried interactively
    if [ -v PASSPHRASE_OTA ]; then
      args+=("--passphrase-env-var" "PASSPHRASE_OTA")
    fi
  
    .tmp/custota-tool gen-csig "${args[@]}"
  
    mkdir -p ".tmp/${flavor}"
    
    local args=()
    args+=("--file" ".tmp/${flavor}/${DEVICE_ID}.json")
    # e.g. https://github.com/schnatterer/rooted-graphene/releases/download/2023121200-v26.4-e54c67f/oriole-ota_update-2023121200.zip
    # Instead of constructing the location we could also parse it from the upload response
    args+=("--location" "https://github.com/$GITHUB_REPO/releases/download/$OTA_VERSION/$POTENTIAL_ASSET_NAME")
  
    .tmp/custota-tool gen-update-info "${args[@]}"
  done
}

function downloadCusotaTool() {
  downloadAndVerifyFromChenxiaolong 'Custota' "$CUSTOTA_VERSION" 'custota-tool'
}

function uploadOtaServerData() {

  # Update OTA server (github pages)
  local current_branch current_commit base_dir src_repo
  current_commit=$(git rev-parse --short HEAD)
  folderPrefix=''
  
  if [[ "${UPLOAD_TEST_OTA}" == 'true' ]]; then
    folderPrefix='test/'
  fi

  (
    base_dir="$(pwd)"
    src_repo=$(extractGithubRepo "$(git config --get remote.origin.url)")
    if [[ -n "${PAGES_REPO_FOLDER}" ]]; then
      cd "${PAGES_REPO_FOLDER}"
    fi
    
    current_branch=$(git rev-parse --abbrev-ref HEAD)
    git checkout gh-pages
    
    for flavor in "${!POTENTIAL_ASSETS[@]}"; do
      local POTENTIAL_ASSET_NAME="${POTENTIAL_ASSETS[$flavor]}"
      local targetFile="${folderPrefix}${flavor}/${DEVICE_ID}.json"
  
      uploadFile "${base_dir}/.tmp/${POTENTIAL_ASSET_NAME}.csig" "$POTENTIAL_ASSET_NAME.csig" "application/octet-stream"
      
      mkdir -p "${folderPrefix}${flavor}"
      # update only, if current $DEVICE_ID.json does not contain $OTA_VERSION
      # We don't want to trigger users to upgrade on new commits from this repo or new magisk versions
      # They can manually upgrade by downloading the OTAs from the releases and "adb sideload" them
      if ! grep -q "$OTA_VERSION" "${targetFile}" || [[ "$FORCE_OTA_SERVER_UPLOAD" == 'true' ]] && [[ "$SKIP_OTA_SERVER_UPLOAD" != 'true' ]]; then
        cp "${base_dir}/.tmp/${flavor}/$DEVICE_ID.json" "${targetFile}"
        git add "${targetFile}"
      elif grep -q "${OTA_VERSION}" "${targetFile}"; then
        printGreen "Skipping update of OTA server, because ${OTA_VERSION} already in ${folderPrefix}${flavor}/${DEVICE_ID}.json and FORCE_OTA_SERVER_UPLOAD is false."
      else
        printGreen "Skipping update of OTA server, because SKIP_OTA_SERVER_UPLOAD is true."
      fi
    done
    
    if ! git diff-index --quiet HEAD; then
      # Commit and push only when there are changes
      git config user.name "GitHub Actions" && git config user.email "actions@github.com"
      git commit \
          --message "Update device ${DEVICE_ID} basing on ${src_repo}@${current_commit}" \
    
      gitPushWithRetries
    fi
  
    # Switch back to the original branch
    git checkout "$current_branch"
  )
}

extractGithubRepo() {
  # Works for both HTTPS and SSH, e.g.
  # https://github.com/schnatterer/rooted-graphene
  # git@github.com:schnatterer/rooted-graphene.git

  local remote_url="$1"
  local repo

  # Remove the protocol and .git suffix
  remote_url=$(echo "$remote_url" | sed -e 's/.*:\/\/\|.*@//' -e 's/\.git$//')

  # Extract the owner/repo part
  repo=$(echo "$remote_url" | sed -e 's/.*[:\/]\([^\/]*\/[^\/]*\)$/\1/')

  echo "$repo"
}

function gitPushWithRetries() {
  local count=0

  while [ $count -lt $GIT_PUSH_RETRIES ]; do
    git pull --rebase
    if git push origin gh-pages; then
      break
    else
      count=$((count + 1))
      printGreen "Retry $count/$GIT_PUSH_RETRIES failed. Retrying..."
      sleep 2
    fi
  done
  
  if [ $count -eq $GIT_PUSH_RETRIES ]; then
    printRed "Failed to push to gh-pages after $GIT_PUSH_RETRIES attempts."
    exit 1
  fi
}

function print() {
  echo -e "$(date '+%Y-%m-%d %H:%M:%S'): $*"
}

function printGreen() {
  if [[ -z "${NO_COLOR}" ]]; then
    echo -e "\e[32m$(date '+%Y-%m-%d %H:%M:%S'): $*\e[0m"
  else
      print "$@"
  fi
}

function printRed() {
  if [[ -z "${NO_COLOR}" ]]; then
   echo -e "\e[31m$(date '+%Y-%m-%d %H:%M:%S'): $*\e[0m"
  else
      print "$@"
  fi
}
