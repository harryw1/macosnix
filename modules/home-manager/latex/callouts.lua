-- callouts.lua — Pandoc Lua filter for professional-report and meeting-notes templates
--
-- Does two things, both only when the output format is LaTeX/PDF:
--
--   1. Converts GitHub-style alerts to tcolorbox callout environments:
--        > [!NOTE]      → \begin{gfm-info}[Note]
--        > [!TIP]       → \begin{gfm-tip}[Tip]
--        > [!WARNING]   → \begin{gfm-warning}[Warning]
--        > [!CAUTION]   → \begin{gfm-warning}[Caution]
--        > [!IMPORTANT] → \begin{gfm-danger}[Important]
--      Handles both the native Alert node (pandoc ≥ 3.2) and the pre-3.2
--      BlockQuote-with-[!TYPE]-header pattern.
--
--   2. Removes a redundant opening H1 when the document carries a YAML `title`
--      field, since the template generates a dedicated title page via \maketitle.

local alert_map = {
  -- pandoc ≥ 3.2 returns lowercase type names from el.alert_type
  note      = { env = "gfm-info",    title = "Note"      },
  tip       = { env = "gfm-tip",     title = "Tip"       },
  warning   = { env = "gfm-warning", title = "Warning"   },
  caution   = { env = "gfm-warning", title = "Caution"   },
  important = { env = "gfm-danger",  title = "Important" },
  -- pre-3.2 pattern matching uses uppercase from [!TYPE]
  NOTE      = { env = "gfm-info",    title = "Note"      },
  TIP       = { env = "gfm-tip",     title = "Tip"       },
  WARNING   = { env = "gfm-warning", title = "Warning"   },
  CAUTION   = { env = "gfm-warning", title = "Caution"   },
  IMPORTANT = { env = "gfm-danger",  title = "Important" },
}

local function is_latex()
  return FORMAT:match("latex") ~= nil or FORMAT:match("pdf") ~= nil
end

-- Returns a pandoc.List: RawBlock(\begin) + content blocks + RawBlock(\end).
-- Returning a List from a filter function splices the items in place of the
-- original block — no serialisation of the content needed.
local function make_callout(env, title, blocks)
  local result = pandoc.List({
    pandoc.RawBlock("latex", "\\begin{" .. env .. "}[" .. title .. "]"),
  })
  result:extend(blocks)
  result:insert(pandoc.RawBlock("latex", "\\end{" .. env .. "}"))
  return result
end

-- ── pandoc ≥ 3.2: native Alert node ────────────────────────────────────────
function Alert(el)
  if not is_latex() then return nil end
  if not el.alert_type then return nil end
  local mapping = alert_map[el.alert_type:lower()]
  if mapping then
    return make_callout(mapping.env, mapping.title, el.content)
  end
end

-- ── pandoc < 3.2: BlockQuote whose first Para is exactly "[!TYPE]" ─────────
function BlockQuote(el)
  if not is_latex() then return nil end
  if #el.content == 0 then return nil end

  local first = el.content[1]
  if first.t ~= "Para" then return nil end

  local text = pandoc.utils.stringify(first)
  local alert_type = text:match("^%[!(%u+)%]$")
  if not alert_type then return nil end

  local mapping = alert_map[alert_type]
  if not mapping then return nil end

  local rest = pandoc.List()
  for i = 2, #el.content do rest:insert(el.content[i]) end

  return make_callout(mapping.env, mapping.title, rest)
end

-- ── Remove redundant opening H1 when a YAML title is present (LaTeX only) ──
-- The template's \maketitle generates a title page, so an H1 that just repeats
-- the title creates a spurious numbered section at the start of the body.
function Pandoc(doc)
  if not is_latex() then return nil end
  if not doc.meta.title then return nil end
  if #doc.blocks == 0 then return nil end

  local first = doc.blocks[1]
  if first.t == "Header" and first.level == 1 then
    doc.blocks = doc.blocks:slice(2)
    return doc
  end
end
