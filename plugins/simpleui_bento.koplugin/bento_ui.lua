-- bento_ui.lua — Simple UI Bento Grid
-- UI helpers: SpinWidget-based menu item for per-module width configuration.

local M = {}

-- Creates a KOReader menu-item table that opens a SpinWidget for choosing
-- the bento grid width of a specific module.
--
-- @param mod_id   string  — the module's stable ID (e.g. "clock", "recently")
-- @param ctx_menu table   — the context menu table passed to mod.getMenuItems()
-- @return         table   — a KOReader menu item ready to be appended to items
function M.addBentoWidthMenuItem(mod_id, ctx_menu)
    local Layout = require("bento_layout")
    return {
        text_func = function()
            local pct = Layout.getModulePct(mod_id)
            return string.format("Bento Grid Width (%d%%)", pct)
        end,
        keep_menu_open = true,
        separator      = true,
        callback = function()
            local UIManager  = require("ui/uimanager")
            local SpinWidget = require("ui/widget/spinwidget")
            local cur_pct    = Layout.getModulePct(mod_id)
            UIManager:show(SpinWidget:new{
                title_text    = "Bento Grid Width",
                info_text     = "Width of this module on the homescreen.\n"
                                .. "50 = half a row, 100 = full row.",
                value         = cur_pct,
                value_min     = 20,
                value_max     = 100,
                value_step    = 5,
                unit          = "%",
                ok_text       = "Apply",
                cancel_text   = "Cancel",
                default_value = 100,
                callback = function(spin)
                    Layout.setModulePct(mod_id, spin.value)
                    if type(ctx_menu.refresh) == "function" then
                        ctx_menu.refresh()
                    end
                end,
            })
        end,
    }
end

return M
