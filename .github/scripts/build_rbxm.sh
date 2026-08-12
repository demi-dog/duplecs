#!/usr/bin/env bash
# builds the studio release artifact: the staged wally tree (wally_stage.sh --
# the identical instance shape the wally linker validation proved in-engine)
# with the jecs shim swapped for a studio stub, rojo-built into <output>.
#
# the stub errors with redirect instructions instead of resolving a link
# module: the studio user IS the linker. it must be replaced -- not filled in
# -- with `return require(<their jecs>)` so the redirected require stays a
# static instance require the type solver can follow; a set-a-variable stub
# would make the require dynamic and drop jecs's types. the artifact bundles
# no jecs of its own because duplecs and the game's code must share one jecs
# installation (the foreign-instance guard exists for exactly that mistake).

set -euo pipefail

out="${1:?usage: build_rbxm.sh <output.rbxm>}"

staging="$(mktemp -d)"
bash "$(dirname "$0")/wally_stage.sh" "${staging}" >/dev/null

cat > "${staging}/roblox_packages/jecs.luau" <<'EOF'
-- duplecs's jecs dependency. duplecs and your own code must share one jecs
-- installation, so this file does not bundle one: REPLACE the error line
-- below with a require of your project's jecs ModuleScript (any jecs
-- matching ^0.11.0), for example:
--
--   return require(game.ReplicatedStorage.jecs)
--
error(
	"[duplecs] this rbxm install needs its jecs require redirected -- open duplecs > roblox_packages > jecs and follow its comment"
)
EOF

rojo build "${staging}/default.project.json" -o "${out}"
echo "built ${out}"
