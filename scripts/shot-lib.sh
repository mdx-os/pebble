# Sourced by scripts/screenshots.sh, and by scripts/shot-lib-test.sh, which
# stands in for xcrun, sleep and same_shot to check that each gives up with
# exit 1 rather than keep a home screen or a half drawn frame.

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
  tries=0
  while [ "$tries" -lt 15 ]; do
    sleep 2
    xcrun simctl io "$1" screenshot "$2.next.png" >/dev/null 2>&1
    if same_shot "$2" "$2.next.png"; then
      rm -f "$2.next.png"
      return 0
    fi
    mv "$2.next.png" "$2"
    tries=$((tries + 1))
  done
  echo "screenshots: the screen never settled for $2 after $tries tries" >&2
  exit 1
}

# Launches app $2 on simulator $1 with the arguments after $3, and takes a
# settled shot to $3, up to three times until the app is running. Still not
# running after the third try is an error, so a home screen never passes
# for the app.
launch_and_shoot() {
  udid="$1"; app="$2"; file="$3"; shift 3
  for attempt in 1 2 3; do
    xcrun simctl launch --terminate-running-process "$udid" "$app" "$@" >/dev/null
    settled_shot "$udid" "$file"
    if xcrun simctl spawn "$udid" launchctl list | grep -q "$app"; then return 0; fi
    echo "screenshots: the app wasn't up for $file, launching again"
  done
  echo "screenshots: the app never came up for $file after three tries" >&2
  exit 1
}
