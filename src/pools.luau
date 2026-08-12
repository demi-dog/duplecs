--!strict
--!native
--!optimize 2

-- the server's recycling pools, one set per instance (constructed by create_server): a generic pool of
-- scratch tables, and the draft / run pools backing the section shapes wire.luau encodes. server.luau owns
-- what the pooled tables are used *for*; this module owns their lifecycle -- fetches, clearing releases, and
-- the escaped side-array exception threaded through release_draft.

local wire = require("./wire")

type SectionDraft = wire.SectionDraft
type SectionRun = wire.SectionRun

return function()
	-- generic scratch tables, shared by every per-frame list the packet passes build. release clears
	-- immediately, so a pooled table never pins user component values between frames.
	local scratch_pool = {} :: { any }
	local scratch_pool_count = 0

	local function fetch_scratch(): any
		if scratch_pool_count == 0 then
			return {}
		end
		local scratch = scratch_pool[scratch_pool_count]
		scratch_pool[scratch_pool_count] = nil
		scratch_pool_count -= 1
		return scratch
	end

	local function release_scratch(scratch: any)
		table.clear(scratch)
		scratch_pool_count += 1
		scratch_pool[scratch_pool_count] = scratch
	end

	-- section drafts and runs pool separately so record-shaped tables never mix with array reuse. escaped
	-- threads finalize_section's side-array return through the releases: whichever values list left in a packet
	-- by reference (the one escape -- see the Packet type) must not be pooled, while inlined or
	-- concatenated-away lists recycle like the others.
	local draft_pool = {} :: { SectionDraft }
	local draft_pool_count = 0

	local run_pool = {} :: { SectionRun }
	local run_pool_count = 0

	local function fetch_draft(component: number?, relation: number?): SectionDraft
		if draft_pool_count == 0 then
			return {
				component = component,
				relation = relation,
			}
		end
		local draft = draft_pool[draft_pool_count]
		draft_pool[draft_pool_count] = nil
		draft_pool_count -= 1
		draft.component = component
		draft.relation = relation
		return draft
	end

	local function fetch_run(target: number): SectionRun
		if run_pool_count == 0 then
			return {
				target = target,
			}
		end
		local run = run_pool[run_pool_count]
		run_pool[run_pool_count] = nil
		run_pool_count -= 1
		run.target = target
		return run
	end

	local function release_run(run: SectionRun, escaped: { any }?)
		local ids = run.ids
		if ids then
			release_scratch(ids)
		end
		local values = run.values
		if values and values ~= escaped then
			release_scratch(values)
		end
		local nulled = run.nulled
		if nulled then
			release_scratch(nulled)
		end
		local removed = run.removed
		if removed then
			release_scratch(removed)
		end
		table.clear(run)
		run_pool_count += 1
		run_pool[run_pool_count] = run
	end

	local function release_draft(draft: SectionDraft, escaped: { any }?)
		local ids = draft.ids
		if ids then
			release_scratch(ids)
		end
		local values = draft.values
		if values and values ~= escaped then
			release_scratch(values)
		end
		local nulled = draft.nulled
		if nulled then
			release_scratch(nulled)
		end
		local removed = draft.removed
		if removed then
			release_scratch(removed)
		end
		local runs = draft.runs
		if runs then
			for _, run in runs do
				release_run(run, escaped)
			end
			release_scratch(runs)
		end
		local run_of = draft.run_of
		if run_of then
			release_scratch(run_of)
		end
		table.clear(draft)
		draft_pool_count += 1
		draft_pool[draft_pool_count] = draft
	end

	-- one run per target within a pair draft, keyed by the gen-qualified target the group rows carry. runs are
	-- only ever fetched here, so run recycling never leaks past this module.
	local function get_run(draft: SectionDraft, target: number): SectionRun
		local run_of = draft.run_of
		if run_of == nil then
			run_of = fetch_scratch()
			draft.run_of = run_of
		end
		local runs_by_target = run_of :: { [number]: SectionRun }
		local run = runs_by_target[target]
		if run == nil then
			run = fetch_run(target)
			runs_by_target[target] = run
			local runs = draft.runs
			if runs == nil then
				runs = fetch_scratch()
				draft.runs = runs
			end
			table.insert(runs :: { SectionRun }, run)
		end
		return run
	end

	return {
		fetch_scratch = fetch_scratch,
		release_scratch = release_scratch,
		fetch_draft = fetch_draft,
		release_draft = release_draft,
		get_run = get_run,
	}
end
