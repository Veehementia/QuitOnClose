#!/bin/bash
# Builds QuitOnClose, installs it to /Applications and opens it.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build.sh

pkill -x QuitOnClose 2>/dev/null || true
rm -rf /Applications/QuitOnClose.app
# Moved rather than copied: Spotlight would find a copy left in build/ and list the app twice.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -u "$PWD/build/QuitOnClose.app" 2>/dev/null || true
mv build/QuitOnClose.app /Applications/

# An ad-hoc signed build counts as a new app for Accessibility each time, so clear the old
# permission and let the app ask again.
if [ "${SIGN_IDENTITY:--}" = "-" ]; then
    tccutil reset Accessibility com.matteonardone.QuitOnClose >/dev/null 2>&1 || true
fi

open /Applications/QuitOnClose.app
echo "Installed /Applications/QuitOnClose.app — allow it in System Settings → Privacy & Security → Accessibility."
