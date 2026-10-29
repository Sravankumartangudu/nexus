#!/bin/bash
# Gives the personal apps Nexus's fleet styles (the master copies in styles/):
#   styles/FleetStyles.swift      → each Swift app in SWIFT_APPS (the sync with Nexus › 🎨 Style per app)
#   styles/fleet-styles-node.js   → each Electron app in NODE_APPS (the same, for the main process)
#   styles/fleet-styles.css + .js → each page in PAGES, between the markers:
#     /* fleet-styles:begin css */ … /* fleet-styles:end css */   at the END of the page's <style>
#     /* fleet-styles:begin js */  … /* fleet-styles:end js */    in the Settings page's <script> or its .js file (the picker)
# The kit's rules name roles (%card% %btn% …). Each page says which of its own selectors play each role in a comment
# above the css markers, one role a line; a role it leaves out matches nothing:
#   /* fleet-styles:map
#      page: body            bar: header (top bars)     side: sidebars        card: .card, .panel   tile: .tile (small stat boxes)
#      title: .card h3       num: big numbers           nav: tab groups       tab: their buttons    pick: the picked one
#      btn: buttons          primary: the main button   field: inputs         chip: chips, pills, badges
#      vars: --bg=bg --card=card --text=text …          (the page's colour variable = the kit's --st-<name>)
#   */
# The kit itself (styles/fleet-styles.css + .js) has the same rules as the other fleet's kit, byte for byte (only its
# header comment is its own); when those change, copy them into styles/ (keeping this header) and run this.
#   scripts/sync-styles.sh          copy and paste it all in
#   scripts/sync-styles.sh --check  only report what differs (exit 1 if anything does)
set -euo pipefail
mode=""; [ "${1:-}" = "--check" ] && mode="--check"
cd "$(dirname "$0")/.."
SWIFT_APPS="../IdeaForge ../Dharalu/mac"
NODE_APPS="../WaterBuddy ../Stratus"
PAGES="../IdeaForge/board.html ../Dharalu/docs/style.css ../WaterBuddy/renderer/settings.html ../WaterBuddy/renderer/settings.js
       ../Stratus/renderer/css/styles.css ../Stratus/renderer/js/core/fleet-styles.js"

differ=0
copy() {   # copy <master> <dir>
  local to="$2/$(basename "$1")"
  [ -d "$2" ] || { echo "  $2: not here, skipped"; return; }
  if cmp -s "$1" "$to"; then echo "  $to: up to date"
  elif [ -n "$mode" ]; then echo "  $to: DIFFERS"; differ=1
  else cp "$1" "$to"; echo "  $to: updated (rebuild it)"; fi
}
for d in $SWIFT_APPS; do copy styles/FleetStyles.swift "$d"; done
for d in $NODE_APPS; do copy styles/fleet-styles-node.js "$d"; done

/usr/bin/python3 - "$mode" $PAGES <<'PY' || differ=1
import re, sys, os
check, pages = sys.argv[1] == "--check", list(dict.fromkeys(sys.argv[2:]))
css = open("styles/fleet-styles.css").read().strip()
js = open("styles/fleet-styles.js").read().strip()
ROLES = "page bar side card tile title num nav tab pick btn primary field chip".split()
FX = {  # the fx- settings kit's own classes
    "side": ".fx-nav", "card": ".fx-card", "title": ".fx-title", "nav": ".fx-seg",
    "tab": ".fx-seg button, .fx-seg label, .fx-nav button",
    "pick": ".fx-seg button.on, .fx-seg label:has(input:checked), .fx-nav button.on",
    "btn": ".fx-btn", "primary": ".fx-btn.fx-primary",
    "field": ".fx-field, .fx-card input[type=text], .fx-card input[type=number], .fx-card input[type=time], .fx-card select, .fx-card textarea",
}
def expand(src, name):
    m = re.search(r"/\* fleet-styles:map\s*\n(.*?)\*/", src, re.S)
    if not m: raise SystemExit(f"  {name}: has the markers but no fleet-styles:map comment")
    roles, vars_ = {}, []
    for line in m.group(1).splitlines():
        k, _, v = line.strip().partition(":")
        k, v = k.strip(), v.strip()
        if not k: continue
        if k == "vars": vars_ += [p.split("=", 1) for p in v.split()]
        elif k in ROLES: roles[k] = ", ".join(s for s in (roles.get(k, ""), v) if s)
        else: raise SystemExit(f"  {name}: unknown role '{k}' in its fleet-styles:map")
    out = css
    for r in ROLES:
        sel = ", ".join(s for s in (roles.get(r, ""), FX.get(r, "")) if s) or ".st-none"
        out = out.replace(f"%{r}%", sel)
    left = re.findall(r"%[a-z]+%", out)
    if left: raise SystemExit(f"  kit: unknown roles {sorted(set(left))}")
    if vars_:
        out += "\n/* This page's own colour variables, pointed at the style's. */\n:root[data-style]:not([data-style=standard]) { " + \
               " ".join(f"{a}: var(--st-{b});" for a, b in vars_) + " }"
    return out
differ = 0
for p in pages:
    name = os.path.normpath(p)
    if not os.path.isfile(p): print(f"  {name}: not here, skipped"); continue
    src = open(p).read()
    if "fleet-styles:begin" not in src: print(f"  {name}: no markers, skipped"); continue
    body = {"js": js}
    if "fleet-styles:begin css" in src: body["css"] = expand(src, name)      # a script file has only the js half
    out = src
    for k, b in body.items():
        pat = re.compile(r"(/\* fleet-styles:begin %s \*/).*?\n([ \t]*/\* fleet-styles:end %s \*/)" % (k, k), re.S)
        out = pat.sub(lambda m: m.group(1) + "\n" + b + "\n" + m.group(2), out)
    if out == src: print(f"  {name}: up to date"); continue
    if check: print(f"  {name}: DIFFERS"); differ = 1
    else: open(p, "w").write(out); print(f"  {name}: updated (rebuild it)")
sys.exit(differ)
PY
exit $differ
