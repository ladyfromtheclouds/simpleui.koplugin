-- bento_layout.lua — Simple UI Bento Grid
-- Grid layout computation engine.
--
-- Reads per-module width percentages from G_reader_settings and converts a flat
-- list of enabled modules into a list of rows, each containing one or more
-- column descriptors with pixel widths already resolved.
--
-- SETTINGS KEY:  simpleui_bento_width_{module_id}
--   Value range: 20 – 100 (integer, snapped to multiples of 5)
--   Default:     100  (full-width row, identical to the original Simple UI layout)

local UI = require("sui_core")

-- Horizontal pixel gap between columns inside a multi-column row.
-- Reuses Simple UI's standard PAD constant so spacing feels consistent.
local COL_GAP    = UI.PAD
local KEY_PREFIX = "simpleui_bento_width_"

local M = {}

M.COL_GAP    = COL_GAP
M.KEY_PREFIX = KEY_PREFIX

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

-- Clamps a percentage value to [20, 100] and snaps it to the nearest 5 % step.
local function _clampPct(v)
    return math.floor(math.max(20, math.min(100, v)) / 5) * 5
end

-- ---------------------------------------------------------------------------
-- Settings helpers
-- ---------------------------------------------------------------------------

-- Returns the configured width percentage for a module (20–100, default 100).
function M.getModulePct(mod_id)
    local v = G_reader_settings:readSetting(KEY_PREFIX .. mod_id)
    if type(v) ~= "number" then return 100 end
    return _clampPct(v)
end

-- Persists the width percentage for a module.
function M.setModulePct(mod_id, pct)
    G_reader_settings:saveSetting(KEY_PREFIX .. mod_id, _clampPct(pct))
end

-- ---------------------------------------------------------------------------
-- Grid computation
-- ---------------------------------------------------------------------------

-- Returns true when at least one module in the list has a configured width < 100.
function M.needsGrid(mods)
    for _, mod in ipairs(mods) do
        if M.getModulePct(mod.id) < 100 then return true end
    end
    return false
end

-- Converts a flat list of module objects into a list of rows.
--
-- Each row is a list of column descriptors:
--   { mod = <module>, pct = <integer 20-100>, col_w = <pixels> }
--
-- Packing rule (greedy, left-to-right):
--   • A module at 100 % always gets its own full-width row.
--   • Partial-width modules are packed into the current row until they no
--     longer fit (current_pct + new_pct > 100), then a new row is started.
--
-- Pixel widths are assigned proportionally to the declared percentages,
-- with integer arithmetic: the last column in each row absorbs the rounding
-- remainder so the total always equals inner_w.
--
-- @param mods     ordered list of module objects (each has .id field)
-- @param inner_w  available pixel width for content
-- @return         list of rows (see above)
function M.computeRows(mods, inner_w)
    local rows    = {}
    local cur_row = {}
    local cur_pct = 0

    for _, mod in ipairs(mods) do
        local pct = M.getModulePct(mod.id)

        if pct >= 100 then
            -- Full-width module — flush any partial row first, then its own row.
            if #cur_row > 0 then
                rows[#rows + 1] = cur_row
                cur_row  = {}
                cur_pct  = 0
            end
            rows[#rows + 1] = { { mod = mod, pct = 100 } }
        else
            if cur_pct + pct <= 100 then
                cur_row[#cur_row + 1] = { mod = mod, pct = pct }
                cur_pct = cur_pct + pct
                -- Row is exactly full — flush it.
                if cur_pct >= 100 then
                    rows[#rows + 1] = cur_row
                    cur_row  = {}
                    cur_pct  = 0
                end
            else
                -- Doesn't fit in current row — flush and start a fresh one.
                if #cur_row > 0 then
                    rows[#rows + 1] = cur_row
                end
                cur_row  = { { mod = mod, pct = pct } }
                cur_pct  = pct
            end
        end
    end

    -- Flush any remaining partial row.
    if #cur_row > 0 then
        rows[#rows + 1] = cur_row
    end

    -- Resolve pixel widths for every column in every row.
    for _, row in ipairs(rows) do
        if #row == 1 then
            -- Single column (full-width or a lone partial): always gets inner_w.
            row[1].col_w = inner_w
        else
            -- Multiple columns: distribute available width proportionally.
            local n_gaps    = #row - 1
            local avail     = inner_w - n_gaps * COL_GAP
            local total_pct = 0
            for _, col in ipairs(row) do total_pct = total_pct + col.pct end

            local assigned = 0
            for i, col in ipairs(row) do
                if i < #row then
                    col.col_w = math.floor(avail * col.pct / total_pct)
                    assigned  = assigned + col.col_w
                else
                    -- Last column absorbs rounding remainder.
                    col.col_w = avail - assigned
                end
            end
        end
    end

    return rows
end

return M
