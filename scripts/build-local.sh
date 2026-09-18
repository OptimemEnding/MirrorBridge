#!/usr/bin/env bash
# macOS / Linux. Paths may contain spaces; no PowerShell or fixed drive letters.
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target="${1:-arm64}"
case "$target" in arm64|normal|demo|all|check|native|doctor) ;; *) printf 'Usage: %s [arm64|normal|demo|all|check|native|doctor]\n' "$0" >&2; exit 2 ;; esac
flutter_bin="${FLUTTER_BIN:-}"
if [[ -z "$flutter_bin" ]] && command -v flutter >/dev/null 2>&1; then flutter_bin="$(command -v flutter)"; fi
if [[ -z "$flutter_bin" && -n "${FLUTTER_ROOT:-}" ]]; then flutter_bin="$FLUTTER_ROOT/bin/flutter"; fi
if [[ ! -x "$flutter_bin" ]]; then printf 'Set FLUTTER_BIN to your Flutter 3.44.5 bin/flutter, or add Flutter to PATH.\n' >&2; exit 2; fi
cd "$project_dir"
if [[ "$target" == check ]]; then
  "$flutter_bin" pub get
  python3 scripts/check_naming.py
  python3 scripts/verify_sources.py
  "$flutter_bin" analyze --no-pub
  "$flutter_bin" test --no-pub --reporter expanded --concurrency=1
  exit 0
fi
if [[ "$target" == doctor ]]; then "$flutter_bin" doctor -v; exit 0; fi
if [[ -z "${ANDROID_HOME:-}" ]]; then
  if [[ -n "${ANDROID_SDK_ROOT:-}" ]]; then export ANDROID_HOME="$ANDROID_SDK_ROOT"
  elif [[ -d "$HOME/Library/Android/sdk" ]]; then export ANDROID_HOME="$HOME/Library/Android/sdk"
  elif [[ -d "$HOME/Android/Sdk" ]]; then export ANDROID_HOME="$HOME/Android/Sdk"; fi
fi
if [[ -z "${JAVA_HOME:-}" && -x /usr/libexec/java_home ]]; then
  if java_dir="$(/usr/libexec/java_home -v 21 2>/dev/null)"; then export JAVA_HOME="$java_dir"; fi
fi
if [[ -z "${JAVA_HOME:-}" && -d '/Applications/Android Studio.app/Contents/jbr/Contents/Home' ]]; then
  export JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home'
fi
if [[ ! -d "${ANDROID_HOME:-}/platforms/android-36" ]]; then
  printf 'Set ANDROID_HOME to Android SDK; install platforms;android-36, build-tools;36.0.0 and ndk;28.2.13676358.\n' >&2; exit 2
fi
if [[ ! -x "${JAVA_HOME:-}/bin/java" || ! -x "${JAVA_HOME:-}/bin/jlink" ]]; then printf 'Set JAVA_HOME to a full JDK including java and jlink (recommended: JDK 21). IDE runtimes may omit jlink.\n' >&2; exit 2; fi
export PATH="$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$PATH"
"$flutter_bin" pub get
if [[ "$target" == native ]]; then
  (cd android && bash gradlew :app:testDebugUnitTest --console=plain)
  exit 0
fi
mkdir -p dist
build_variant() {
  local variant="$1" arch artifact name
  local args=(build apk)
  if [[ "$variant" == arm64 ]]; then
    args+=(--release --target-platform android-arm64)
    artifact=build/app/outputs/flutter-apk/app-release.apk
    name=MirrorBridge-arm64.apk
  else
    arch="${EMULATOR_ARCH:-}"
    if [[ -z "$arch" ]]; then
      case "$(uname -m)" in arm64|aarch64) arch=android-arm64 ;; *) arch=android-x64 ;; esac
    fi
    args+=(--debug --target-platform "$arch")
    artifact=build/app/outputs/flutter-apk/app-debug.apk
    name=MirrorBridge-emulator.apk
    if [[ "$variant" == demo ]]; then args+=(--dart-define=DEMO_MODE=true); name=MirrorBridge-demo.apk; fi
  fi
  "$flutter_bin" "${args[@]}" 2>&1 | tee "dist/build-$variant.log"
  python3 scripts/inspect_apk.py "$artifact"
  cp "$artifact" "dist/$name"
  printf 'APK: %s/dist/%s\n' "$project_dir" "$name"
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "dist/$name"; else sha256sum "dist/$name"; fi
}
if [[ "$target" == all ]]; then for variant in arm64 normal demo; do build_variant "$variant"; done
else build_variant "$target"; fi
