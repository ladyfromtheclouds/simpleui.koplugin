-- main.lua — Simple UI Bento Grid Plugin
--
-- Hooks Simple UI's homescreen at runtime to transform the portrait single-column
-- layout into a configurable bento grid without modifying Simple UI's own source.
--
-- STRATEGY
-- ① On init(), require sui_homescreen and wrap Homescreen.show() so that every
--   new homescreen instance gets its _updatePage() method wrapped.
-- ② The wrapped _updatePage() calls the original first (warming all caches and
--   building the normal portrait layout), then — when portrait mode is active
--   and at least one module is configured below 100 % — clears the body and
--   rebuilds it using the grid rows produced by bento_layout.computeRows().
-- ③ Modules are rebuilt at their target column width by calling mod.build()
--   again with the correct pixel width.  This is safe because build() uses the
--   ctx table (already cached) so no extra DB / disk I/O occurs.
-- ④ The clock surgical-tick contract (_clock_body_ref / _clock_body_idx /
--   _clock_is_wrapped) is maintained during the rebuild.
-- ⑤ Registry.get() is wrapped to inject a "Bento Grid Width" SpinWidget item
--   into every module's settings menu.
-- ⑥ All patches are stored and restored on teardown so the plugin can be
--   safely enabled/disabled without restarting KOReader.

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger          = require("logger")

local BentoPlugin = WidgetContainer:new{
    name            = "simpleui_bento",
    _active         = false,
    _orig_show      = nil,           -- saved Homescreen.show
    _orig_reg_get   = nil,           -- saved Registry.get
    _orig_menus     = nil,           -- map mod_id → original getMenuItems fn
}

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function BentoPlugin:init()
    local ok, err = pcall(function() self:_hookSimpleUI() end)
    if not ok then
        logger.warn("simpleui_bento: init failed: " .. tostring(err))
    end
end

function BentoPlugin:onCloseWidget()
    local ok, err = pcall(function() self:_teardown() end)
    if not ok then
        logger.warn("simpleui_bento: teardown failed: " .. tostring(err))
    end
end

-- ---------------------------------------------------------------------------
-- Hook installation
-- ---------------------------------------------------------------------------

function BentoPlugin:_hookSimpleUI()
    -- Require Simple UI's homescreen module.
    local ok_hs, Homescreen = pcall(require, "sui_homescreen")
    if not ok_hs or type(Homescreen) ~= "table" or type(Homescreen.show) ~= "function" then
        logger.warn("simpleui_bento: sui_homescreen not available — bento grid inactive")
        return
    end

    -- Wrap Homescreen.show so that new instances get their _updatePage patched.
    local orig_show   = Homescreen.show
    self._orig_show   = orig_show
    local plugin      = self

    Homescreen.show = function(on_qa_tap, on_goal_tap)
        local result = orig_show(on_qa_tap, on_goal_tap)
        -- Homescreen._instance is the freshly created widget.
        plugin:_patchInstance(Homescreen._instance)
        return result
    end

    -- Patch any instance that is already alive (e.g. plugin enabled at runtime).
    if Homescreen._instance then
        self:_patchInstance(Homescreen._instance)
    end

    -- Hook Registry to inject the width menu item into every module.
    local ok_reg, Registry = pcall(require, "desktop_modules/moduleregistry")
    if ok_reg and type(Registry) == "table" then
        self:_hookRegistry(Registry)
    end

    self._active = true
end

-- ---------------------------------------------------------------------------
-- Per-instance _updatePage wrapper
-- ---------------------------------------------------------------------------

function BentoPlugin:_patchInstance(inst)
    if not inst or inst._bento_patched then return end

    local orig_updatePage = inst._updatePage
    if type(orig_updatePage) ~= "function" then return end

    local plugin = self

    inst._updatePage = function(self_hs, keep_cache, books_only)
        -- Let Simple UI build the page normally — this warms all caches.
        orig_updatePage(self_hs, keep_cache, books_only)
        -- Post-process with bento grid (portrait only).
        local ok, err = pcall(plugin._applyBentoLayout, plugin, self_hs)
        if not ok then
            logger.warn("simpleui_bento: layout error: " .. tostring(err))
        end
    end

    inst._bento_patched = true
end

-- ---------------------------------------------------------------------------
-- Grid layout post-processor
-- ---------------------------------------------------------------------------

function BentoPlugin:_applyBentoLayout(hs)
    local Screen = require("device").screen

    -- Landscape mode already has its own two-column layout in Simple UI —
    -- leave it entirely untouched.
    if Screen:getWidth() > Screen:getHeight() then return end

    local Layout   = require("bento_layout")
    local body     = hs._body
    if not body then return end

    local cache = hs._enabled_mods_cache
    if not cache then return end

    local cur_page     = hs._current_page or 1
    local pages        = cache.pages_of_mods
    local cur_page_mods = pages and pages[cur_page]
    if not cur_page_mods or #cur_page_mods == 0 then return end

    -- Nothing to do when every module is at 100 % (normal Simple UI behaviour).
    if not Layout.needsGrid(cur_page_mods) then return end

    local ctx = hs._ctx_cache
    if not ctx then return end

    local UI      = require("sui_core")
    local inner_w = hs._layout_inner_w or (Screen:getWidth() - UI.SIDE_PAD * 2)
    local mod_gaps = cache.mod_gaps or {}
    local MOD_GAP  = UI.MOD_GAP

    -- Preserve the dithering flag (set by the original _updatePage based on
    -- which cover modules are on this page — unchanged by our rebuild).
    local dithered = hs.dithered

    -- Compute grid rows.
    local rows = Layout.computeRows(cur_page_mods, inner_w)

    -- Replace body content with the new grid layout.
    body:clear()

    -- ── Top padding (mirrors original _updatePage) ────────────────────────
    local topbar_on = G_reader_settings:nilOrTrue("navbar_topbar_enabled")
    local top_pad   = topbar_on and MOD_GAP or (MOD_GAP * 2)
    body[#body + 1] = hs:_vspan(top_pad)

    -- Reset clock / header tracking fields.
    hs._clock_body_idx    = nil
    hs._clock_body_ref    = body
    hs._clock_is_wrapped  = false
    hs._header_body_idx   = nil
    hs._header_body_ref   = body
    hs._header_is_wrapped = false

    -- ── Build grid rows ───────────────────────────────────────────────────
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local VerticalGroup   = require("ui/widget/verticalgroup")
    local HorizontalSpan  = require("ui/widget/horizontalspan")
    local COL_GAP         = Layout.COL_GAP

    local first_row = true

    for _, row in ipairs(rows) do
        -- Inter-row gap: use the gap configured for the first module in the row.
        if first_row then
            first_row = false
        else
            local gap_px = mod_gaps[row[1].mod.id] or MOD_GAP
            body[#body + 1] = hs:_vspan(gap_px)
        end

        if #row == 1 then
            -- ── Single-column row ─────────────────────────────────────────
            local col = row[1]
            local mod = col.mod
            local ok_w, widget = pcall(mod.build, col.col_w, ctx)
            if ok_w and widget then
                local has_menu = type(mod.getMenuItems) == "function"

                if mod.label and ctx.sectionLabel then
                    body[#body + 1] = ctx.sectionLabel(mod.label, col.col_w)
                end

                if mod.id == "header" then
                    hs._header_body_idx   = #body + 1
                    hs._header_body_ref   = body
                    hs._header_is_wrapped = has_menu
                end
                if mod.id == "clock" then
                    hs._clock_body_idx   = #body + 1
                    hs._clock_body_ref   = body
                    hs._clock_is_wrapped = has_menu
                end

                if has_menu then
                    body[#body + 1] = hs:_makeModWrapper(mod, widget, col.col_w)
                else
                    body[#body + 1] = widget
                end
            end
        else
            -- ── Multi-column row ──────────────────────────────────────────
            local h_group = HorizontalGroup:new{ align = "top" }

            for i, col in ipairs(row) do
                local mod  = col.mod
                local ok_w, widget = pcall(mod.build, col.col_w, ctx)
                if ok_w and widget then
                    local has_menu    = type(mod.getMenuItems) == "function"
                    local entry       = has_menu
                        and hs:_makeModWrapper(mod, widget, col.col_w)
                        or  widget

                    -- Wrap in a VerticalGroup so the column can grow vertically
                    -- if stacking is needed in future and to give HorizontalGroup
                    -- a stable child type.
                    local v_group = VerticalGroup:new{ align = "left" }

                    if mod.label and ctx.sectionLabel then
                        v_group[#v_group + 1] = ctx.sectionLabel(mod.label, col.col_w)
                    end

                    v_group[#v_group + 1] = entry

                    -- Track the clock widget for the surgical minute-tick swap.
                    if mod.id == "clock" then
                        hs._clock_body_ref   = v_group
                        hs._clock_body_idx   = #v_group
                        hs._clock_is_wrapped = has_menu
                    end
                    if mod.id == "header" then
                        hs._header_body_ref   = v_group
                        hs._header_body_idx   = #v_group
                        hs._header_is_wrapped = has_menu
                    end

                    h_group[#h_group + 1] = v_group
                    if i < #row then
                        h_group[#h_group + 1] = HorizontalSpan:new{ width = COL_GAP }
                    end
                end
            end

            -- Only add the row if at least one column succeeded.
            if #h_group > 0 then
                body[#body + 1] = h_group
            end
        end
    end

    -- Restore the dithering hint (needed for e-ink cover refresh cycles).
    hs.dithered = dithered
end

-- ---------------------------------------------------------------------------
-- Registry hook — inject "Bento Grid Width" into every module's menu
-- ---------------------------------------------------------------------------

function BentoPlugin:_hookRegistry(Registry)
    self._orig_menus  = {}
    self._orig_reg_get = Registry.get

    local plugin = self

    -- Patch all already-loaded modules immediately.
    local ok_list, mods = pcall(Registry.list)
    if ok_list and type(mods) == "table" then
        for _, mod in ipairs(mods) do
            plugin:_patchModuleMenu(mod)
        end
    end

    -- Wrap Registry.get so that any future loads are also patched.
    Registry.get = function(id, ...)
        local mod = plugin._orig_reg_get(id, ...)
        if mod then plugin:_patchModuleMenu(mod) end
        return mod
    end
end

function BentoPlugin:_patchModuleMenu(mod)
    if not mod or type(mod.id) ~= "string" then return end
    -- Guard: only patch once, only modules with a settings menu, and only when
    -- _orig_menus has been initialised (i.e. _hookRegistry already ran).
    if not self._orig_menus then return end
    if self._orig_menus[mod.id] then return end
    if type(mod.getMenuItems) ~= "function" then return end

    local orig   = mod.getMenuItems
    local mod_id = mod.id
    local BentoUI = require("bento_ui")

    self._orig_menus[mod_id] = orig

    mod.getMenuItems = function(ctx_menu)
        local items = orig(ctx_menu)
        if type(items) ~= "table" then items = {} end
        items[#items + 1] = BentoUI.addBentoWidthMenuItem(mod_id, ctx_menu)
        return items
    end
end

-- ---------------------------------------------------------------------------
-- Clean teardown
-- ---------------------------------------------------------------------------

function BentoPlugin:_teardown()
    if not self._active then return end

    -- Restore Homescreen.show.
    local ok_hs, Homescreen = pcall(require, "sui_homescreen")
    if ok_hs and type(Homescreen) == "table" and self._orig_show then
        Homescreen.show = self._orig_show
        self._orig_show = nil
        -- Remove the instance patch flag so a subsequent init() works correctly.
        if Homescreen._instance then
            Homescreen._instance._bento_patched = nil
        end
    end

    -- Restore Registry.get.
    local ok_reg, Registry = pcall(require, "desktop_modules/moduleregistry")
    if ok_reg and type(Registry) == "table" and self._orig_reg_get then
        Registry.get = self._orig_reg_get
        self._orig_reg_get = nil
    end

    -- Restore module getMenuItems functions.
    if self._orig_menus then
        if ok_reg and type(Registry) == "table" then
            local ok_list, mods = pcall(Registry.list)
            if ok_list and type(mods) == "table" then
                for _, mod in ipairs(mods) do
                    local orig = self._orig_menus[mod.id]
                    if orig then
                        mod.getMenuItems = orig
                    end
                end
            end
        end
        self._orig_menus = nil
    end

    self._active = false
end

return BentoPlugin
