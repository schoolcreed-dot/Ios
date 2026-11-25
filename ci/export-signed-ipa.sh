#!/usr/bin/env bash
set -euo pipefail
umask 077
mkdir -p output
signing_dir="$(mktemp -d "$RUNNER_TEMP/alpha-signing.XXXXXX")"
keychain="$signing_dir/build.keychain-db"
profile_target=""
cleanup() {
  if [[ -n "$profile_target" ]]; then rm -f "$profile_target"; fi
  security delete-keychain "$keychain" >/dev/null 2>&1 || true
  rm -rf "$signing_dir"
  rm -f App/GoogleService-Info.plist
}
trap cleanup EXIT

printf '%s' "$IOS_P12_BASE64" | base64 -D > "$signing_dir/distribution.p12"
printf '%s' "$IOS_PROFILE_BASE64" | base64 -D > "$signing_dir/profile.mobileprovision"
security cms -D -i "$signing_dir/profile.mobileprovision" > "$signing_dir/profile.plist"

profile_uuid=$(/usr/libexec/PlistBuddy -c 'Print UUID' "$signing_dir/profile.plist")
export PROFILE_UUID="$profile_uuid"
profile_id=$(/usr/libexec/PlistBuddy -c 'Print Entitlements:application-identifier' "$signing_dir/profile.plist")
profile_push=$(/usr/libexec/PlistBuddy -c 'Print Entitlements:aps-environment' "$signing_dir/profile.plist")
[[ "$profile_id" == "$IOS_TEAM_ID.$IOS_BUNDLE_ID" ]] || { echo 'Provisioning profile app identifier does not match the team and bundle ID.' >&2; exit 1; }
[[ "$profile_push" == production ]] || { echo 'Provisioning profile must include production APNs.' >&2; exit 1; }
if [[ "$EXPORT_METHOD" == app-store-connect ]]; then
  /usr/libexec/PlistBuddy -c 'Print ProvisionedDevices' "$signing_dir/profile.plist" >/dev/null 2>&1 && { echo 'Use an App Store distribution profile.' >&2; exit 1; }
elif [[ "$EXPORT_METHOD" == ad-hoc ]]; then
  /usr/libexec/PlistBuddy -c 'Print ProvisionedDevices' "$signing_dir/profile.plist" >/dev/null 2>&1 || { echo 'Use an Ad Hoc profile with registered devices.' >&2; exit 1; }
else
  echo 'Unsupported export method.' >&2; exit 1
fi
profile_target="$HOME/Library/MobileDevice/Provisioning Profiles/$profile_uuid.mobileprovision"
mkdir -p "$(dirname "$profile_target")"
cp "$signing_dir/profile.mobileprovision" "$profile_target"

keychain_password="$(openssl rand -hex 32)"
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$signing_dir/distribution.p12" -k "$keychain" -P "$IOS_P12_PASSWORD" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$keychain_password" "$keychain" >/dev/null
security list-keychains -d user -s "$keychain"
security find-identity -v -p codesigning "$keychain" | grep -q 'Apple Distribution' || { echo 'No Apple Distribution signing identity found in the .p12.' >&2; exit 1; }

python3 - "$signing_dir/ExportOptions.plist" <<'PY'
import os, plistlib, sys
options = {
    'method': os.environ['EXPORT_METHOD'],
    'teamID': os.environ['IOS_TEAM_ID'],
    'signingStyle': 'manual',
    'signingCertificate': 'Apple Distribution',
    'provisioningProfiles': {os.environ['IOS_BUNDLE_ID']: os.environ['PROFILE_UUID']},
    'destination': 'export',
    'manageAppVersionAndBuildNumber': False,
}
with open(sys.argv[1], 'wb') as f:
    plistlib.dump(options, f)
PY

xcodebuild archive -project AlphaMovies.xcodeproj -scheme AlphaMovies \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$PWD/output/AlphaMovies.xcarchive" \
  PRODUCT_BUNDLE_IDENTIFIER="$IOS_BUNDLE_ID" \
  DEVELOPMENT_TEAM="$IOS_TEAM_ID" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY='Apple Distribution' \
  PROVISIONING_PROFILE_SPECIFIER="$profile_uuid" \
  2>&1 | tee output/xcodebuild.log
xcodebuild -exportArchive \
  -archivePath "$PWD/output/AlphaMovies.xcarchive" \
  -exportPath "$PWD/output/export" \
  -exportOptionsPlist "$signing_dir/ExportOptions.plist" \
  2>&1 | tee -a output/xcodebuild.log
ipa="$(find output/export -maxdepth 1 -name '*.ipa' -print -quit)"
[[ -n "$ipa" ]] || { echo 'Xcode did not produce an IPA.' >&2; exit 1; }
cp "$ipa" output/AlphaMovies-SIGNED.ipa
unzip -tq output/AlphaMovies-SIGNED.ipa
mkdir -p "$signing_dir/verify"
unzip -q output/AlphaMovies-SIGNED.ipa -d "$signing_dir/verify"
codesign --verify --deep --strict --verbose=2 "$signing_dir/verify/Payload/AlphaMovies.app"
