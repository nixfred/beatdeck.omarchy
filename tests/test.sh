#!/usr/bin/env bash
# Beatdeck test suite. Validates the manifest, then exercises the theme-palette
# helpers against synthetic input so the hue maths is not trusted on sight.

set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "  ok  $*"; }

echo "== manifest =="
omarchy plugin validate "$repo_dir"
ok "omarchy plugin validate"

jq -e '
  .id == "nixfred.beatdeck" and
  .entryPoints.barWidget == "BarWidget.qml" and
  (.kinds == ["bar-widget"]) and
  (.entryPoints | has("service") | not) and
  (.barWidget.schema | map(.key) | index("themeColors")) != null
' manifest.json >/dev/null || fail "manifest contract"
ok "manifest contract"

# Every entry point the manifest names must actually be on disk. A manifest
# that promises a file the package does not ship fails at load, which is how a
# stale install once named a service the plugin dir did not have. The widget is
# the only entry point now: the shell hands a widget under a third-party bar no
# service at all, so the analyzer and the MPRIS read live in MediaEngine.qml
# and the widget owns them.
for key in barWidget; do
  f=$(jq -r ".entryPoints.$key" manifest.json)
  [ -f "$f" ] || fail "manifest names $key entry point '$f' but it is missing"
done
ok "every declared entry point exists"

echo "== qml parses =="
for f in *.qml; do
  grep -q "^import QtQuick" "$f" || fail "$f has no QtQuick import"
  o=$(grep -o '{' "$f" | wc -l); c=$(grep -o '}' "$f" | wc -l)
  [ "$o" = "$c" ] || fail "$f braces unbalanced ($o open, $c close)"
done
ok "all qml files import QtQuick and balance their braces"

echo "== theme palette =="
command -v node >/dev/null || fail "node is required for the palette tests"
node tests/test_theme_palette.cjs >/dev/null 2>&1 || fail "theme palette tests"
ok "palette parses, hues are in range, snapping wraps the colour circle"

echo
echo "ALL TESTS PASSED"
