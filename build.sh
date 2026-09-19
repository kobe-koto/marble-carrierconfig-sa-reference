#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_XML="$ROOT/overlay/input/vendor.xml"
BUILD="$ROOT/build"
DIST="$ROOT/dist"
KEY_DIR="$ROOT/keys"
KEYSTORE="${KEYSTORE:-$KEY_DIR/carrierconfig-overlay.p12}"
KEY_ALIAS="${KEY_ALIAS:-carrierconfig-overlay}"
KEY_PASS="${KEY_PASS:-carrierconfig-overlay}"
AAPT2="${AAPT2:-$(command -v aapt2)}"
ZIPALIGN="${ZIPALIGN:-$(command -v zipalign)}"
APKSIGNER="${APKSIGNER:-$(command -v apksigner)}"
JAVAC="${JAVAC:-$(command -v javac)}"
D8="${D8:-$(command -v d8 || true)}"
[[ -n "$D8" ]] || D8="${ANDROID_HOME:-/opt/android-sdk}/cmdline-tools/latest/bin/d8"
MODULE_VERSION="1.1.1"
MODULE_VERSION_CODE="3"

if [[ -n "${ANDROID_JAR:-}" ]]; then
    :
elif [[ -n "${ANDROID_HOME:-}" ]]; then
    ANDROID_JAR="$(find "$ANDROID_HOME/platforms" -mindepth 2 -maxdepth 2 -name android.jar -print | sort -V | tail -n 1)"
elif [[ -f "$HOME/Android/Sdk/platforms/android-35/android.jar" ]]; then
    ANDROID_JAR="$HOME/Android/Sdk/platforms/android-35/android.jar"
else
    echo "ANDROID_JAR not found; export ANDROID_JAR=/path/to/android.jar" >&2
    exit 1
fi

for f in "$SOURCE_XML" "$ANDROID_JAR"; do
    [[ -f "$f" ]] || { echo "Missing file: $f" >&2; echo "See overlay/README.md for vendor.xml extraction instructions." >&2; exit 1; }
done
for tool in "$AAPT2" "$ZIPALIGN" "$APKSIGNER" "$JAVAC" "$D8" keytool jar zip python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "Missing tool: $tool" >&2; exit 1; }
done

mkdir -p "$BUILD" "$DIST" "$KEY_DIR" "$ROOT/reports"
if [[ ! -f "$KEYSTORE" ]]; then
    keytool -genkeypair -noprompt \
        -keystore "$KEYSTORE" -storetype PKCS12 \
        -storepass "$KEY_PASS" -keypass "$KEY_PASS" \
        -alias "$KEY_ALIAS" -keyalg RSA -keysize 4096 -validity 10000 \
        -dname "CN=Evolution X CarrierConfig SA Overlay, OU=Local Build, O=Local, C=XX"
fi
chmod 0600 "$KEYSTORE"

build_companion() {
    local work="$BUILD/companion"
    local src="$ROOT/companion/src/io/github/evox/carrierconfig/sa/enforcer/SaModeReceiver.java"
    local stubs="$ROOT/companion/stubs"
    local manifest="$ROOT/companion/AndroidManifest.xml"
    local apk="$DIST/CarrierConfigSaEnforcer.apk"

    rm -rf "$work"
    mkdir -p "$work/stub-classes" "$work/classes" "$work/dex"
    mapfile -t stub_sources < <(find "$stubs" -type f -name '*.java' -print | sort)
    "$JAVAC" -source 8 -target 8 -Xlint:-options -cp "$ANDROID_JAR" \
        -d "$work/stub-classes" "${stub_sources[@]}"
    jar cf "$work/extphone-stubs.jar" -C "$work/stub-classes" .
    "$JAVAC" -source 8 -target 8 -Xlint:-options \
        -cp "$ANDROID_JAR:$work/extphone-stubs.jar" -d "$work/classes" "$src"
    jar cf "$work/classes.jar" -C "$work/classes" .
    "$D8" --lib "$ANDROID_JAR" --classpath "$work/extphone-stubs.jar" \
        --min-api 31 --output "$work/dex" "$work/classes.jar"
    "$AAPT2" link -I "$ANDROID_JAR" --manifest "$manifest" \
        -o "$work/CarrierConfigSaEnforcer-unsigned.apk"
    (cd "$work/dex" && zip -q -9 "$work/CarrierConfigSaEnforcer-unsigned.apk" classes.dex)
    "$ZIPALIGN" -f 4 "$work/CarrierConfigSaEnforcer-unsigned.apk" \
        "$work/CarrierConfigSaEnforcer-aligned.apk"
    "$APKSIGNER" sign \
        --ks "$KEYSTORE" --ks-type PKCS12 --ks-key-alias "$KEY_ALIAS" \
        --ks-pass "pass:$KEY_PASS" --key-pass "pass:$KEY_PASS" \
        --out "$apk" "$work/CarrierConfigSaEnforcer-aligned.apk"
    "$APKSIGNER" verify --verbose --print-certs "$apk" > "$work/apksigner-verify.txt"
}

build_variant() {
    local variant="$1" package_name="$2" apk_name="$3" module_id="$4" module_name="$5" other_module="$6"
    local work="$BUILD/$variant"
    local variant_root="$ROOT/variants/$variant"
    local apk="$DIST/$apk_name.apk"
    local module_root="$work/module"
    local zip_name="$DIST/${module_id}-v${MODULE_VERSION}.zip"
    local companion_dir="CarrierConfigSaEnforcerV${MODULE_VERSION_CODE}"

    rm -rf "$work"
    mkdir -p "$work/compiled" "$variant_root/res/xml" \
        "$module_root/system/vendor/overlay" \
        "$module_root/system/system_ext/priv-app/$companion_dir" \
        "$module_root/system/system_ext/etc/permissions" \
        "$module_root/system/system_ext/etc/default-permissions"

    python3 "$ROOT/overlay/tools/patch_vendor_xml.py" \
        --mode "$variant" "$SOURCE_XML" "$variant_root/res/xml/vendor.xml" \
        --report "$ROOT/reports/$variant.json" > "$work/patch-report.json"

    cat > "$work/AndroidManifest.xml" <<MANIFEST
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="$package_name"
    android:versionCode="$MODULE_VERSION_CODE"
    android:versionName="$MODULE_VERSION">
    <uses-sdk android:minSdkVersion="31" android:targetSdkVersion="35" />
    <application android:hasCode="false" android:label="$module_name" />
    <overlay
        android:targetPackage="com.android.carrierconfig"
        android:isStatic="true"
        android:priority="999" />
</manifest>
MANIFEST

    "$AAPT2" compile --dir "$variant_root/res" -o "$work/compiled"
    mapfile -t flats < <(find "$work/compiled" -type f -name '*.flat' -print | sort)
    [[ ${#flats[@]} -gt 0 ]] || { echo "No compiled resources for $variant" >&2; exit 1; }
    "$AAPT2" link \
        -I "$ANDROID_JAR" \
        --manifest "$work/AndroidManifest.xml" \
        --auto-add-overlay --no-resource-deduping --no-resource-removal --keep-raw-values \
        -o "$work/$apk_name-unsigned.apk" "${flats[@]}"
    "$ZIPALIGN" -f 4 "$work/$apk_name-unsigned.apk" "$work/$apk_name-aligned.apk"
    "$APKSIGNER" sign \
        --ks "$KEYSTORE" --ks-type PKCS12 --ks-key-alias "$KEY_ALIAS" \
        --ks-pass "pass:$KEY_PASS" --key-pass "pass:$KEY_PASS" \
        --out "$apk" "$work/$apk_name-aligned.apk"
    "$APKSIGNER" verify --verbose --print-certs "$apk" > "$work/apksigner-verify.txt"

    cp "$apk" "$module_root/system/vendor/overlay/$apk_name.apk"
    cp "$DIST/CarrierConfigSaEnforcer.apk" \
        "$module_root/system/system_ext/priv-app/$companion_dir/CarrierConfigSaEnforcer.apk"
    cp "$ROOT/companion/privapp-permissions.xml" \
        "$module_root/system/system_ext/etc/permissions/privapp-permissions-carrierconfig-sa-enforcer.xml"
    cp "$ROOT/companion/default-permissions.xml" \
        "$module_root/system/system_ext/etc/default-permissions/default-permissions-carrierconfig-sa-enforcer.xml"
    cat > "$module_root/module.prop" <<MODULE
id=$module_id
name=$module_name
version=$MODULE_VERSION
versionCode=$MODULE_VERSION_CODE
author=local build
description=CarrierConfig RRO plus privileged QTI applicator; enables combined 5G SA+NSA policy ($variant).
MODULE
    cat > "$module_root/customize.sh" <<CUSTOMIZE
#!/system/bin/sh
OTHER="/data/adb/modules/$other_module"
# Use a versioned system-app directory so PackageManager cannot reuse parsed
# metadata for an older APK at the same path. Remove obsolete module copies.
for OLD in \$MODPATH/system/system_ext/priv-app/CarrierConfigSaEnforcer*; do
    [ "\$OLD" = "\$MODPATH/system/system_ext/priv-app/$companion_dir" ] || rm -rf "\$OLD"
done
if [ -d "\$OTHER" ] && [ ! -f "\$OTHER/disable" ] && [ ! -f "\$OTHER/remove" ]; then
    abort "Conflicting CarrierConfig SA module is enabled: $other_module"
fi
ui_print "Installing $module_name"
ui_print "Target: com.android.carrierconfig / res/xml/vendor.xml"
ui_print "Clearing CarrierConfig cache so the overlay is parsed after reboot."
rm -f /data/user_de/0/com.android.phone/files/carrierconfig-com.android.carrierconfig-*.xml
ui_print "A reboot is required. Do not enable both variants."
set_perm_recursive \$MODPATH 0 0 0755 0644
CUSTOMIZE
    cat > "$module_root/post-fs-data.sh" <<'POSTFSDATA'
#!/system/bin/sh
# CarrierConfigLoader caches the default carrier app's result by package
# version. An RRO does not change that version, so invalidate only that cache.
rm -f /data/user_de/0/com.android.phone/files/carrierconfig-com.android.carrierconfig-*.xml
POSTFSDATA
    cat > "$module_root/uninstall.sh" <<'UNINSTALL'
#!/system/bin/sh
# Force regeneration from the stock resource after the overlay is removed.
rm -f /data/user_de/0/com.android.phone/files/carrierconfig-com.android.carrierconfig-*.xml
UNINSTALL
    chmod 0755 "$module_root/customize.sh" "$module_root/post-fs-data.sh" "$module_root/uninstall.sh"
    cat > "$module_root/README.txt" <<README
This module overlays com.android.carrierconfig:xml/vendor and installs a small
privileged companion that applies allowed SA+NSA policy through ExtTelephony.
The XML input must be extracted from the exact ROM build being targeted.
Variant: $variant
Package: $package_name

Do not enable this and the other variant at the same time. Disable or uninstall
the module and reboot to roll back. Rebuild after a ROM/vendor update.
README

    rm -f "$zip_name"
    (cd "$module_root" && zip -q -r -9 "$zip_name" .)
    printf '%s  %s\n' "$(sha256sum "$apk" | awk '{print $1}')" "$(basename "$apk")" > "$work/SHA256SUMS.txt"
    printf '%s  %s\n' "$(sha256sum "$DIST/CarrierConfigSaEnforcer.apk" | awk '{print $1}')" "CarrierConfigSaEnforcer.apk" >> "$work/SHA256SUMS.txt"
    printf '%s  %s\n' "$(sha256sum "$zip_name" | awk '{print $1}')" "$(basename "$zip_name")" >> "$work/SHA256SUMS.txt"
    cp "$work/SHA256SUMS.txt" "$DIST/${variant}-SHA256SUMS.txt"

    echo "Built: $apk"
    echo "Built: $zip_name"
}

build_companion

build_variant \
    explicit-nsa \
    io.github.evox.carrierconfig.sa.explicitnsa \
    CarrierConfigSaExplicitNsaOverlay \
    evox_carrierconfig_sa_explicit_nsa \
    "EvoX CarrierConfig SA (explicit NSA)" \
    evox_carrierconfig_sa_universal

build_variant \
    universal \
    io.github.evox.carrierconfig.sa.universal \
    CarrierConfigSaUniversalOverlay \
    evox_carrierconfig_sa_universal \
    "EvoX CarrierConfig SA (universal)" \
    evox_carrierconfig_sa_explicit_nsa

(
    cd "$DIST"
    sha256sum \
        CarrierConfigSaExplicitNsaOverlay.apk \
        CarrierConfigSaUniversalOverlay.apk \
        CarrierConfigSaEnforcer.apk \
        "evox_carrierconfig_sa_explicit_nsa-v${MODULE_VERSION}.zip" \
        "evox_carrierconfig_sa_universal-v${MODULE_VERSION}.zip" \
        > SHA256SUMS.txt
)

echo "All artifacts are in: $DIST"
