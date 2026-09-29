# Source me: puts the Flutter/Dart SDK on PATH when it is installed user-locally
# (FLUTTER_HOME, default /home/pmp/devel/flutter). Elsewhere (e.g. CI) the SDK
# is expected on PATH already.
FLUTTER_HOME="${FLUTTER_HOME:-/home/pmp/devel/flutter}"
if [[ -d "$FLUTTER_HOME/bin" ]]; then export PATH="$FLUTTER_HOME/bin:$PATH"; fi
