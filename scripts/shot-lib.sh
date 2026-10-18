# Sourced by scripts/screenshots.sh, and by scripts/shot-lib-test.sh, which
# stands in for xcrun, sleep and same_shot to check that each gives up with
# exit 1 rather than keep a home screen or a half drawn frame. Every
# variable here starts with shot_, so none of them overwrites one the
# sourcing script uses.

# Whether two shots match, allowing a thousandth of the pixels to differ.
same_shot() {
  build/same-shot "$1" "$2"
}

# A screenshot of simulator $1 once the screen has stopped changing, written
# to $2. A fixed wait can catch a launch half drawn, or the home screen, on
# a busy machine; two shots in a row that match mean it has settled. A
# blinking caret never matches byte for byte, so same_shot lets a
# thousandth of the pixels differ. A screen that never settles is an error,
# never its last frame.
settled_shot() {
  sleep 3
  xcrun simctl io "$1" screenshot "$2" >/dev/null 2>&1
  shot_tries=0
  while [ "$shot_tries" -lt 15 ]; do
    sleep 2
    xcrun simctl io "$1" screenshot "$2.next.png" >/dev/null 2>&1
    if same_shot "$2" "$2.next.png"; then
      rm -f "$2.next.png"
      return 0
    fi
    mv "$2.next.png" "$2"
    shot_tries=$((shot_tries + 1))
  done
  echo "screenshots: the screen never settled for $2 after $shot_tries tries" >&2
  exit 1
}

# Whether app $2 is running on simulator $1: a launchctl line whose label
# starts with exactly UIKitApplication:$2[ and whose PID is a number.
# launchctl keeps a job that has exited, with - for its PID, and a
# lookalike such as the $2.UITests runner shares the prefix, so neither
# counts.
app_is_up() {
  xcrun simctl spawn "$1" launchctl list 2>/dev/null |
    awk -v want="UIKitApplication:$2[" '
      $1 ~ /^[0-9]+$/ && index($3, want) == 1 { up = 1 }
      END { exit up ? 0 : 1 }'
}

# Launches app $2 on simulator $1 with the arguments after $3, and takes a
# settled shot to $3, up to three times until the app is running. The app
# must be up both before the screen settles and after, so neither a launch
# that never started nor one that died while settling passes. Still not
# running after the third try is an error, so a home screen never passes
# for the app.
launch_and_shoot() {
  shot_udid="$1"; shot_app="$2"; shot_file="$3"; shift 3
  for shot_attempt in 1 2 3; do
    xcrun simctl launch --terminate-running-process "$shot_udid" "$shot_app" "$@" >/dev/null
    if app_is_up "$shot_udid" "$shot_app"; then
      settled_shot "$shot_udid" "$shot_file"
      if app_is_up "$shot_udid" "$shot_app"; then return 0; fi
    fi
    echo "screenshots: the app wasn't up for $shot_file on try $shot_attempt, launching again"
  done
  echo "screenshots: the app never came up for $shot_file after three tries" >&2
  exit 1
}
