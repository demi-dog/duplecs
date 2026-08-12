-- Fetches the jecs release duplecs is developed against into
-- roblox_packages/jecs.luau, which is where duplecs.luau requires it from
-- (the same path pesde links for consumers). Run once before the tests:
--
--   lune run tests/setup.luau
--
-- Re-run it to restore the file if a `pesde install` in this repo replaced
-- it with a Roblox-only linker stub.
--
-- Keep the tag in sync with the jecs version constraint in pesde.toml.

local JECS_TAG = "v0.11.0"

local fs = require("@lune/fs")
local net = require("@lune/net")
local process = require("@lune/process")

-- the module moved from jecs.luau to src/jecs.luau upstream between 0.9.0 and 0.11.0
local url = `https://raw.githubusercontent.com/Ukendio/jecs/{JECS_TAG}/src/jecs.luau`

print(`fetching jecs {JECS_TAG} from {url}`)
local response = net.request(url)
if not response.ok then
	print(`fetch failed: HTTP {response.statusCode}`)
	process.exit(1)
end

if not fs.isDir("roblox_packages") then
	fs.writeDir("roblox_packages")
end

-- Remove the old file rather than overwriting it in place: roblox_packages is
-- pesde-managed, and writing through an existing path poisons pesde's
-- cross-project file cache.
if fs.isFile("roblox_packages/jecs.luau") then
	fs.removeFile("roblox_packages/jecs.luau")
end
fs.writeFile("roblox_packages/jecs.luau", response.body)
print(`wrote roblox_packages/jecs.luau ({#response.body} bytes)`)
