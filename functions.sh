#!/bin/bash

put() {
  printf "%s" "$1" 1>&2
}

puts() {
  printf "%s\n" "${1:-}" 1>&2
}

green() {
  echo -e "\033[32;1m$1\033[0m"
}

red() {
  echo -e "\033[31;1m$1\033[0m"
}

make_repo() {
  set -eu # unset variables are errors & non-zero return values exit the whole script

  setup_logging

  if [ ! -d "$TOOLS" ]; then
    $SDK_MANAGER "build-tools;29.0.2"
  fi
  puts "generating fdroid repo"
  url="http://localhost"
  yml="$OUT/index-v1.yml"
  json="$OUT/index-v1.json"
  jar="$OUT/index-v1.jar"
  now="$(date --utc +%s)000"
  yq n repo.name "Implant" >"$yml"
  write repo.timestamp "$now"
  write repo.version 18
  write repo.address "$url"
  write "repo.mirrors[+]" "$url"
  write repo.icon "default-repo-icon.png"
  write repo.description "Implant"
  write requests.install "[]"
  write requests.uninstall "[]"
  readarray -t apks < <(ls "$OUT/"*.apk)
  num_apks="${#apks[@]}"
  for i in "${!apks[@]}"; do
    apk="${apks[$i]}"
    puts "adding ($((i+1))/$num_apks) $apk"
    package=$(get_apk_package "$apk")
    version=$(get_apk_version_code "$apk")
    CONFIG="$METADATA/$package.yml"
    write "apps[+].name" "$(get_config name 2>/dev/null)"
    write_app suggestedVersionCode "$version"
    write_app license Unknown
    write_app packageName "$package"
    write_app icon ""
    write_app added "$now"
    write_app lastUpdated "$now"
    write "packages.[$package].[+].apkName" "$(basename "$apk")"
    write_package packageName "$package"
    write_package versionCode "$version"
    write_package versionName "$(get_version_name "$apk")"
    write_package minSdkVersion "$(get_min_sdk "$apk")"
    write_package targetSdkVersion "$(get_target_sdk "$apk")"
    write_package hash "$(sha256 "$apk")"
    write_package hashType "sha256"
    write_package added "$now"
    write_package sig "$(get_apk_sig "$apk")"
    write_package size "$(get_size "$apk")"
    # nativecode
    # uses-permission
    # uses-permission-sdk-23
  done
  yq r -j "$yml" >"$json"
  rm "$jar"
  zip -j "$jar" "$json"
  jarsigner -keystore "$KEYSTORE" -storepass:env KSPASS -digestalg SHA1 -sigalg SHA1withRSA "$jar" implant
}

write() {
  yq w -i "$yml" "$1" "$2"
}

write_app() {
  yq w -i "$yml" "apps[$i].$1" "$2"
}

write_package() {
  yq w -i "$yml" "packages.[$package].[0].$1" "$2"
}

get_size() {
  stat --printf="%s" "$1"
}

get_min_sdk() {
  $APKANALYZER manifest min-sdk "$1"
}

get_target_sdk() {
  $APKANALYZER manifest target-sdk "$1"
}

get_version_name() {
  $(find_build_tool aapt) dump badging "$1" | grep versionName | awk '{ print $4 }' | cut -d"'" -f2
}

get_apk_sig() {
  $(find_build_tool apksigner) verify --print-certs "$1" | grep SHA-256 | awk '{ print $NF }'
}

get_apk_package() {
  $APKANALYZER manifest application-id "$1"
}

get_latest_tag() {
  if [ -z "$GIT_TAGS" ]; then
    GIT_TAGS="[vV]?[0-9.-]+"
  fi
  LATEST_SHA=$GIT_SHA
  for tag in $(git tag --sort=-committerdate); do
    if ! [[ "$tag" =~ ^${GIT_TAGS}$ ]]; then
      puts "$tag does not match"
      continue
    fi
    SHA=$(git rev-parse --short=7 "$tag^{}")
    if git merge-base --is-ancestor "$SHA" "$LATEST_SHA"; then
      puts "$tag ($SHA) is ancestor of $LATEST_SHA"
      continue
    fi
    OLD_DATE=$(get_commit_date "$LATEST_SHA")
    NEW_DATE=$(get_commit_date "$SHA")
    if [ "$NEW_DATE" -lt "$OLD_DATE" ]; then
      puts "$tag ($SHA) is older than $LATEST_SHA"
      continue
    fi
    LATEST_SHA=$SHA
    puts "found newer tag $tag ($LATEST_SHA)"
  done
  echo "$LATEST_SHA"
}

get_apk_version_code() {
  $APKANALYZER manifest version-code "$1"
}

find_build_tool() {
  find "$TOOLS" -name "$1" | sort | tail -n 1
}

get_installed_packages() {
  PACKAGES=()
  for p in $(adb shell pm list package | awk -F'package:' '{ print $2 }' | sort); do
    if [ -f "$METADATA/$p.yml" ]; then
      PACKAGES+=("$p")
    fi
  done
}

up_to_date() {
  PACKAGE=$1
  CONFIG="$METADATA/$PACKAGE.yml"
  if [ "$INSTALL" -eq 0 ]; then
    if [ -f "$OUT/$PACKAGE-${VERSION:-}.apk" ]; then
      return 0
    fi
  else
    INSTALLED_VERSION=$(get_installed_version_code "$PACKAGE")
  fi
  LATEST_VERSION=$(get_config version 2>/dev/null)
  [ -n "${INSTALLED_VERSION:-}" ] && [ "$INSTALLED_VERSION" == "$LATEST_VERSION" ]
}

get_installed_version_code() {
  adb shell dumpsys package "$1" | grep versionCode | awk '{ print $1 }' | grep -o "[0-9]\+"
}

get_commit_date() {
  git show --no-patch --no-notes --pretty='%ct' "$1"
}

get_package() {
  filename=$(basename "$1")
  echo "${filename%.yml*}"
}

setup_logging() {
  if [ "$VERBOSE" -eq 1 ]; then
    exec > >(tee "$LOG") 2>&1
  else
    exec >>"$LOG" 2>&1
  fi
}

prebuild() {
  if [ -z "$PREBUILD" ]; then
    return 0
  fi
  puts "prebuild..."
  to_array "$PREBUILD"
  for step in "${array[@]}"; do
    puts "prebuild step: $step"
    if ! eval "$step"; then
      exit 1
    fi
  done
}

to_array() {
  IFS=$'\n'
  array=()
  for entry in $1; do
    array+=("$entry")
  done
}

build() {
  puts "building $PACKAGE..."
  if [ -z "$BUILD" ]; then
    TASK=assemble$FLAVOR$TARGET
    if [ -n "$PROJECT" ]; then
      TASK=$PROJECT:$TASK
    fi

    /bin/bash -c "$GRADLE --stacktrace $TASK"
  else
    eval "$BUILD"
  fi
  # shellcheck disable=SC2181
  if [ $? -ne 0 ]; then
    exit 1
  fi
}

setup_gradle_properties() {
  if [ -z "$GRADLEPROPS" ]; then
    return 0
  fi
  puts "creating gradle.properties..."
  echo "" >>gradle.properties
  echo "$GRADLEPROPS" >>gradle.properties
}

setup_ndk() {
  if [ -z "$NDK" ]; then
    return 0
  fi
  NDK_DIR=android-ndk-$NDK
  NDK_URL=https://dl.google.com/android/repository/$NDK_DIR-linux-x86_64.zip
  export ANDROID_NDK_HOME=$TMP/$NDK_DIR

  download "$NDK_URL"

  extract "$DEST"
}

get_config() {
  PROP=$1
  DEFAULT=${2:-}
  value=$(yq r "$CONFIG" "$PROP")
  if [ "$value" != null ]; then
    puts "$1=$value"
    echo "$value"
  else
    puts "$1=$DEFAULT [default]"
    echo "$DEFAULT"
  fi
}

install_deps() {
  if [ -z "$DEPS" ]; then
    return 0
  fi
  puts "installing dependencies..."
  # running sudo for use outside of a container
  sudo apt-get update
  # shellcheck disable=SC2086
  if ! sudo apt-get install --no-install-suggests --no-install-recommends -y $DEPS; then
    exit 1
  fi
}

adb() {
  HOST=$(getent hosts host.docker.internal | awk '{ printf $1 }')
  $ADB -H "${HOST:-localhost}" "$@"
}

clone_and_cd() {
  clone "$1" "$2" "$3"
  cd "$2" || exit
}

zipalign() {
  zipalign=$(find_build_tool zipalign)
  puts "aligning $1 to $2..."
  if ! $zipalign -f -v -p 4 "$1" "$2"; then
    exit 1
  fi
  puts "verifying alignment for $2"
  if ! $zipalign -c -v 4 "$2"; then
    exit 1
  fi
}

sign() {
  apksigner=$(find_build_tool apksigner)
  puts "signing $1..."
  if ! $apksigner sign --ks "$KEYSTORE" --ks-pass env:KSPASS "$1"; then
    exit 1
  fi
  puts "verifying signature for $1"
  if ! $apksigner verify "$1"; then
    exit 1
  fi
}

clone() {
  URL=$1
  DIR=$2
  SHA=$3
  if [ -d "$DIR" ]; then
    (
      cd "$DIR" || exit
      git fetch --tags --prune
    )
  else
    git clone "$URL" "$DIR" --recurse-submodules
  fi
  (
    cd "$DIR" || exit
    git reset --hard "$SHA"
    git submodule update --init --recursive
  )
}

download_gradle() {
  if [ -z "$GRADLE_VERSION" ]; then
    DISTRIBUTION=$(grep -e "^distributionUrl=https\\\\://services.gradle.org/" gradle/wrapper/gradle-wrapper.properties)
    GRADLE_VERSION=$(echo "$DISTRIBUTION" | grep -o "[0-9]\+\(\.[0-9]\+\)\+")
  fi
  GRADLE_ZIP_URL=https://services.gradle.org/distributions/gradle-$GRADLE_VERSION-bin.zip
  GRADLE=$TMP/gradle-$GRADLE_VERSION/bin/gradle

  download "$GRADLE_ZIP_URL.sha256"

  download "$GRADLE_ZIP_URL"

  checksum "$DEST" "$DEST.sha256"

  extract "$DEST"
}

download() {
  URL=$1
  FILENAME=$(basename "$URL")
  DEST=$DOWNLOADS/$FILENAME
  puts "downloading $URL to $DEST"
  if ! wget --continue --quiet "$URL" -O "$DEST"; then
    exit 1
  fi
}

extract() {
  ZIP=$1
  puts "unzipping $ZIP to $TMP..."
  unzip -oq "$ZIP" -d "$TMP"
}

checksum() {
  FILE=$1
  CHECKSUM=$2
  puts "checking $FILE"
  if ! sha256 "$FILE" | diff "$CHECKSUM" -; then
    rm -v "$FILE" "$CHECKSUM"
    exit 1
  fi
}

sha256() {
  sha256sum "$1" | awk '{ printf $1 }'
}
