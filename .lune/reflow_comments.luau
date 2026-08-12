-- Rewraps standalone prose comment paragraphs in a .luau file to a wider column budget, to cut
-- lines spent on comments without touching their wording. Run from the repo root:
--
--   lune run .lune/reflow_comments.luau <file> <max_width>
--
-- A paragraph is a maximal run of `-- text` lines sharing one indentation, bounded by a blank
-- line, a code line, or another paragraph at a different indentation. Lines whose text has two or
-- more consecutive spaces are left untouched instead of merged into a paragraph -- that spacing
-- means column-aligned layout (e.g. wire.luau's wire-format tables), not prose. `--!` directives
-- never match (no space after the second dash) and are left alone too. A standalone "--" (used as
-- a mid-sentence em dash) is never placed at the start of a wrapped line, since `-- -- text` reads
-- as a doubled comment marker; it stays glued to the line it follows instead.

local fs = require("@lune/fs")
local process = require("@lune/process")

local file_path = process.args[1]
local max_width = tonumber(process.args[2])

if not file_path or not max_width then
	print("usage: lune run .lune/reflow_comments.luau <file> <max_width>")
	process.exit(1)
end

local function split_lines(s: string): { string }
	local lines = {}
	local start = 1
	while true do
		local newline = string.find(s, "\n", start, true)
		if not newline then
			table.insert(lines, string.sub(s, start))
			break
		end
		table.insert(lines, string.sub(s, start, newline - 1))
		start = newline + 1
	end
	return lines
end

local function wrap_paragraph(indent: string, words: { string }, prefix_len: number): { string }
	local budget = max_width - #indent - prefix_len
	local out = {}
	local current = {}
	local current_len = 0
	for _, word in words do
		if word == "--" and #current > 0 then
			table.insert(current, word)
			current_len += 1 + #word
			continue
		end
		local add_len = if #current == 0 then #word else current_len + 1 + #word
		if #current > 0 and add_len > budget then
			table.insert(out, table.concat(current, " "))
			current = { word }
			current_len = #word
		else
			table.insert(current, word)
			current_len = add_len
		end
	end
	if #current > 0 then
		table.insert(out, table.concat(current, " "))
	end
	for i, text in out do
		out[i] = `{indent}-- {text}`
	end
	return out
end

local lines = split_lines(fs.readFile(file_path))
local result = {}
local paragraph_indent = nil :: string?
local paragraph_lines = {}

local function flush()
	if #paragraph_lines == 0 then
		return
	end
	local words = {}
	for _, text in paragraph_lines do
		for word in text:gmatch("%S+") do
			table.insert(words, word)
		end
	end
	for _, wrapped in wrap_paragraph(paragraph_indent :: string, words, 3) do
		table.insert(result, wrapped)
	end
	paragraph_lines = {}
	paragraph_indent = nil
end

for _, line in lines do
	local indent, text = line:match("^(\t*)%-%- (.+)$")
	if not indent then
		flush()
		table.insert(result, line)
	elseif text:find("%s%s") then
		flush()
		table.insert(result, line)
	else
		if #paragraph_lines > 0 and indent ~= paragraph_indent then
			flush()
		end
		paragraph_indent = indent
		table.insert(paragraph_lines, text)
	end
end
flush()

fs.writeFile(file_path, table.concat(result, "\n"))
