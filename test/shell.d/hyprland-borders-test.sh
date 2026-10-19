#!/bin/bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
stub_dir="$tmpdir/bin"
home_dir="$tmpdir/home"
state_home="$home_dir/.local/state"
toggles_dir="$state_home/omarchy/toggles/hypr"
mkdir -p "$stub_dir" "$home_dir"
export TEST_LOG="$tmpdir/commands.log"
: >"$TEST_LOG"

cat >"$stub_dir/hyprctl" <<'STUB'
#!/bin/bash
printf 'hyprctl %s\n' "$*" >>"$TEST_LOG"
[[ ${FAIL_COMMAND:-} != "hyprctl" ]]
STUB
cat >"$stub_dir/omarchy-notification-send" <<'STUB'
#!/bin/bash
printf 'notification %s\n' "$*" >>"$TEST_LOG"
STUB
for command in mkdir cp rm; do
  cat >"$stub_dir/$command" <<STUB
#!/bin/bash
[[ \${FAIL_COMMAND:-} != "$command" ]] || exit 1
exec /usr/bin/$command "\$@"
STUB
done
chmod +x "$stub_dir"/*

run() {
  HOME="$home_dir" XDG_STATE_HOME="$state_home" OMARCHY_PATH="$ROOT" PATH="$stub_dir:$ROOT/bin:$PATH" "$@"
}

menu_check() {
  local mode guard
  mode=$(run omarchy-hyprland-borders)
  for choice in theme none; do
    guard=$(node - "$ROOT" "$choice" <<'JS'
const root = process.argv[2]
const menu = require(root + '/shell/plugins/menu/MenuModel.js')
const fs = require('fs')
const items = menu.parseMenuJsonc(fs.readFileSync(root + '/default/omarchy/omarchy-menu.jsonc', 'utf8'))
const item = items.find(item => item.id === 'trigger.appearance.window-borders.' + process.argv[3])
if (!item || item.action !== 'omarchy-hyprland-borders ' + process.argv[3] || item.aliases.length || !item.checked) process.exit(1)
process.stdout.write(item.checked)
JS
    ) || fail "border menu actions and guards exist without aliases"
    if run bash -c "$guard"; then
      [[ $choice == "$mode" ]] || fail "only the current border choice is checked"
    else
      [[ $choice != "$mode" ]] || fail "the current border choice is checked"
    fi
  done
}

[[ -x $ROOT/bin/omarchy-hyprland-borders ]] || fail "borders command is executable"
[[ $(run omarchy-hyprland-borders) == "theme" ]] || fail "borders default to theme"
[[ ! -e $state_home && ! -s $TEST_LOG ]] || fail "default query has no side effects"
menu_check
pass "default borders follow the theme without side effects"

run omarchy-hyprland-borders none
[[ $(run omarchy-hyprland-borders) == "none" ]] || fail "no borders are reported"
cmp -s "$ROOT/default/hypr/toggles/borders-none.lua" "$toggles_dir/borders-none.lua" || fail "no borders persist as the shipped flag"
grep -qx 'hyprctl reload' "$TEST_LOG" || fail "setting borders reloads Hyprland"
grep -q '^notification .*No borders for all themes$' "$TEST_LOG" || fail "setting borders notifies in English"
run omarchy-hyprland-borders none
cmp -s "$ROOT/default/hypr/toggles/borders-none.lua" "$toggles_dir/borders-none.lua" || fail "repeated none keeps the flag"
menu_check
pass "none persists, reloads and can be repeated"

# Removing borders must not remove unrelated gap or corner choices.
cp "$ROOT/default/hypr/toggles/window-no-gaps.lua" "$toggles_dir/window-no-gaps.lua"
printf 'unrelated\n' >"$toggles_dir/corners-sharp.lua"
: >"$TEST_LOG"
run omarchy-hyprland-borders theme
[[ $(run omarchy-hyprland-borders) == "theme" && ! -e $toggles_dir/borders-none.lua ]] || fail "theme removes the border override"
[[ -f $toggles_dir/window-no-gaps.lua && -f $toggles_dir/corners-sharp.lua ]] || fail "theme keeps unrelated toggles"
grep -qx 'hyprctl reload' "$TEST_LOG" || fail "theme reloads Hyprland"
grep -q '^notification .*Borders follow the theme$' "$TEST_LOG" || fail "theme notifies in English"
menu_check
pass "theme removes only the border override and reloads"

for initial in theme none; do
  run omarchy-hyprland-borders "$initial"
  for invalid in unknown theme none ''; do
    : >"$TEST_LOG"
    if [[ $invalid == "unknown" || -z $invalid ]]; then
      args=("$invalid")
    else
      args=("$invalid" extra)
    fi
    if run omarchy-hyprland-borders "${args[@]}" 2>/dev/null; then
      fail "invalid and excess arguments are refused"
    fi
    [[ $(run omarchy-hyprland-borders) == "$initial" && ! -s $TEST_LOG ]] || fail "invalid arguments leave state and reload log unchanged"
  done
done
pass "invalid and excess arguments leave both states unchanged"

state_home="$tmpdir/custom state"
run omarchy-hyprland-borders none
[[ -f $state_home/omarchy/toggles/hypr/borders-none.lua && $(run omarchy-hyprland-borders) == "none" ]] || fail "borders follow XDG_STATE_HOME"
menu_check
state_home=""
run omarchy-hyprland-borders theme
run omarchy-hyprland-borders none
[[ -f $toggles_dir/borders-none.lua && $(run omarchy-hyprland-borders) == "none" ]] || fail "empty XDG_STATE_HOME falls back to HOME"
env -u XDG_STATE_HOME HOME="$home_dir" PATH="$stub_dir:$ROOT/bin:$PATH" omarchy-hyprland-borders | grep -qx none || fail "unset XDG_STATE_HOME falls back to HOME"
menu_check
pass "custom, empty and unset XDG_STATE_HOME are supported"

# Stub failures deterministically, including when run as root.
for failure in mkdir cp; do
  run omarchy-hyprland-borders theme
  : >"$TEST_LOG"
  if FAIL_COMMAND="$failure" run omarchy-hyprland-borders none 2>/dev/null; then
    fail "failed $failure is reported"
  fi
  [[ ! -e $toggles_dir/borders-none.lua && ! -s $TEST_LOG ]] || fail "failed $failure does not reload or notify"
done
: >"$TEST_LOG"
if OMARCHY_PATH="$tmpdir/missing" HOME="$home_dir" XDG_STATE_HOME="" PATH="$stub_dir:$ROOT/bin:$PATH" omarchy-hyprland-borders none 2>/dev/null; then
  fail "missing shipped flag is reported"
fi
[[ ! -e $toggles_dir/borders-none.lua && ! -s $TEST_LOG ]] || fail "missing flag does not reload or notify"
pass "mkdir, copy and missing flag failures surface without success"

run omarchy-hyprland-borders none
: >"$TEST_LOG"
if FAIL_COMMAND=rm run omarchy-hyprland-borders theme 2>/dev/null; then
  fail "failed removal is reported"
fi
[[ $(run omarchy-hyprland-borders) == "none" && ! -s $TEST_LOG ]] || fail "failed removal retains state without reload or success"
for mode in theme none; do
  : >"$TEST_LOG"
  if FAIL_COMMAND=hyprctl run omarchy-hyprland-borders "$mode" 2>/dev/null; then
    fail "failed reload is reported for $mode"
  fi
  grep -qx 'hyprctl reload' "$TEST_LOG" || fail "reload was attempted"
  ! grep -q '^notification ' "$TEST_LOG" || fail "failed reload never notifies success"
done
pass "removal and reload failures surface without success notifications"

printf 'ja\n' >"$tmpdir/language"
: >"$TEST_LOG"
OMARCHY_LANGUAGE_FILE="$tmpdir/language" run omarchy-hyprland-borders none
grep -q 'すべてのテーマで枠線なし$' "$TEST_LOG" || fail "Japanese notification is translated"
printf 'da\n' >"$tmpdir/language"
: >"$TEST_LOG"
OMARCHY_LANGUAGE_FILE="$tmpdir/language" run omarchy-hyprland-borders none
grep -q 'No borders for all themes$' "$TEST_LOG" || fail "other locales fall back to English"
pass "notifications support Japanese and English fallback"

if command -v lua >/dev/null; then
  toggle_load() {
    local dir="$tmpdir/load"
    rm -rf "$dir"
    mkdir -p "$dir"
    for toggle in "$@"; do cp "$ROOT/default/hypr/toggles/$toggle.lua" "$dir/"; done
    DIR="$dir" lua - <<'LUA'
package.path = os.getenv("ROOT") .. "/?.lua;" .. os.getenv("DIR") .. "/?.lua;" .. package.path
local state = { general = { border_size = 7, gaps_in = 8, gaps_out = 9 }, decoration = { rounding = 10 } }
hl = { config = function(config)
  for section, values in pairs(config) do
    for key, value in pairs(values) do state[section][key] = value end
  end
end }
require("default.hypr.require_all").files(os.getenv("DIR"), nil, { reload = true })
print(state.general.border_size, state.general.gaps_in, state.general.gaps_out, state.decoration.rounding)
LUA
  }
  [[ $(toggle_load) == $'7\t8\t9\t10' ]] || fail "theme restores configured width without override"
  [[ $(toggle_load borders-none) == $'0\t8\t9\t10' ]] || fail "no borders preserve gaps and rounding"
  [[ $(toggle_load window-no-gaps) == $'0\t0\t0\t0' ]] || fail "theme borders respect no-gaps"
  [[ $(toggle_load borders-none window-no-gaps) == $'0\t0\t0\t0' ]] || fail "no-gaps remains authoritative with no borders"
  # Reject any new setting, including colors, opacity and dimming.
  ROOT="$ROOT" lua - <<'LUA'
hl = { config = function(config)
  assert(next(config) == "general" and next(config, "general") == nil)
  assert(next(config.general) == "border_size" and next(config.general, "border_size") == nil)
  assert(config.general.border_size == 0)
end }
dofile(os.getenv("ROOT") .. "/default/hypr/toggles/borders-none.lua")
LUA
  pass "real Lua loader preserves theme width, gaps and rounding, with no-gaps precedence"
else
  skip "lua is not installed"
fi
