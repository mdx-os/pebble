#!/bin/sh
# PERMANENT GUARD, run by scripts/check-screenshots.sh and so by `make
# verify`. scripts/shot-lib.sh must exit 1 when the app never comes up or
# the screen never settles, so a home screen or a half drawn frame is never
# kept as a shot. Stands in for xcrun, sleep and same_shot, so it needs no
# simulator and takes a moment.
# Usage: scripts/shot-lib-test.sh
set -eu

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Runs scripts/shot-lib.sh's $1 with the rest as its arguments, in a
# subshell with the stand-ins, and prints its exit status. $APP_UP says
# whether the app shows in launchctl, $SETTLES whether two shots match.
run() {
  (
    . scripts/shot-lib.sh
    sleep() { :; }
    same_shot() { [ "$SETTLES" = yes ]; }
    xcrun() {
      case "$*" in
        *" screenshot "*) for last in "$@"; do :; done; echo shot > "$last" ;;
        *" launchctl list") [ "$APP_UP" = no ] || echo "123 0 UIKitApplication:com.example.app" ;;
      esac
    }
    "$@" >/dev/null 2>&1
  ) && echo 0 || echo 1
}

expect() {
  if [ "$1" != "$2" ]; then
    echo "shot-lib-test: $3: exit $1, expected $2" >&2
    exit 1
  fi
}

export APP_UP SETTLES
APP_UP=yes SETTLES=yes; expect "$(run launch_and_shoot sim com.example.app "$work/up.png")" 0 "an app that comes up"
[ -s "$work/up.png" ] || { echo "shot-lib-test: no shot was kept" >&2; exit 1; }
APP_UP=no SETTLES=yes; expect "$(run launch_and_shoot sim com.example.app "$work/down.png")" 1 "an app that never comes up"
APP_UP=yes SETTLES=no; expect "$(run settled_shot sim "$work/busy.png")" 1 "a screen that never settles"
APP_UP=yes SETTLES=no; expect "$(run launch_and_shoot sim com.example.app "$work/busy2.png")" 1 "a launch that never settles"
echo "shot-lib-test: a shot is kept only when the app is up and the screen has settled"
