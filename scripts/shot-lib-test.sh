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
# subshell with the stand-ins, and prints its exit status. $SETTLES says
# whether two shots match. $APP_UP says what launchctl shows:
#   yes        the app, running
#   no         nothing
#   dash       the app's job, exited, with - for its PID
#   lookalike  only the app's .UITests runner, running
#   dies       the app running at the first look, then gone
#   slow       nothing at the first look, then the app running
# A shot holds "app" once launchctl has shown the app running, and "home"
# before, so a test can tell which was kept.
run() {
  rm -f "$work/looks" "$work/seen"
  (
    . scripts/shot-lib.sh
    sleep() { :; }
    same_shot() { [ "$SETTLES" = yes ]; }
    xcrun() {
      case "$*" in
        *" screenshot "*)
          for last in "$@"; do :; done
          if [ -f "$work/seen" ]; then echo app > "$last"; else echo home > "$last"; fi ;;
        *" launchctl list")
          echo x >> "$work/looks"
          looks="$(wc -l < "$work/looks" | tr -d ' ')"
          echo "PID	Status	Label"
          echo "77	0	com.apple.springboard"
          case "$APP_UP" in
            yes) line="123	0	UIKitApplication:com.example.app[a1b2][rb-legacy]" ;;
            no) line="" ;;
            dash) line="-	0	UIKitApplication:com.example.app[a1b2][rb-legacy]" ;;
            lookalike) line="123	0	UIKitApplication:com.example.app.UITests.xctrunner[a1b2][rb-legacy]" ;;
            dies) if [ "$looks" -eq 1 ]; then line="123	0	UIKitApplication:com.example.app[a1b2][rb-legacy]"; else line=""; fi ;;
            slow) if [ "$looks" -eq 1 ]; then line=""; else line="123	0	UIKitApplication:com.example.app[a1b2][rb-legacy]"; fi ;;
          esac
          if [ -n "$line" ]; then
            echo "$line"
            case "$line" in 123*"UIKitApplication:com.example.app["*) touch "$work/seen" ;; esac
          fi ;;
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
[ "$(cat "$work/up.png")" = app ] || { echo "shot-lib-test: no shot of the app was kept" >&2; exit 1; }
APP_UP=no SETTLES=yes; expect "$(run launch_and_shoot sim com.example.app "$work/down.png")" 1 "an app that never comes up"
APP_UP=dash SETTLES=yes; expect "$(run launch_and_shoot sim com.example.app "$work/dash.png")" 1 "an app whose job exited, with - for its PID"
APP_UP=lookalike SETTLES=yes; expect "$(run launch_and_shoot sim com.example.app "$work/lookalike.png")" 1 "only the app's UI test runner up"
APP_UP=dies SETTLES=yes; expect "$(run launch_and_shoot sim com.example.app "$work/dies.png")" 1 "an app that dies while the screen settles"
APP_UP=slow SETTLES=yes; expect "$(run launch_and_shoot sim com.example.app "$work/slow.png")" 0 "an app that comes up on the second launch"
[ "$(cat "$work/slow.png")" = app ] || { echo "shot-lib-test: a shot taken before the app was up was kept" >&2; exit 1; }
APP_UP=yes SETTLES=no; expect "$(run settled_shot sim "$work/busy.png")" 1 "a screen that never settles"
APP_UP=yes SETTLES=no; expect "$(run launch_and_shoot sim com.example.app "$work/busy2.png")" 1 "a launch that never settles"
echo "shot-lib-test: a shot is kept only when the app is up and the screen has settled"
