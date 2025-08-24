-- Working version FINAL
--[[
    file: Core-Latex-Renderer
    title: Rendering LaTeX with snacks.nvim
    summary: A module for rendering latex images inline using snacks.nvim.
    ---

This module requires nvim 0.10+. It renders LaTeX snippets as images, making use of the
snacks.nvim plugin. By default, images are only rendered after running the command:
`:Neorg render-latex`. Rendering can be disabled with `:Neorg render-latex disable`.

Requires:
- The [snacks.nvim](https://github.com/pysan3/snacks.nvim) neovim plugin.
- `tectonic` or `pdflatex` executable in path.
- `magick` (ImageMagick) executable in path for image conversion.

There's a highlight group that controls the foreground color of the rendered latex:
`@norg.rendered.latex`, configurable in `core.highlights`
--]]
local neorg = require("neorg.core")
local module = neorg.modules.create("core.latex.renderer")
local modules = neorg.modules

local placement

module.setup = function()
    return {
        requires = {
            "core.integrations.treesitter",
            "core.autocommands",
            "core.neorgcmd",
            "core.highlights",
        },
    }
end

module.config.public = {
    -- When true, images of rendered LaTeX will cover the source LaTeX they were produced from.
    conceal = true,

    -- The rendering density for the LaTeX image, similar to DPI.
    -- Higher values result in crisper images at the expense of performance.
    density = 300,

    -- When true, images will render when a `.norg` buffer is entered.
    render_on_enter = false,

    -- Don't re-render anything until 200ms after the buffer has stopped changing.
    debounce_ms = 200,

    -- Only render latex snippets that are longer than this many chars.
    -- Delimiters like `$|` are not counted.
    min_length = 3,
}

---Compute and set the foreground color hex string for LaTeX rendering.
local function compute_foreground()
    local neorg_hi = neorg.modules.get_module("core.highlights")
    assert(neorg_hi, "Failed to load core.highlights")
    local hi = vim.api.nvim_get_hl(0, { name = "@norg.rendered.latex", link = false })

    if not vim.tbl_isempty(hi) and hi.fg then
        module.private.foreground_hex = ("%06x"):format(hi.fg):upper()
    else
        -- Use a sensible default that works on both light and dark backgrounds.
        -- Users can override this with the highlight group.
        module.private.foreground_hex = vim.o.background == "dark" and "FFFFFF" or "000000"
    end
end

---Creates a full LaTeX document source from a math snippet.
---@param snippet string The raw math snippet from the buffer.
---@return string The full LaTeX source code.
local function create_latex_source(snippet)
    local fg_hex = module.private.foreground_hex
    local content = vim.trim(snippet or "")

    -- Clean the snippet from neorg's delimiters
    content = string.gsub(content, "^%$|", "")
    content = string.gsub(content, "|%$$", "")
    content = string.gsub(content, "^%$", "")
    content = string.gsub(content, "%$$", "")

    -- Ensure it's in a display math environment for consistent rendering
    if not string.find(content, "\\begin") then
        content = ("\\[ %s \\]"):format(content)
    end

    -- A standard LaTeX template, inspired by snacks.nvim's own template
    local template = [[
        \documentclass[preview,border=1pt,varwidth=500pt,12pt]{standalone}
        \usepackage{amsmath, amssymb, amsfonts, amscd, mathtools, xcolor}
        \begin{document}
        { \Large \selectfont
          \color[HTML]{${color}}
        ${content}}
        \end{document}
    ]]

    return template:gsub("${color}", fg_hex):gsub("${content}", content)
end

module.load = function()
    local snacks_ok, snacks_placement = pcall(require, "snacks.image.placement")
    if not snacks_ok then
        vim.notify("Neorg: core.latex.renderer requires 'pysan3/snacks.nvim' to be installed.", vim.log.levels.ERROR)
        return
    end
    placement = snacks_placement

    -- ******* THIS IS THE FIX *******
    -- We are overriding snacks's default PDF-to-PNG conversion to ensure a transparent background.
    -- This is the correct way to fix the white background issue.
    local snacks_image = require("snacks.image")
    local magick_args = {
        "-density",
        module.config.public.density,
        "{src}[0]",
        "-background",
        "none", -- The crucial flag for transparency
        "-trim",
    }
    snacks_image.config.convert.magick.pdf = magick_args
    snacks_image.config.convert.magick.math = magick_args
    -- *******************************

    compute_foreground()

    module.private.cache_dir = vim.fn.stdpath("cache") .. "/neorg/latex/"
    vim.fn.mkdir(module.private.cache_dir, "p", 0755)

    module.private.placements = {} ---@type table<number, table<string, any>>
    module.private.hidden_by_cursor = {} ---@type table<number, table<string, boolean>>
    module.private.do_render = module.config.public.render_on_enter

    module.required["core.autocommands"].enable_autocommand("BufWinEnter")
    module.required["core.autocommands"].enable_autocommand("CursorMoved")
    module.required["core.autocommands"].enable_autocommand("TextChanged")
    module.required["core.autocommands"].enable_autocommand("InsertLeave")
    module.required["core.autocommands"].enable_autocommand("Colorscheme")

    modules.await("core.neorgcmd", function(neorgcmd)
        neorgcmd.add_commands_from_table({
            ["render-latex"] = {
                name = "latex.render.render",
                min_args = 0,
                max_args = 1,
                subcommands = {
                    enable = { args = 0, name = "latex.render.enable" },
                    disable = { args = 0, name = "latex.render.disable" },
                    toggle = { args = 0, name = "latex.render.toggle" },
                },
                condition = "norg",
            },
        })
    end)
end

function module.private.update_placements(buf)
    if not module.private.do_render then
        return
    end

    local active_nodes = {}
    local current_placements = module.private.placements[buf] or {}
    module.private.placements[buf] = current_placements

    module.required["core.integrations.treesitter"].execute_query(
        [[
            (
                (inline_math) @latex
                (#offset! @latex 0 1 0 -1)
            )
        ]],
        function(query, id, node)
            if query.captures[id] ~= "latex" then
                return
            end

            local node_id = tostring(node:id())
            active_nodes[node_id] = true

            if current_placements[node_id] then
                return
            end

            local snippet = module.required["core.integrations.treesitter"].get_node_text(node, buf)

            if #snippet < module.config.public.min_length + 2 then
                return
            end

            local tex_source = create_latex_source(snippet)
            local source_hash = vim.fn.sha256(tex_source)
            local tex_file = module.private.cache_dir .. source_hash:sub(1, 12) .. ".tex"

            if vim.fn.filereadable(tex_file) == 0 then
                vim.fn.writefile(vim.split(tex_source, "\n"), tex_file)
            end

            local range = { node:range() }
            local pos = { range[1] + 1, range[2] }

            local new_placement = placement.new(buf, tex_file, {
                pos = pos,
                range = { range[1] + 1, range[2], range[3] + 1, range[4] },
                inline = true,
                conceal = module.config.public.conceal,
                type = "math",
            })

            if new_placement then
                current_placements[node_id] = new_placement
            end
        end,
        buf
    )

    -- Clean up placements for nodes that no longer exist
    for node_id, p in pairs(current_placements) do
        if not active_nodes[node_id] then
            p:close()
            current_placements[node_id] = nil
        end
    end
end

local render_timer = nil
local function render_latex()
    local buf = vim.api.nvim_get_current_buf()
    if not module.private.do_render then
        if render_timer then
            render_timer:stop()
            render_timer:close()
            render_timer = nil
        end
        return
    end

    if render_timer then
        render_timer:stop()
    else
        render_timer = vim.uv.new_timer()
    end

    render_timer:start(module.config.public.debounce_ms, 0, function()
        render_timer:stop()
        render_timer:close()
        render_timer = nil

        vim.schedule(function()
            module.private.update_placements(buf)
        end)
    end)
end

local function clear_at_cursor()
    local buf = vim.api.nvim_get_current_buf()
    if not module.private.do_render or render_timer or not module.private.placements[buf] then
        return
    end

    local cursor_row = vim.api.nvim_win_get_cursor(0)[1]
    local placements_on_line = {}

    for id, p in pairs(module.private.placements[buf]) do
        local p_range = p.opts.range
        if p_range and cursor_row >= p_range[1] and cursor_row <= p_range[3] then
            placements_on_line[id] = true
        end
    end

    local previously_hidden = module.private.hidden_by_cursor[buf] or {}
    module.private.hidden_by_cursor[buf] = placements_on_line

    for id, p in pairs(module.private.placements[buf]) do
        if placements_on_line[id] and not previously_hidden[id] then
            p:hide()
        elseif not placements_on_line[id] and previously_hidden[id] then
            p:show()
        end
    end
end

local function show_all_placements(buf)
    if module.private.do_render and module.private.placements[buf] then
        for _, p in pairs(module.private.placements[buf]) do
            p:show()
        end
    end
    module.private.hidden_by_cursor[buf] = {}
end

local function disable_rendering()
    module.private.do_render = false
    for buf, placements_table in pairs(module.private.placements) do
        if placements_table then
            for _, p in pairs(placements_table) do
                p:close()
            end
        end
        module.private.placements[buf] = nil
    end
end

local function enable_rendering()
    module.private.do_render = true
    render_latex()
end

local function toggle_rendering()
    if module.private.do_render then
        disable_rendering()
    else
        enable_rendering()
    end
end

local function colorscheme_change()
    compute_foreground()

    -- Clear caches to force regeneration with new color
    vim.fn.delete(module.private.cache_dir, "rf")
    vim.fn.mkdir(module.private.cache_dir, "p", 0755)

    local was_rendering = module.private.do_render
    if was_rendering then
        disable_rendering()
        vim.schedule(function()
            enable_rendering()
        end)
    end
end

local event_handlers = {
    ["core.neorgcmd.events.latex.render.render"] = enable_rendering,
    ["core.neorgcmd.events.latex.render.enable"] = enable_rendering,
    ["core.neorgcmd.events.latex.render.disable"] = disable_rendering,
    ["core.neorgcmd.events.latex.render.toggle"] = toggle_rendering,
    ["core.autocommands.events.bufwinenter"] = function(event)
        show_all_placements(event.buffer)
        render_latex()
    end,
    ["core.autocommands.events.cursormoved"] = clear_at_cursor,
    ["core.autocommands.events.textchanged"] = render_latex,
    ["core.autocommands.events.insertleave"] = render_latex,
    ["core.autocommands.events.colorscheme"] = colorscheme_change,
}

module.on_event = function(event)
    if event.referrer == "core.autocommands" then
        if not vim.api.nvim_buf_is_valid(event.buffer) or vim.bo[event.buffer].ft ~= "norg" then
            return
        end
        local handler = event_handlers[event.type]
        if handler then
            handler(event)
        end
    else
        local handler = event_handlers[event.type]
        if handler then
            handler()
        end
    end
end

module.events.subscribed = {
    ["core.autocommands"] = {
        bufwinenter = true,
        cursormoved = true,
        textchanged = true,
        insertleave = true,
        colorscheme = true,
    },
    ["core.neorgcmd"] = {
        ["latex.render.render"] = true,
        ["latex.render.enable"] = true,
        ["latex.render.disable"] = true,
        ["latex.render.toggle"] = true,
    },
}

if module.config.public.render_on_enter then
    module.events.subscribed["core.autocommands"].bufreadpost = true
    event_handlers["core.autocommands.events.bufreadpost"] = render_latex
end

return module
