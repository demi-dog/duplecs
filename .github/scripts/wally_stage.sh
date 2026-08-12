#!/usr/bin/env bash
# stages the tree `wally publish` (and any local `wally package` free check)
# must run against: a pristine copy of the *tracked* files -- the live tree
# carries fetched jecs, pesde install output, and CI action logs, and wally
# packs whatever sits on disk -- plus the wally-only consumption arrangement.
#
# the arrangement exists because wally's generated consumer link requires the
# package-named instance directly (require(Packages._Index["<scope>_<name>@<v>"]
# ["<name>"])), so that instance must be a ModuleScript, and because nothing on
# the wally side materializes roblox_packages/jecs at the path the sources
# require jecs through. three files, none of which live in the repo tree
# (roblox_packages/ is pesde-managed; the others are dead weight pesde never
# ships):
#
#   default.project.json  mounts a redirect module as the package root, with
#                         src and the shim folder as its children (wally
#                         rewrites the project's name to the package name at
#                         pack time; it is still set correctly here for local
#                         inspection)
#   wally_root.luau       the redirect: the package-named ModuleScript wally's
#                         link requires, re-exporting src
#   roblox_packages/jecs.luau  gives ../roblox_packages/jecs something to
#                         resolve to: from the shim, .Parent.Parent.Parent is
#                         the _Index version folder, whose `jecs` child is the
#                         link module wally generates for the dependency
#
# under this mount, ../roblox_packages/jecs from a src file resolves
# src -> parent (the redirect root) -> roblox_packages -> jecs, the same walk
# the pesde layout's links take.

set -euo pipefail

staging="${1:?usage: wally_stage.sh <staging-dir>}"

git checkout-index --all --prefix="${staging%/}/"

name="$(grep -m 1 '^name = ' "${staging}/wally.toml" | cut -d '"' -f 2)"
bare="${name##*/}"

cat > "${staging}/default.project.json" <<EOF
{
	"name": "${bare}",
	"tree": {
		"\$path": "wally_root.luau",
		"src": { "\$path": "src" },
		"roblox_packages": { "\$path": "roblox_packages" }
	}
}
EOF

cat > "${staging}/wally_root.luau" <<'EOF'
-- the package root wally's generated link requires; the real module is src
return require(script:FindFirstChild("src"))
EOF

mkdir -p "${staging}/roblox_packages"
cat > "${staging}/roblox_packages/jecs.luau" <<'EOF'
-- resolves the sources' ../roblox_packages/jecs require to the link module
-- wally generates beside this package in the consumer's _Index version folder
return require(script.Parent.Parent.Parent:FindFirstChild("jecs"))
EOF

echo "staged ${name} for wally at ${staging}"
