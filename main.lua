-- Settings layout
local TIMEZIGS_SETTINGS_DEFAULT_DIR = renoise.tool().bundle_path .. "settings/default/"
local TIMEZIGS_SETTINGS_USER_DIR    = renoise.tool().bundle_path .. "settings/user/"
local TIMEZIGS_CONFIG_DEFAULT_PATH  = TIMEZIGS_SETTINGS_DEFAULT_DIR .. "config.json"
local TIMEZIGS_CONFIG_USER_PATH     = TIMEZIGS_SETTINGS_USER_DIR .. "config.json"
local TIMEZIGS_PRESETS_DEFAULT_PATH = TIMEZIGS_SETTINGS_DEFAULT_DIR .. "timesignatures.json"
local TIMEZIGS_PRESETS_USER_PATH    = TIMEZIGS_SETTINGS_USER_DIR .. "timesignatures.json"


local TIMEZIGS_BASE_LPB = 4
local TimeZigsDialogRef = nil
local TimeZigsVB = nil
local TimeZigsDefaultNumerator = 4
local TimeZigsDefaultDenominator = 4
local TimeZigsNumerator = TimeZigsDefaultNumerator
local TimeZigsDenominator = TimeZigsDefaultDenominator
-- Current/active time signature (may be preset or custom)
local TimeZigsCurrentNumerator = TimeZigsDefaultNumerator
local TimeZigsCurrentDenominator = TimeZigsDefaultDenominator
local TimeZigsCurrentIsCustom = true
-- Preset grid denominator can be decoupled from custom denominator
local TimeZigsPresetDenominator = TimeZigsDefaultDenominator
local TimeZigsGlobalCustomDenominator = true
local TimeZigsDefaultPresetLabel = string.format("%d/%d", TimeZigsDefaultNumerator, TimeZigsDefaultDenominator)
local TimeZigsActivePresetLabel = TimeZigsDefaultPresetLabel
local TimeZigsPresetButtons = {}
-- Section settings
local TimeZigsSectionName = ""
local TimeZigsAppendPresetToSectionName = false
-- Experimental features
local TimeZigsFillNotes = false
-- Safety features
local TimeZigsSafeMode = true -- Avoid float pattern lengths (warn only)
-- Sync features
local TimeZigsSyncDenominatorLPB = false -- When enabled, sync LPB to denominator (writes ZL with synced LPB)
-- Canvas-based UI state
local TimeZigsPresetCanvas = nil
local TimeZigsCustomCanvas = nil
-- Slightly tighter layout to avoid bleed
local TIMEZIGS_CANVAS_WIDTH = 480
local TIMEZIGS_CANVAS_HEIGHT = 240
local TIMEZIGS_BANNER_HEIGHT = 70
local TIMEZIGS_PRESET_COLS = 4
local TIMEZIGS_PRESET_ROWS = 4 -- 4x4 -> 16 presets
local TIMEZIGS_PRESET_PADDING = 8
local TIMEZIGS_PRESET_GUTTER = 8
local TIMEZIGS_CUSTOM_CANVAS_HEIGHT = 112

-- Forward declaration for function used before its definition
local TimeZigsUpdateBanner
-- Forward declarations for helpers referenced before definitions
local TimeZigsIsIntegralBar
local TimeZigsWarnIfNonIntegral
local TimeZigsGetLPBForDenominator

-- Custom presets storage (JSON only)
local TimeZigsCustomPresets = {
  { n = nil, d = nil },
  { n = nil, d = nil },
  { n = nil, d = nil },
  { n = nil, d = nil }
}
local TimeZigsCustomPresetLabels = {}
local TimeZigsLPBObserverAdded = false


function TimeZigsGeneratePresets(denominator)
  local presets = {}
  for i = 1, 16 do
    local lines = math.floor(4 * (4 / denominator) * i)
    table.insert(presets, { numerator = i, denominator = denominator, label = tostring(i) .. "/" .. tostring(denominator), values = { "0x" .. string.format("%X", lines) } })
  end
  return presets
end


local TimeZigsPresets = TimeZigsGeneratePresets(TimeZigsPresetDenominator)

-- Compute the main preset grid cell size so other UIs can match it
local function TimeZigsGetPresetCellSize()
  local cols = TIMEZIGS_PRESET_COLS
  local rows = TIMEZIGS_PRESET_ROWS
  local pad = TIMEZIGS_PRESET_PADDING
  local gutter = TIMEZIGS_PRESET_GUTTER
  local total_w = TIMEZIGS_CANVAS_WIDTH
  local total_h = TIMEZIGS_CANVAS_HEIGHT
  local btn_w = math.floor((total_w - (2 * pad) - ((cols - 1) * gutter)) / cols)
  local avail_h = total_h - TIMEZIGS_BANNER_HEIGHT - (2 * pad) - ((rows - 1) * gutter)
  if avail_h < rows then avail_h = rows end
  local btn_h = math.floor(avail_h / rows)
  return btn_w, btn_h
end

function TimeZigsApplyPreset(preset_index)
  if not TimeZigsPresets[preset_index] then return end
  -- Update current numerator/denominator from preset and refresh UI
  local preset = TimeZigsPresets[preset_index]
  if preset.numerator then TimeZigsCurrentNumerator = preset.numerator end
  if preset.denominator then TimeZigsCurrentDenominator = preset.denominator end
  TimeZigsCurrentIsCustom = false
  TimeZigsActivePresetLabel = TimeZigsPresets[preset_index].label or ""
  TimeZigsSave()
  if TimeZigsVB and TimeZigsVB.views then
    TimeZigsUpdateBanner()
  end
  -- Safe Mode: warn if resulting bar length will be non-integer at current LPB
  local s = renoise.song and renoise.song()
  local lpb = (s and s.transport and tonumber(s.transport.lpb)) and s.transport.lpb or 4
  -- If sync is enabled, update LPB to match denominator and use it for warnings
  if TimeZigsSyncDenominatorLPB and s and s.transport then
    local new_lpb = TimeZigsGetLPBForDenominator(TimeZigsCurrentDenominator)
    if tonumber(s.transport.lpb) ~= new_lpb then
      s.transport.lpb = new_lpb
      lpb = new_lpb
    end
  end
  TimeZigsWarnIfNonIntegral(TimeZigsCurrentNumerator, TimeZigsCurrentDenominator, lpb, "preset")
  -- Refresh Canvas button labels if present
  TimeZigsRefreshPresetButtons()
  if TimeZigsPresetCanvas then TimeZigsPresetCanvas:update() end
end

-- Helpers: load/save config -------------------------------------------------

-- tiny helpers
local function ts_read_all(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function ts_write_all(path, content)
  local f = io.open(path, "w")
  if not f then return false end
  f:write(content)
  f:close()
  return true
end

local function ts_json_get_number(blob, key)
  local v = blob:match('"'..key..'"%s*:%s*(%-?%d+)')
  return tonumber(v)
end

local function ts_json_get_bool(blob, key)
  local v = blob:match('"'..key..'"%s*:%s*(true)')
  if v == "true" then return true end
  v = blob:match('"'..key..'"%s*:%s*(false)')
  if v == "false" then return false end
  return nil
end

function TimeZigsLoad()
  -- defaults
  TimeZigsNumerator = TimeZigsDefaultNumerator
  TimeZigsDenominator = TimeZigsDefaultDenominator
  TimeZigsAppendPresetToSectionName = false
  TimeZigsPresetDenominator = TimeZigsDefaultDenominator
  TimeZigsGlobalCustomDenominator = true
  TimeZigsFillNotes = false
  TimeZigsSafeMode = true
  TimeZigsSyncDenominatorLPB = false

  -- read user config first, then default
  local data = ts_read_all(TIMEZIGS_CONFIG_USER_PATH) or ts_read_all(TIMEZIGS_CONFIG_DEFAULT_PATH)
  if data then
    local n = ts_json_get_number(data, "Numerator")
    local d = ts_json_get_number(data, "Denominator")
    local pd = ts_json_get_number(data, "PresetDenominator")
    local gcd = ts_json_get_bool(data, "GlobalCustomDen")
    local ap = ts_json_get_bool(data, "AppendTSLPB")
    local fn = ts_json_get_bool(data, "FillNotes")
  local sm = ts_json_get_bool(data, "SafeMode")
  local sd = ts_json_get_bool(data, "SyncDenLPB")
    if n then TimeZigsNumerator = n end
    if d then TimeZigsDenominator = d end
    if pd then TimeZigsPresetDenominator = pd end
    if gcd ~= nil then TimeZigsGlobalCustomDenominator = gcd end
    if ap ~= nil then TimeZigsAppendPresetToSectionName = ap end
    if fn ~= nil then TimeZigsFillNotes = fn end
    if sm ~= nil then TimeZigsSafeMode = sm end
  if sd ~= nil then TimeZigsSyncDenominatorLPB = sd end
  end

  -- Clamp and update presets using the decoupled denominator
  TimeZigsPresetDenominator = math.max(2, math.min(32, tonumber(TimeZigsPresetDenominator) or TimeZigsDefaultDenominator))
  -- Initialize current to custom on load
  TimeZigsCurrentNumerator = TimeZigsNumerator
  TimeZigsCurrentDenominator = TimeZigsDenominator
  TimeZigsCurrentIsCustom = true
  -- Ensure status label reflects current values
  TimeZigsActivePresetLabel = string.format("%d/%d", TimeZigsCurrentNumerator, TimeZigsCurrentDenominator)
  TimeZigsUpdatePresets()
  -- Load custom presets (4 slots)
  if TimeZigsLoadCustomPresets then TimeZigsLoadCustomPresets() end
end

function TimeZigsSave()
  local json = {}
  table.insert(json, '{')
  table.insert(json, string.format('  "Numerator": %d,', tonumber(TimeZigsNumerator) or TimeZigsDefaultNumerator))
  table.insert(json, string.format('  "Denominator": %d,', tonumber(TimeZigsDenominator) or TimeZigsDefaultDenominator))
  table.insert(json, string.format('  "PresetDenominator": %d,', tonumber(TimeZigsPresetDenominator) or TimeZigsDefaultDenominator))
  table.insert(json, string.format('  "GlobalCustomDen": %s,', TimeZigsGlobalCustomDenominator and 'true' or 'false'))
  table.insert(json, string.format('  "AppendTSLPB": %s,', TimeZigsAppendPresetToSectionName and 'true' or 'false'))
  table.insert(json, string.format('  "FillNotes": %s,', TimeZigsFillNotes and 'true' or 'false'))
  table.insert(json, string.format('  "SafeMode": %s,', TimeZigsSafeMode and 'true' or 'false'))
  table.insert(json, string.format('  "SyncDenLPB": %s', TimeZigsSyncDenominatorLPB and 'true' or 'false'))
  table.insert(json, '}\n')
  local ok = ts_write_all(TIMEZIGS_CONFIG_USER_PATH, table.concat(json, "\n"))
  if not ok then
    renoise.app():show_status("Could not save config. Ensure settings/user/ exists and is writable.")
  end
end

-- Fill per-beat notes across the newly created bar of patterns, using delay for fractional positions
function TimeZigsFillNotesAcrossBar(start_seq_index, created_lengths, track_index, n, d, lpb)
  if not renoise.song then return end
  local s = renoise.song()
  if not s then return end
  if not (start_seq_index and created_lengths and #created_lengths > 0) then return end

  -- Choose a safe sequencer track (no notes on master/send/group). Fallback to 1 if out of range
  local t_index = tonumber(track_index) or 1
  t_index = math.max(1, math.min(t_index, s.sequencer_track_count))
  local track = s.tracks[t_index]
  if track and track.visible_note_columns and track.visible_note_columns < 1 then
    track.visible_note_columns = 1
  end
  if track and track.delay_column_visible ~= nil then
    track.delay_column_visible = true
  end

  local inst_index = math.max(1, tonumber(s.selected_instrument_index) or 1)
  local lines_per_beat = (lpb * 4.0) / math.max(1, d)

  for b = 0, math.max(0, (n or 0) - 1) do
    local t = b * lines_per_beat -- time in lines from start of bar (can be fractional)
    local rem = t
    local seq = start_seq_index

    -- find target sequence and line within it
    local found = false
    for i = 1, #created_lengths do
      local len = created_lengths[i]
      if rem < len then
        local line_index = math.floor(rem) + 1
        local frac = rem - math.floor(rem)
        local delay = math.floor((frac * 255) + 0.5)
        local pat_index = s.sequencer.pattern_sequence[seq]
        local p = s.patterns[pat_index]
        if p then
          local l = p:track(t_index):line(line_index)
          if l and l.note_columns and #l.note_columns >= 1 then
            local nc = l.note_columns[1]
            nc.note_string = "C-4"
            nc.instrument_value = math.max(0, inst_index - 1)
            if nc.delay_value ~= nil then
              nc.delay_value = math.max(0, math.min(255, delay))
            end
          end
        end
        found = true
        break
      else
        rem = rem - len
        seq = seq + 1
      end
    end
    if not found then
      -- out of bounds; ignore silently
    end
  end
end

-- Custom Presets (JSON only)
function TimeZigsLoadCustomPresets()
  local presets = {
    { n = nil, d = nil },
    { n = nil, d = nil },
    { n = nil, d = nil },
    { n = nil, d = nil }
  }
  local data = ts_read_all(TIMEZIGS_PRESETS_USER_PATH) or ts_read_all(TIMEZIGS_PRESETS_DEFAULT_PATH)
  if data then
    local idx = 1
    for n,d in data:gmatch('"n"%s*:%s*(%d+)%s*,%s*"d"%s*:%s*(%d+)') do
      if idx > 4 then break end
      presets[idx].n = tonumber(n)
      presets[idx].d = tonumber(d)
      idx = idx + 1
    end
  end
  TimeZigsCustomPresets = presets
end

function TimeZigsSaveCustomPresets()
  local parts = {}
  table.insert(parts, '{\n  "presets": [')
  for i=1,4 do
    local p = TimeZigsCustomPresets[i] or {}
    local n = p.n and tostring(tonumber(p.n)) or 'null'
    local d = p.d and tostring(tonumber(p.d)) or 'null'
    local comma = (i < 4) and ',' or ''
    table.insert(parts, string.format('    { "n": %s, "d": %s }%s', n, d, comma))
  end
  table.insert(parts, '  ]\n}')
  local ok = ts_write_all(TIMEZIGS_PRESETS_USER_PATH, table.concat(parts, '\n'))
  if not ok then
    renoise.app():show_status("Could not save custom presets. Ensure settings/user/ exists and is writable.")
  end
end


function TimeZigsCalculateLinesPerBeat(denominator)
  local base_lines = 4 * (4 / denominator)
  return base_lines
end

-- True when the bar length is an integer number of lines at current LPB
TimeZigsIsIntegralBar = function(n, d, lpb)
  n = math.max(1, tonumber(n) or 1)
  d = math.max(1, tonumber(d) or 1)
  lpb = math.max(1, tonumber(lpb) or 4)
  local total = n * lpb * 4
  return (total % d) == 0
end

TimeZigsWarnIfNonIntegral = function(n, d, lpb, context)
  if not TimeZigsSafeMode then return end
  if not TimeZigsIsIntegralBar(n, d, lpb) then
    n = math.max(1, tonumber(n) or 1)
    d = math.max(1, tonumber(d) or 1)
    lpb = math.max(1, tonumber(lpb) or 4)
    local lines_float = (n * (4.0 / d) * lpb)
    local lines_rounded = math.max(1, math.floor(lines_float + 0.5))
    local msg = string.format(
      "Warning: Non-integer bar length for %d/%d at %d LPB%s — will approximate %.1f lines to %d lines. Consider raising LPB or changing denominator.",
      n, d, lpb, context and (" ("..context..")") or "", lines_float, lines_rounded)
    renoise.app():show_status(msg)
  end
end

-- Determine the LPB to use when syncing to denominator
TimeZigsGetLPBForDenominator = function(d)
  d = math.max(2, math.min(32, tonumber(d) or 4))
  -- Strategy: match LPB to denominator to ensure integer grid for the chosen beat unit
  -- This yields integer lines per bar (n*4) and avoids fractional placement.
  local lpb = d
  return math.max(1, math.min(255, lpb))
end

-- Compute required lines for one bar at current selection and LPB
local function TimeZigsComputeCurrentLines()
  local s = renoise.song and renoise.song()
  local lpb = 4
  if s and s.transport and tonumber(s.transport.lpb) then
    lpb = math.max(1, math.min(255, s.transport.lpb))
  end
  local n = math.max(1, tonumber(TimeZigsCurrentNumerator) or TimeZigsDefaultNumerator)
  local d = math.max(1, tonumber(TimeZigsCurrentDenominator) or TimeZigsDefaultDenominator)
  local lines = math.max(1, math.floor((n * (4 / d) * lpb) + 0.5))
  return lines, lpb
end

-- Validate that a beat will be at least 1 line long for the given LPB and denominator
function TimeZigsValidate(lpb, numerator, denominator)
  local l = math.max(1, tonumber(lpb) or 4)
  local den = math.max(1, tonumber(denominator) or 1)
  local lines_per_beat = (l * 4.0) / den
  if lines_per_beat < 1 then
    local rounded = string.format("%.2f", lines_per_beat)
    local msg = string.format(
      "Error: Current Time Signature %d/%d will result in beats that are only %s lines long (min. is 1 line). Either increase LPB or reduce Denominator.",
      tonumber(numerator) or 0, tonumber(denominator) or 0, rounded
    )
    renoise.app():show_status(msg)
    return false
  end
  return true
end

-- Update the banner labels for current time signature and required lines
TimeZigsUpdateBanner = function()
  if not (TimeZigsVB and TimeZigsVB.views) then return end
  local views = TimeZigsVB.views
  if views.current_ts_value_label then
    views.current_ts_value_label.text = tostring(TimeZigsCurrentNumerator) .. "/" .. tostring(TimeZigsCurrentDenominator)
  end
  if views.current_lines_label then
    local _, lpb = TimeZigsComputeCurrentLines()
    if TimeZigsSyncDenominatorLPB then
      lpb = TimeZigsGetLPBForDenominator(TimeZigsCurrentDenominator)
    end
    local n = math.max(1, tonumber(TimeZigsCurrentNumerator) or TimeZigsDefaultNumerator)
    local d = math.max(1, tonumber(TimeZigsCurrentDenominator) or TimeZigsDefaultDenominator)
    local lines_float = (n * (4.0 / d) * lpb)
    local lines_text = string.format("%.1f", lines_float)
    local beat = string.format("%.1f", (lpb * 4.0) / d)
    views.current_lines_label.text = "Lines: " .. lines_text .. "  LPB: " .. tostring(lpb) .. "  Beat Duration: " .. beat .. " lines"
  end
  -- Refresh preset labels to update subtle non-integer markers on LPB change
  TimeZigsRefreshPresetButtons()
  if TimeZigsPresetCanvas then TimeZigsPresetCanvas:update() end
end

function TimeZigsCreate()
  if not renoise.song then return end
  local s = renoise.song()
  if not s then return end

  local insert_at = s.selected_sequence_index + 1
  local first_created_seq_index = insert_at
  local created = 0
  local created_lengths = {}

  -- Determine LPB to use: if Sync is ON, derive from denominator; else use current transport LPB
  local current_lpb = math.max(1, math.min(255, s.transport.lpb))
  local n = math.max(1, tonumber(TimeZigsCurrentNumerator) or TimeZigsDefaultNumerator)
  local d = math.max(1, tonumber(TimeZigsCurrentDenominator) or TimeZigsDefaultDenominator)
  if TimeZigsSyncDenominatorLPB then
    local synced = TimeZigsGetLPBForDenominator(d)
    if synced ~= current_lpb then current_lpb = synced end
  end

  -- Validate feasibility: beats must be at least 1 line long
  if not TimeZigsValidate(current_lpb, n, d) then
    return
  end

  -- Compute lines for one bar at current LPB: n * (4/d) * LPB
  -- Safe Mode: block creation if bar length would be non-integer
  if TimeZigsSafeMode and not TimeZigsIsIntegralBar(n, d, current_lpb) then
    renoise.app():show_status(string.format(
      "Safe Mode: Cannot create patterns — %d/%d at %d LPB would yield a non-integer beat and pattern length. Disable Safe Mode to allow float approximation.", n, d, current_lpb))
    return
  end
  local lines = math.max(1, math.floor((n * (4 / d) * current_lpb) + 0.5))

  local remaining = lines
  while remaining > 0 do
    local chunk = math.min(remaining, 512)
    s.sequencer:insert_new_pattern_at(insert_at)
    local pat_index = s.sequencer.pattern_sequence[insert_at]
    local pat = s.patterns[pat_index]
    if pat then
      pat.number_of_lines = chunk
      -- Write ZLxx (LPB) on the first line of the master track so LPB stays with the pattern
      local master_track_index = s.sequencer_track_count + 1
      if s.tracks[master_track_index].visible_effect_columns < 2 then
        s.tracks[master_track_index].visible_effect_columns = 2
      end
      local first_line = pat:track(master_track_index):line(1)
      first_line.effect_columns[2].number_string = "ZL"
  first_line.effect_columns[2].amount_value = math.min(255, current_lpb)
    end
    table.insert(created_lengths, chunk)
    insert_at = insert_at + 1
    created = created + 1
    remaining = remaining - chunk
  end

  if created > 0 then
    s.selected_sequence_index = first_created_seq_index
  end

  -- Optional: fill per-beat notes across the created bar (experimental)
  if TimeZigsFillNotes and created > 0 then
    local target_track_index = tonumber(s.selected_track_index) or 1
    TimeZigsFillNotesAcrossBar(first_created_seq_index, created_lengths, target_track_index, n, d, current_lpb)
  end

  local lengths_text = table.concat(created_lengths, ", ")
  local preset_part = (TimeZigsActivePresetLabel ~= "" and (" (" .. TimeZigsActivePresetLabel .. ")") or "")
  -- Optional section creation and naming
  local section_name = tostring(TimeZigsSectionName or "")
  if section_name ~= "" then
    local computed_name = section_name
    if TimeZigsAppendPresetToSectionName then
      local ts = tostring(TimeZigsActivePresetLabel or "")
      local lpb_text = tostring(current_lpb)
      local suffix
      if ts ~= "" then
        suffix = string.format(" (%s - %s LPB)", ts, lpb_text)
      else
        suffix = string.format(" (%s LPB)", lpb_text)
      end
      computed_name = computed_name .. suffix
    end
    s.sequencer:set_sequence_is_start_of_section(first_created_seq_index, true)
    s.sequencer:set_sequence_section_name(first_created_seq_index, computed_name)
  else
    if TimeZigsAppendPresetToSectionName then
      local ts = tostring(TimeZigsActivePresetLabel or "")
      local lpb_text = tostring(current_lpb)
      local computed_name
      if ts ~= "" then
        computed_name = string.format("%s - %s LPB", ts, lpb_text)
      else
        computed_name = string.format("%s LPB", lpb_text)
      end
      s.sequencer:set_sequence_is_start_of_section(first_created_seq_index, true)
      s.sequencer:set_sequence_section_name(first_created_seq_index, computed_name)
    end
  end

  renoise.app():show_status("Added " .. tostring(created) .. " pattern(s) at lengths: " .. lengths_text .. preset_part)
end

-- Apply a preset (or custom) and immediately create patterns. Usable from keybindings.
function TimeZigsApplyPresetAndCreate(preset_index)
  -- Ensure state is ready
  if not TimeZigsPresets or #TimeZigsPresets == 0 then
    TimeZigsLoad()
    TimeZigsUpdatePresets()
  end
  if preset_index == 16 then
    -- Use Custom values
    TimeZigsCurrentNumerator = TimeZigsNumerator
    TimeZigsCurrentDenominator = TimeZigsDenominator
    TimeZigsCurrentIsCustom = true
    TimeZigsActivePresetLabel = string.format("%d/%d", TimeZigsCurrentNumerator, TimeZigsCurrentDenominator)
  else
    local preset = TimeZigsPresets[preset_index]
    if not preset then return end
    TimeZigsCurrentNumerator = preset.numerator or TimeZigsCurrentNumerator
    TimeZigsCurrentDenominator = preset.denominator or TimeZigsCurrentDenominator
    TimeZigsCurrentIsCustom = false
    TimeZigsActivePresetLabel = preset.label or (tostring(TimeZigsCurrentNumerator).."/"..tostring(TimeZigsCurrentDenominator))
  end
  -- If syncing is enabled, update the Renoise LPB before creating
  local s = renoise.song and renoise.song()
  if TimeZigsSyncDenominatorLPB and s and s.transport then
    local new_lpb = TimeZigsGetLPBForDenominator(TimeZigsCurrentDenominator)
    if tonumber(s.transport.lpb) ~= new_lpb then s.transport.lpb = new_lpb end
  end
  -- Create patterns right away
  TimeZigsCreate()
end

-- Apply one of the 1-4 custom preset slots and immediately create patterns
function TimeZigsApplyCustomPresetSlotAndCreate(slot_index)
  if type(slot_index) ~= "number" or slot_index < 1 or slot_index > 4 then return end
  -- Ensure configuration and custom presets are loaded when called via keybinding
  TimeZigsLoad()

  local p = TimeZigsCustomPresets and TimeZigsCustomPresets[slot_index]
  if not (p and p.n and p.d) then
    renoise.app():show_status(string.format("Custom preset %d is empty", slot_index))
    return
  end

  -- Clamp and store as current custom values
  TimeZigsNumerator = math.max(1, math.min(32, tonumber(p.n) or TimeZigsDefaultNumerator))
  TimeZigsDenominator = math.max(2, math.min(32, tonumber(p.d) or TimeZigsDefaultDenominator))
  TimeZigsSave()

  if TimeZigsGlobalCustomDenominator then
    TimeZigsPresetDenominator = TimeZigsDenominator
    TimeZigsUpdatePresets()
    TimeZigsRefreshPresetButtons()
    if TimeZigsPresetCanvas then TimeZigsPresetCanvas:update() end
  end

  -- Apply to current selection as custom
  TimeZigsCurrentIsCustom = true
  TimeZigsCurrentNumerator = TimeZigsNumerator
  TimeZigsCurrentDenominator = TimeZigsDenominator
  TimeZigsActivePresetLabel = string.format("%d/%d", TimeZigsCurrentNumerator, TimeZigsCurrentDenominator)
  if TimeZigsVB and TimeZigsVB.views then TimeZigsUpdateBanner() end

  -- If syncing is enabled, update the Renoise LPB now
  local s = renoise.song and renoise.song()
  if TimeZigsSyncDenominatorLPB and s and s.transport then
    local new_lpb = TimeZigsGetLPBForDenominator(TimeZigsCurrentDenominator)
    if tonumber(s.transport.lpb) ~= new_lpb then s.transport.lpb = new_lpb end
  end

  -- Create patterns right away
  TimeZigsCreate()
end

-- Apply a preset (or custom) and immediately create a phrase. Usable from keybindings.
function TimeZigsApplyPresetAndCreatePhrase(preset_index)
  -- Ensure state is ready
  if not TimeZigsPresets or #TimeZigsPresets == 0 then
    TimeZigsLoad()
    TimeZigsUpdatePresets()
  end
  if preset_index == 16 then
    -- Use Custom values
    TimeZigsCurrentNumerator = TimeZigsNumerator
    TimeZigsCurrentDenominator = TimeZigsDenominator
    TimeZigsCurrentIsCustom = true
    TimeZigsActivePresetLabel = string.format("%d/%d", TimeZigsCurrentNumerator, TimeZigsCurrentDenominator)
  else
    local preset = TimeZigsPresets[preset_index]
    if not preset then return end
    TimeZigsCurrentNumerator = preset.numerator or TimeZigsCurrentNumerator
    TimeZigsCurrentDenominator = preset.denominator or TimeZigsCurrentDenominator
    TimeZigsCurrentIsCustom = false
    TimeZigsActivePresetLabel = preset.label or (tostring(TimeZigsCurrentNumerator).."/"..tostring(TimeZigsCurrentDenominator))
  end
  -- If syncing is enabled, update the Renoise LPB before creating the phrase
  local s = renoise.song and renoise.song()
  if TimeZigsSyncDenominatorLPB and s and s.transport then
    local new_lpb = TimeZigsGetLPBForDenominator(TimeZigsCurrentDenominator)
    if tonumber(s.transport.lpb) ~= new_lpb then s.transport.lpb = new_lpb end
  end
  -- Create phrase right away
  TimeZigsCreatePhrases()
end

-- Apply one of the 1-4 custom preset slots and immediately create a phrase
function TimeZigsApplyCustomPresetSlotAndCreatePhrase(slot_index)
  if type(slot_index) ~= "number" or slot_index < 1 or slot_index > 4 then return end
  -- Ensure configuration and custom presets are loaded when called via keybinding
  TimeZigsLoad()

  local p = TimeZigsCustomPresets and TimeZigsCustomPresets[slot_index]
  if not (p and p.n and p.d) then
    renoise.app():show_status(string.format("Custom preset %d is empty", slot_index))
    return
  end

  -- Clamp and store as current custom values
  TimeZigsNumerator = math.max(1, math.min(32, tonumber(p.n) or TimeZigsDefaultNumerator))
  TimeZigsDenominator = math.max(2, math.min(32, tonumber(p.d) or TimeZigsDefaultDenominator))
  TimeZigsSave()

  if TimeZigsGlobalCustomDenominator then
    TimeZigsPresetDenominator = TimeZigsDenominator
    TimeZigsUpdatePresets()
    TimeZigsRefreshPresetButtons()
    if TimeZigsPresetCanvas then TimeZigsPresetCanvas:update() end
  end

  -- Apply to current selection as custom
  TimeZigsCurrentIsCustom = true
  TimeZigsCurrentNumerator = TimeZigsNumerator
  TimeZigsCurrentDenominator = TimeZigsDenominator
  TimeZigsActivePresetLabel = string.format("%d/%d", TimeZigsCurrentNumerator, TimeZigsCurrentDenominator)
  if TimeZigsVB and TimeZigsVB.views then TimeZigsUpdateBanner() end

  -- If syncing is enabled, update the Renoise LPB now
  local s2 = renoise.song and renoise.song()
  if TimeZigsSyncDenominatorLPB and s2 and s2.transport then
    local new_lpb2 = TimeZigsGetLPBForDenominator(TimeZigsCurrentDenominator)
    if tonumber(s2.transport.lpb) ~= new_lpb2 then s2.transport.lpb = new_lpb2 end
  end

  -- Create phrase right away
  TimeZigsCreatePhrases()
end

-- Create a phrase in the currently selected instrument based on current time signature
function TimeZigsCreatePhrases()
  if not renoise.song then return end
  local s = renoise.song()
  if not s then return end

  local instr = s.selected_instrument
  if not instr then
    renoise.app():show_status("No selected instrument to create a phrase in")
    return
  end

  -- Determine LPB to use: if Sync is ON, derive from denominator; else use current transport LPB
  local current_lpb = math.max(1, math.min(255, s.transport.lpb))
  local n = math.max(1, tonumber(TimeZigsCurrentNumerator) or TimeZigsDefaultNumerator)
  local d = math.max(1, tonumber(TimeZigsCurrentDenominator) or TimeZigsDefaultDenominator)
  if TimeZigsSyncDenominatorLPB then
    local synced = TimeZigsGetLPBForDenominator(d)
    if synced ~= current_lpb then current_lpb = synced end
  end

  -- Validate feasibility: beats must be at least 1 line long
  if not TimeZigsValidate(current_lpb, n, d) then
    return
  end

  -- Compute lines for one bar at current LPB
  -- Safe Mode: block creation if bar length would be non-integer
  if TimeZigsSafeMode and not TimeZigsIsIntegralBar(n, d, current_lpb) then
    renoise.app():show_status(string.format(
      "Safe Mode: Cannot create phrase — %d/%d at %d LPB would yield a non-integer bar. Increase LPB or change denominator.", n, d, current_lpb))
    return
  end
  local lines = math.max(1, math.floor((n * (4 / d) * current_lpb) + 0.5))
  local max_lines = renoise.InstrumentPhrase.MAX_NUMBER_OF_LINES or 512
  if lines > max_lines then
    renoise.app():show_status(string.format(
      "Cannot create phrase: required lines (%d) exceed the maximum allowed (%d).",
      lines, max_lines))
    return
  end

  -- Insert phrase at the end
  local insert_index = (#instr.phrases) + 1
  local phrase = instr:insert_phrase_at(insert_index)
  if not phrase then
    renoise.app():show_status("Failed to create phrase in the selected instrument")
    return
  end

  phrase.name = string.format("%d/%d @ %d LPB", n, d, current_lpb)
  phrase.number_of_lines = lines
  phrase.lpb = current_lpb
  phrase.looping = true
  phrase.loop_start = 1
  phrase.loop_end = lines

  -- Also write ZLxx on the first line of the phrase for visual parity
  -- (phrase.lpb is authoritative; ZL here mirrors the patterns behavior)
  local first_line = phrase:line(1)
  if first_line and first_line.effect_columns and #first_line.effect_columns >= 2 then
    first_line.effect_columns[2].number_string = "ZL"
  first_line.effect_columns[2].amount_value = math.min(255, current_lpb)
  end

  -- Ensure phrase editor is visible for feedback (non-intrusive)
  s.selected_instrument.phrase_editor_visible = true

  renoise.app():show_status(string.format("Created phrase (%s) with %d lines in instrument #%d: %s",
    phrase.name, lines, s.selected_instrument_index or 0, s.selected_instrument.name or ""))
end

-- Manually enter pattern sizes (same as Paketti Slab O Patterns)

function TimeZigsMoveSelection(delta)
  if #TimeZigsValues == 0 then return end
  TimeZigsSelectedIndex = TimeZigsSelectedIndex + delta
  if TimeZigsSelectedIndex < 1 then
    TimeZigsSelectedIndex = #TimeZigsValues
  elseif TimeZigsSelectedIndex > #TimeZigsValues then
    TimeZigsSelectedIndex = 1
  end
  TimeZigsRefreshRowColors()
end

function TimeZigsAppendChar(ch)
  if #TimeZigsValues == 0 then return end
  local idx = TimeZigsSelectedIndex
  if idx < 1 then idx = 1 TimeZigsSelectedIndex = 1 end
  local cur = tostring(TimeZigsValues[idx] or "")
  -- If value starts with 0x, allow only hex digits and max 3 digits after 0x
  -- Allow typing '@' to start LPB suffix and digits after it
  if cur:match("^0[xX]") then
    -- if user types '@' and there's not already a suffix, allow it
    if ch == "@" then
      if not cur:match("@") then
        cur = cur .. "@"
        TimeZigsValues[idx] = cur
        TimeZigsUpdateRowLabels(idx)
      end
      return nil
    end
    -- previously limited to 3 hex digits; allow more and clamp during parsing when used
    -- If there's a suffix, allow only digits for LPB
    if cur:match("@") then
      if not ch:match("%d") then return nil end
      -- limit LPB digits to max 3 characters
      local suffix = cur:match("@(.*)$") or ""
      if #suffix >= 3 then
        renoise.app():show_status("Max 3 digits for LPB")
        return nil
      end
      cur = cur .. ch
      TimeZigsValues[idx] = cur
      TimeZigsUpdateRowLabels(idx)
      return nil
    end
    if not ch:match("[0-9a-fA-FxX]") then
      return nil
    end
  end
  TimeZigsValues[idx] = cur .. ch
  TimeZigsUpdateRowLabels(idx)
end

function TimeZigsBackspace()
  if #TimeZigsValues == 0 then return end
  local idx = TimeZigsSelectedIndex
  if idx < 1 then idx = 1 TimeZigsSelectedIndex = 1 end
  local cur = tostring(TimeZigsValues[idx] or "")
  if #cur > 0 then
    cur = string.sub(cur, 1, #cur - 1)
  end
  TimeZigsValues[idx] = cur
  TimeZigsUpdateRowLabels(idx)
end

-- UI
-- Build Canvas-based preset grid as a stack: canvas background + 16 large buttons
local function TimeZigsBuildPresetCanvas(vb)
  -- compute grid geometry
  local cols = TIMEZIGS_PRESET_COLS
  local rows = TIMEZIGS_PRESET_ROWS
  local pad = TIMEZIGS_PRESET_PADDING
  local gutter = TIMEZIGS_PRESET_GUTTER
  local total_w = TIMEZIGS_CANVAS_WIDTH
  local total_h = TIMEZIGS_CANVAS_HEIGHT
  local btn_w = math.floor((total_w - (2 * pad) - ((cols - 1) * gutter)) / cols)
  local avail_h = total_h - TIMEZIGS_BANNER_HEIGHT - (2 * pad) - ((rows - 1) * gutter)
  if avail_h < rows then avail_h = rows end
  local btn_h = math.floor(avail_h / rows)

  -- background canvas
  local canvas = vb:canvas{
    mode = "plain",
    size = { total_w, total_h },
    render = function(ctx)
      -- fill background and border using explicit RGBA colors to avoid theme lookup issues
      ctx.fill_color = {40,40,40,255}
      ctx:fill_rect(0, 0, ctx.size.width, ctx.size.height)
      ctx.stroke_color = {90,90,90,255}
      ctx.line_width = 2
      ctx:stroke_rect(1, 1, ctx.size.width - 2, ctx.size.height - 2)
      -- banner background at top
      ctx.fill_color = {55,55,55,255}
      ctx:fill_rect(0, 0, ctx.size.width, TIMEZIGS_BANNER_HEIGHT)
      -- draw button background blocks underneath the real buttons
      ctx.fill_color = {60,60,60,255}
      local idx = 1
      for r = 1, rows do
        for c = 1, cols do
          local x = pad + (c - 1) * (btn_w + gutter)
          local y = TIMEZIGS_BANNER_HEIGHT + pad + (r - 1) * (btn_h + gutter)
          ctx:fill_rect(x, y, btn_w, btn_h)
          idx = idx + 1
        end
      end
    end
  }
  TimeZigsPresetCanvas = canvas

  -- overlay big preset buttons in a stack for interaction and labels
  local overlay_buttons = {}
  TimeZigsPresetButtons = {}
  local idx = 1
  for r = 1, rows do
    for c = 1, cols do
      local x = pad + (c - 1) * (btn_w + gutter)
      local y = TIMEZIGS_BANNER_HEIGHT + pad + (r - 1) * (btn_h + gutter)
      local is_custom_btn = (idx == 16)
      local label
      if is_custom_btn then
        label = "CUSTOM"
      else
        label = (TimeZigsPresets[idx] and TimeZigsPresets[idx].label) or (tostring(idx) .. "/" .. tostring(TimeZigsPresetDenominator))
      end
      local btn = vb:button{
        text = label,
        size = { btn_w, btn_h },
        origin = { x, y },
        tooltip = is_custom_btn and "Use Custom Time Signature" or ("Apply Time Signature: " .. label),
        notifier = (function(i, custom)
          return function()
            if custom then
              -- Switch current selection back to custom values
              TimeZigsCurrentNumerator = TimeZigsNumerator
              TimeZigsCurrentDenominator = TimeZigsDenominator
              TimeZigsCurrentIsCustom = true
              TimeZigsActivePresetLabel = string.format("%d/%d", TimeZigsCurrentNumerator, TimeZigsCurrentDenominator)
              TimeZigsUpdateBanner()
            else
              TimeZigsApplyPreset(i)
            end
          end
        end)(idx, is_custom_btn)
      }
      TimeZigsPresetButtons[idx] = btn
      table.insert(overlay_buttons, btn)
      idx = idx + 1
    end
  end

  -- Banner overlays: header, current TS value, and lines/LPB
  local current_ts_header_text = vb:text{
    id = "current_ts_header_label",
    text = "Current TimeSignature:",
    font = "normal",
    style = "strong",
    align = "center",
    size = { total_w, 16 },
    origin = { 0, 6 }
  }

  local current_ts_value_text = vb:text{
    id = "current_ts_value_label",
    text = tostring(TimeZigsCurrentNumerator) .. "/" .. tostring(TimeZigsCurrentDenominator),
    font = "big",
    style = "strong",
    align = "center",
    size = { total_w, 20 },
    origin = { 0, 24 }
  }

  local init_lines, init_lpb = TimeZigsComputeCurrentLines()
  local init_lpb_for_banner = init_lpb
  if TimeZigsSyncDenominatorLPB then
    init_lpb_for_banner = TimeZigsGetLPBForDenominator(TimeZigsCurrentDenominator)
  end
  local init_beat = string.format("%.1f", (init_lpb_for_banner * 4.0) / math.max(1, TimeZigsCurrentDenominator))
  -- Show Lines with at least one decimal for clarity (non-rounded preview)
  local init_n = math.max(1, tonumber(TimeZigsCurrentNumerator) or TimeZigsDefaultNumerator)
  local init_d = math.max(1, tonumber(TimeZigsCurrentDenominator) or TimeZigsDefaultDenominator)
  local init_lines_float = (init_n * (4.0 / init_d) * init_lpb_for_banner)
  local init_lines_text = string.format("%.1f", init_lines_float)
  local current_lines_text = vb:text{
    id = "current_lines_label",
    text = "Lines: " .. init_lines_text .. "  LPB: " .. tostring(init_lpb_for_banner) .. "  Beat Duration: " .. init_beat .. " lines",
    font = "normal",
    style = "strong",
    align = "center",
    size = { total_w, 16 },
    origin = { 0, 44 }
  }

  return vb:stack{
    size = { total_w, total_h },
    canvas,
    current_ts_header_text,
    current_ts_value_text,
    current_lines_text,
    unpack(overlay_buttons)
  }
end

-- Build dialog
function TimeZigsBuildContent()
  local vb = TimeZigsVB

  local BUTTON_HEIGHT = 32
  local SPACING = 4
  local MARGIN = 8

  -- Canvas-based preset grid
  local preset_canvas_stack = TimeZigsBuildPresetCanvas(vb)

  -- Custom Time Signature controls: adjust functions
  local function adjust_den(delta)
    local newv = math.max(2, math.min(32, (tonumber(TimeZigsDenominator) or TimeZigsDefaultDenominator) + delta))
    if newv ~= TimeZigsDenominator then
      TimeZigsDenominator = newv
      TimeZigsSave()
      -- If syncing is enabled, also update the Renoise LPB immediately
      local s = renoise.song and renoise.song()
      if TimeZigsSyncDenominatorLPB and s and s.transport then
        local new_lpb = TimeZigsGetLPBForDenominator(TimeZigsDenominator)
        if tonumber(s.transport.lpb) ~= new_lpb then
          s.transport.lpb = new_lpb
        end
      end
      if TimeZigsGlobalCustomDenominator then
        TimeZigsPresetDenominator = TimeZigsDenominator
        TimeZigsUpdatePresets()
      end
      -- When adjusting custom controls, switch to Custom selection and update banner
      TimeZigsCurrentIsCustom = true
      TimeZigsCurrentDenominator = TimeZigsDenominator
      TimeZigsCurrentNumerator = TimeZigsNumerator
      TimeZigsActivePresetLabel = string.format("%d/%d", TimeZigsCurrentNumerator, TimeZigsCurrentDenominator)
      if TimeZigsVB and TimeZigsVB.views then
        TimeZigsUpdateBanner()
        if TimeZigsVB.views.custom_den_value then
          TimeZigsVB.views.custom_den_value.text = string.format("%d", TimeZigsDenominator)
        end
      end
      -- Safe Mode warning on change
      local lpb = (s and s.transport and tonumber(s.transport.lpb)) and s.transport.lpb or 4
      if TimeZigsSyncDenominatorLPB then
        lpb = TimeZigsGetLPBForDenominator(TimeZigsCurrentDenominator)
      end
      TimeZigsWarnIfNonIntegral(TimeZigsCurrentNumerator, TimeZigsCurrentDenominator, lpb, "custom")
      TimeZigsRefreshPresetButtons()
      if TimeZigsPresetCanvas then TimeZigsPresetCanvas:update() end
      if TimeZigsCustomCanvas then TimeZigsCustomCanvas:update() end
    end
  end

  local function adjust_num(delta)
    local newv = math.max(1, math.min(32, (tonumber(TimeZigsNumerator) or TimeZigsDefaultNumerator) + delta))
    if newv ~= TimeZigsNumerator then
      TimeZigsNumerator = newv
      TimeZigsSave()
      -- When adjusting custom controls, switch to Custom selection and update banner
      TimeZigsCurrentIsCustom = true
      TimeZigsCurrentNumerator = TimeZigsNumerator
      TimeZigsCurrentDenominator = TimeZigsDenominator
      TimeZigsActivePresetLabel = string.format("%d/%d", TimeZigsCurrentNumerator, TimeZigsCurrentDenominator)
      if TimeZigsVB and TimeZigsVB.views then
        TimeZigsUpdateBanner()
        if TimeZigsVB.views.custom_num_value then
          TimeZigsVB.views.custom_num_value.text = string.format("%d", TimeZigsNumerator)
        end
      end
      -- Safe Mode warning on change
      local s = renoise.song and renoise.song()
      local lpb = (s and s.transport and tonumber(s.transport.lpb)) and s.transport.lpb or 4
      TimeZigsWarnIfNonIntegral(TimeZigsCurrentNumerator, TimeZigsCurrentDenominator, lpb, "custom")
      if TimeZigsCustomCanvas then TimeZigsCustomCanvas:update() end
    end
  end

  local function TimeZigsBuildCustomCanvas(vb)
    local total_w = TIMEZIGS_CANVAS_WIDTH
    local total_h = TIMEZIGS_CUSTOM_CANVAS_HEIGHT
    -- unified symmetric margins and center gap for this canvas
    local cc_left_margin, cc_right_margin, cc_center_gap = 8, 8, 8
    local cc_left_w = math.floor((total_w - cc_left_margin - cc_right_margin - cc_center_gap) / 2)
    local cc_left_x = cc_left_margin
    local cc_right_x = cc_left_x + cc_left_w + cc_center_gap
    local cc_right_w = total_w - cc_right_x - cc_right_margin
    local cc_sep_x = cc_left_x + cc_left_w + math.floor(cc_center_gap / 2)
    local canvas = vb:canvas{
      mode = "plain",
      size = { total_w, total_h },
      render = function(ctx)
        ctx.fill_color = {40,40,40,255}
        ctx:fill_rect(0, 0, ctx.size.width, ctx.size.height)
        ctx.stroke_color = {90,90,90,255}
        ctx.line_width = 2
        ctx:stroke_rect(1, 1, ctx.size.width - 2, ctx.size.height - 2)
        -- header strip
        ctx.fill_color = {55,55,55,255}
        ctx:fill_rect(0, 0, ctx.size.width, 24)
        -- vertical separator line
        -- use a filled thin rect for the separator, perfectly centered in the gap
        ctx.fill_color = {90,90,90,255}
        ctx:fill_rect(cc_sep_x, 24, 1, ctx.size.height - 30)
        -- Right boxes are rendered using real buttons (same styling as main grid)
      end
    }
    TimeZigsCustomCanvas = canvas

    local header = vb:text{
      text = "Custom Time Signatures",
      font = "bold",
      style = "strong",
      align = "center",
      size = { total_w, 24 },
      origin = { 0, 0 }
    }

  -- Geometry split (match render's exact math)
  local left_w = cc_left_w
  local left_x = cc_left_x
  local right_x = cc_right_x
  local right_w = cc_right_w

    -- Controls (LEFT): Numerator row above Denominator row, centered within left panel
    local btn_w, btn_h = 40, 28
    local val_w, val_h = 60, 28
    local spacing = 4
    local group_w = btn_w + spacing + val_w + spacing + btn_w
    local center_x = left_x + math.floor((left_w - group_w) / 2)
    local y = 32

    -- Numerator row
    local num_dec = vb:button{ text = "-", size = { btn_w, btn_h }, origin = { center_x, y }, notifier = function() adjust_num(-1) end }
    local num_val = vb:text{ id = "custom_num_value", text = tostring(TimeZigsNumerator), font = "big", style = "strong", align = "center", size = { val_w, val_h }, origin = { center_x + btn_w + spacing, y } }
    local num_inc = vb:button{ text = "+", size = { btn_w, btn_h }, origin = { center_x + btn_w + spacing + val_w + spacing, y }, notifier = function() adjust_num(1) end }

    -- Denominator row (below numerator)
    y = y + btn_h + 10
    local den_dec = vb:button{ text = "-", size = { btn_w, btn_h }, origin = { center_x, y }, notifier = function() adjust_den(-1) end }
    local den_val = vb:text{ id = "custom_den_value", text = tostring(TimeZigsDenominator), font = "big", style = "strong", align = "center", size = { val_w, val_h }, origin = { center_x + btn_w + spacing, y } }
    local den_inc = vb:button{ text = "+", size = { btn_w, btn_h }, origin = { center_x + btn_w + spacing + val_w + spacing, y }, notifier = function() adjust_den(1) end }

    -- (removed) Global Custom Denominator checkbox here; now only available in Settings

  -- Custom Presets (RIGHT): 4 boxes, each as a real button (same style as grid)
  -- with a small Save overlay button on the right (click big box to load)
    TimeZigsCustomPresetLabels = {}
    local cols, rows = 2, 2
    local gutter = 8
    -- Match size to the main preset grid cells
    local preset_btn_w, preset_btn_h = TimeZigsGetPresetCellSize()
    local box_w = preset_btn_w
    local box_h = preset_btn_h
    local inner_pad = 8
  -- Compact Save button to fit within box_h comfortably
  local btn_w2 = 20
  local btn_h2 = math.min(18, box_h - 6)
  local SAVE_ICON = "💾" -- falls back to tofu if font lacks emoji, but still functional
    local function preset_label_for(i)
      local p = TimeZigsCustomPresets[i]
      if p and p.n and p.d then
        return string.format("%d/%d", p.n, p.d)
      end
      return "--/--"
    end
    local function refresh_label(i)
      local lbl = TimeZigsCustomPresetLabels[i]
      if lbl then lbl.text = preset_label_for(i) end
    end
    local function save_slot(i)
      TimeZigsCustomPresets[i] = { n = TimeZigsNumerator, d = TimeZigsDenominator }
      TimeZigsSaveCustomPresets()
      refresh_label(i)
      renoise.app():show_status(string.format("Saved custom preset %d as %d/%d", i, TimeZigsNumerator, TimeZigsDenominator))
    end
    local function load_slot(i)
      local p = TimeZigsCustomPresets[i]
      if not (p and p.n and p.d) then
        renoise.app():show_status(string.format("Preset %d is empty", i))
        return
      end
      -- Clamp and apply to custom values
      TimeZigsNumerator = math.max(1, math.min(32, tonumber(p.n) or TimeZigsDefaultNumerator))
  TimeZigsDenominator = math.max(2, math.min(32, tonumber(p.d) or TimeZigsDefaultDenominator))
      TimeZigsSave()
      -- If syncing is enabled, update LPB when loading a custom slot
      local s = renoise.song and renoise.song()
      if TimeZigsSyncDenominatorLPB and s and s.transport then
        local new_lpb = TimeZigsGetLPBForDenominator(TimeZigsDenominator)
        if tonumber(s.transport.lpb) ~= new_lpb then s.transport.lpb = new_lpb end
      end
      if TimeZigsGlobalCustomDenominator then
        TimeZigsPresetDenominator = TimeZigsDenominator
        TimeZigsUpdatePresets()
        TimeZigsRefreshPresetButtons()
        if TimeZigsPresetCanvas then TimeZigsPresetCanvas:update() end
      end
      -- If current selection is custom, update it and banner
      if TimeZigsCurrentIsCustom then
        TimeZigsCurrentNumerator = TimeZigsNumerator
        TimeZigsCurrentDenominator = TimeZigsDenominator
        TimeZigsActivePresetLabel = string.format("%d/%d", TimeZigsCurrentNumerator, TimeZigsCurrentDenominator)
        TimeZigsUpdateBanner()
      end
      -- Safe Mode: warn when loading a custom slot that yields a non-integer bar at current LPB
      local lpb = (s and s.transport and tonumber(s.transport.lpb)) and s.transport.lpb or 4
      if TimeZigsSyncDenominatorLPB then
        lpb = TimeZigsGetLPBForDenominator(TimeZigsCurrentDenominator)
      end
      TimeZigsWarnIfNonIntegral(TimeZigsCurrentNumerator, TimeZigsCurrentDenominator, lpb, "custom slot")
      -- Update left-side displayed values
      if TimeZigsVB and TimeZigsVB.views then
        if TimeZigsVB.views.custom_num_value then TimeZigsVB.views.custom_num_value.text = string.format("%d", TimeZigsNumerator) end
        if TimeZigsVB.views.custom_den_value then TimeZigsVB.views.custom_den_value.text = string.format("%d", TimeZigsDenominator) end
      end
      if TimeZigsCustomCanvas then TimeZigsCustomCanvas:update() end
      renoise.app():show_status(string.format("Loaded custom preset %d: %d/%d", i, TimeZigsNumerator, TimeZigsDenominator))
    end

    local right_controls = {}
    local idx = 1
    for r = 1, rows do
      for c = 1, cols do
        local bx = right_x + (c - 1) * (box_w + gutter)
        local by = 24 + (r - 1) * (box_h + gutter) + 6
        -- base button: same styling/size as main grid; clicking it loads the slot
        local base_btn = vb:button{
          text = preset_label_for(idx),
          size = { box_w, box_h },
          origin = { bx, by },
          tooltip = string.format("Load slot %d into custom Time Signature", idx),
          notifier = (function(i) return function() load_slot(i) end end)(idx)
        }
        TimeZigsCustomPresetLabels[idx] = base_btn -- reuse updater to change .text
        table.insert(right_controls, base_btn)
        -- compute positions so Save icon is vertically centered and doesn't overlap the text
        local buttons_x = bx + box_w - inner_pad - btn_w2
        local buttons_y = by + math.floor((box_h - btn_h2) / 2)
        -- Save icon on the right using a Bitmap (clickable via notifier)
        local save_icon = vb:bitmap{
          bitmap = "Icons/Save.bmp",
          mode = "button_color",
          size = { btn_w2, btn_h2 },
          origin = { buttons_x, buttons_y },
          tooltip = string.format("Save current custom Time Signature to slot %d", idx),
          notifier = (function(i) return function() save_slot(i) end end)(idx)
        }
        table.insert(right_controls, save_icon)
        idx = idx + 1
      end
    end

    return vb:stack{
      size = { total_w, total_h },
      canvas,
      header,
      num_dec, num_val, num_inc,
      den_dec, den_val, den_inc,
      unpack(right_controls)
    }
  end

  local custom_canvas_stack = TimeZigsBuildCustomCanvas(vb)

  -- Status label moved into canvas banner as 'current_ts_label'

  -- Section name input
  local section_name_input = vb:textfield{
    text = TimeZigsSectionName,
    width = "100%",
    notifier = function(value)
      TimeZigsSectionName = value or ""
    end
  }
  local section_row = vb:row{
    vb:text{ text = "Section Name", width = "80%" },
    section_name_input
  }

  -- Checkbox: append time signature and LPB to section name
  local append_ts_lpb_cb = vb:checkbox{
    value = TimeZigsAppendPresetToSectionName or false,
    tooltip = "When enabled, will include the selected time signature and current LPB in the section header",
    notifier = function(v)
      TimeZigsAppendPresetToSectionName = v and true or false
      TimeZigsSave()
    end
  }
  local append_label = vb:text{ text = "Append Time Signature and LPB to Section Name" }
  local append_row = vb:row{ append_ts_lpb_cb, append_label }

  -- Settings toggle helpers (starts hidden)
  local function settings_set_visible(v)
    if not (TimeZigsVB and TimeZigsVB.views) then return end
    local views = TimeZigsVB.views
    if views.settings_panel then views.settings_panel.visible = v and true or false end
    if views.settings_toggle_btn then
      views.settings_toggle_btn.text = (v and "Hide Settings ▲" or "Show Settings ▼")
    end
  end

  local settings_toggle_row = vb:row{
    vb:button{
      id = "settings_toggle_btn",
      text = "Show Settings ▼",
      width = "100%",
      notifier = function()
        local v = not (TimeZigsVB.views.settings_panel.visible)
        settings_set_visible(v)
      end
    }
  }

  local settings_panel = vb:column{
    id = "settings_panel",
    visible = false,
    spacing = 6,
    vb:text{ text = "Settings", style = "strong", font = "bold", width = "100%" },
    section_row,
    append_row,
    -- Sync Denominator ↔ LPB
    vb:row{
      vb:checkbox{
        value = TimeZigsSyncDenominatorLPB or false,
        tooltip = "Sync Denominator ↔ LPB: when enabled, changing the Denominator sets LPB accordingly and creation uses the synced LPB (ZLxx). Prevents fractional beat lengths.",
        notifier = function(v)
          TimeZigsSyncDenominatorLPB = v and true or false
          TimeZigsSave()
          -- If turning on, immediately sync current denominator to LPB
          local s = renoise.song and renoise.song()
          if TimeZigsSyncDenominatorLPB and s and s.transport then
            local new_lpb = TimeZigsGetLPBForDenominator(TimeZigsCurrentDenominator)
            if tonumber(s.transport.lpb) ~= new_lpb then s.transport.lpb = new_lpb end
          end
          -- Refresh banner to reflect LPB value used
          TimeZigsUpdateBanner()
        end
      },
      vb:text{ text = "Sync Denominator and LPB" }
    },
    vb:row{
      vb:checkbox{
        value = TimeZigsSafeMode or false,
        tooltip = "Safe/Integer Line mode — Allow only integer beat durations: blocks creation when a bar isn't an integer number of lines. Presets with a • dot in the grid indicate non-integer bar lengths at the current LPB. Disable to allow approximation.",
        notifier = function(v)
          TimeZigsSafeMode = v and true or false
          TimeZigsSave()
        end
      },
      vb:text{ text = "Safe/Integer Line mode - Allow only integer beat durations" }
    },
    -- Mirror: Global Custom Denominator toggle
    vb:row{
      vb:checkbox{
        id = "settings_global_den_cb",
        value = TimeZigsGlobalCustomDenominator or false,
        tooltip = "When enabled, the preset grid's denominator follows the Custom denominator.",
        notifier = function(v)
          TimeZigsGlobalCustomDenominator = v and true or false
          if TimeZigsGlobalCustomDenominator then
            TimeZigsPresetDenominator = TimeZigsDenominator
            TimeZigsUpdatePresets()
            TimeZigsRefreshPresetButtons()
            if TimeZigsPresetCanvas then TimeZigsPresetCanvas:update() end
          end
          -- (removed) sync to custom panel checkbox; control now lives only in Settings
          TimeZigsSave()
        end
      },
      vb:text{ text = "Global Custom Denominator" }
    },
    vb:row{
      vb:checkbox{
        value = TimeZigsFillNotes or false,
        tooltip = "Fill per-beat notes across created bar; uses delay column for fractional positions.",
        notifier = function(v)
          TimeZigsFillNotes = v and true or false
          TimeZigsSave()
        end
      },
      vb:text{ text = "Fill notes (experimental)" }
    }
  }

  -- Main layout (single column)
  local content = vb:column{
    margin = MARGIN,
    spacing = 8,
    preset_canvas_stack,
    custom_canvas_stack,
    vb:space{ height = 8 },
    settings_toggle_row,
    settings_panel,
    vb:space{ height = 10 },
    vb:button{
      text = "Create Phrase",
      width = "100%",
      height = BUTTON_HEIGHT,
      tooltip = "Create a phrase in the currently selected instrument (uses Current Time Signature and LPB)",
      notifier = TimeZigsCreatePhrases
    },
    vb:space{ height = 4 },
    vb:button{
      text = "Create Patterns",
      width = "100%",
      height = BUTTON_HEIGHT,
      tooltip = "Create one bar of patterns using the Current Time Signature and LPB",
      notifier = TimeZigsCreate
    }
  }

  -- ensure initial collapsed state label is correct
  settings_set_visible(false)

  return content
end

-- Update preset button labels without rebuilding
function TimeZigsRefreshPresetButtons()
  -- get current LPB for non-integer highlighting
  local s = renoise.song and renoise.song()
  local lpb = (s and s.transport and tonumber(s.transport.lpb)) and s.transport.lpb or 4
  for i = 1, 16 do
    local btn = TimeZigsPresetButtons[i]
    local preset = TimeZigsPresets[i]
    if btn then
      if i == 16 then
        btn.text = "CUSTOM"
        btn.tooltip = "Use Custom Time Signature"
      elseif preset then
        local base = preset.label
        local integral = TimeZigsIsIntegralBar(preset.numerator or i, preset.denominator or TimeZigsPresetDenominator, lpb)
        local label = base
        if not integral then
          label = base .. " •" -- subtle dot marker for non-integer bar at current LPB
        end
        btn.text = label
        btn.tooltip = ("Apply preset: %s"):format(base) .. (integral and "" or " (non-integer at current LPB)")
      end
    end
  end
end

-- Keyhandler
-- Ported from Paketti Slab O Patterns and Paketti global Keyhandler function

local function TimeZigsCallExternalKeyHandler(dialog, key)
  local handler = rawget(_G, "my_keyhandler_func")
  if type(handler) ~= "function" then
    return key
  end

  local ok, result = pcall(handler, dialog, key)
  if not ok then
    renoise.app():show_status("TimeZigs external keyhandler error: " .. tostring(result))
    return key
  end

  if result == nil then
    return nil
  end

  if type(result) == "table" then
    return result
  end

  return key
end

function TimeZigsKeyHandler(dialog, key)
  local processed_key = TimeZigsCallExternalKeyHandler(dialog, key)
  if processed_key == nil then
    return nil
  end
  if type(processed_key) == "table" then
    key = processed_key
  end

  if key.name == "return" then
    TimeZigsCreate()
    return nil
  elseif key.name == "back" then
    -- keep for future use; no-op in simplified UI
    return key
  elseif key.name == "esc" then
    dialog:close()
    return nil
  elseif key.name == "space" then
    -- keep for future use; no-op in simplified UI
    return key
  elseif string.len(key.name) == 1 then
    -- keep for future use; no-op in simplified UI
    return key
  end

  return key
end

-- Rebuild/close/open --

function TimeZigsRebuild()
  if TimeZigsDialogRef and TimeZigsDialogRef.visible then
    -- close and reopen to rebuild the dialog content
    TimeZigsClose()
    TimeZigsOpen()
  end
end

function TimeZigsClose()
  if TimeZigsDialogRef and TimeZigsDialogRef.visible then
    TimeZigsDialogRef:close()
  end
  TimeZigsDialogRef = nil
  TimeZigsVB = nil
  -- Detach LPB observer if attached
  local s = renoise.song and renoise.song()
  if s and s.transport and s.transport.lpb_observable and TimeZigsLPBObserverAdded then
    if s.transport.lpb_observable:has_notifier(TimeZigsUpdateBanner) then
      s.transport.lpb_observable:remove_notifier(TimeZigsUpdateBanner)
    end
    TimeZigsLPBObserverAdded = false
  end
end

function TimeZigsOpen()
  TimeZigsLoad()
  -- Ensure presets exist
  if not TimeZigsPresets or #TimeZigsPresets == 0 then
    renoise.app():show_status("Error: Presets are empty, regenerating...")
    TimeZigsUpdatePresets()
  end
  TimeZigsVB = renoise.ViewBuilder()
  local content = TimeZigsBuildContent()
  TimeZigsDialogRef = renoise.app():show_custom_dialog(
    "TimeZigs",
    content,
    TimeZigsKeyHandler
  )
  TimeZigsRefreshPresetButtons()
  -- Ensure Renoise captures keyboard for our keyhandler
  renoise.app().window.active_middle_frame = renoise.app().window.active_middle_frame
  -- Attach LPB observer to update banner live on LPB changes
  local s = renoise.song and renoise.song()
  if s and s.transport and s.transport.lpb_observable and not TimeZigsLPBObserverAdded then
    s.transport.lpb_observable:add_notifier(TimeZigsUpdateBanner)
    TimeZigsLPBObserverAdded = true
  end
  -- Initial banner refresh to pick up current LPB
  if TimeZigsUpdateBanner then TimeZigsUpdateBanner() end
end

function TimeZigsToggle()
  if TimeZigsDialogRef and TimeZigsDialogRef.visible then
    TimeZigsClose()
  else
    TimeZigsOpen()
  end
end

-- Menu entries / keybindings --

renoise.tool():add_menu_entry{ name = "Main Menu:Tools:TimeZigs", invoke = TimeZigsToggle }
renoise.tool():add_keybinding{ name = "Pattern Editor:TimeZigs:Toggle", invoke = TimeZigsToggle }
renoise.tool():add_keybinding{ name = "Global:TimeZigs:Toggle", invoke = TimeZigsToggle }

-- Quick-create keybindings for presets 1..16 (16 = CUSTOM)
for i = 1,16 do
  local pe_name = string.format("Pattern Editor:TimeZigs:Create Patterns - Preset %02d", i)
  local gl_name = string.format("Global:TimeZigs:Create Patterns - Preset %02d", i)
  local fn = (function(idx)
    return function() TimeZigsApplyPresetAndCreate(idx) end
  end)(i)
  renoise.tool():add_keybinding{ name = pe_name, invoke = fn }
  renoise.tool():add_keybinding{ name = gl_name, invoke = fn }
end

-- Quick-create keybindings for custom preset slots 1..4
for i = 1,4 do
  local pe_name = string.format("Pattern Editor:TimeZigs:Create Patterns - Custom Preset %02d", i)
  local gl_name = string.format("Global:TimeZigs:Create Patterns - Custom Preset %02d", i)
  local fn = (function(idx)
    return function() TimeZigsApplyCustomPresetSlotAndCreate(idx) end
  end)(i)
  renoise.tool():add_keybinding{ name = pe_name, invoke = fn }
  renoise.tool():add_keybinding{ name = gl_name, invoke = fn }
end

-- Quick-create keybindings for phrases using presets 1..16 (16 = CUSTOM)
for i = 1,16 do
  local gl_name = string.format("Global:TimeZigs:Create Phrases - Preset %02d", i)
  local fn = (function(idx)
    return function() TimeZigsApplyPresetAndCreatePhrase(idx) end
  end)(i)
  renoise.tool():add_keybinding{ name = gl_name, invoke = fn }
end

-- Quick-create keybindings for phrases using custom preset slots 1..4
for i = 1,4 do
  local gl_name = string.format("Global:TimeZigs:Create Phrases - Custom Preset %02d", i)
  local fn = (function(idx)
    return function() TimeZigsApplyCustomPresetSlotAndCreatePhrase(idx) end
  end)(i)
  renoise.tool():add_keybinding{ name = gl_name, invoke = fn }
end

-- Update presets dynamically when the denominator changes
function TimeZigsUpdatePresets()
  TimeZigsPresets = TimeZigsGeneratePresets(TimeZigsPresetDenominator)
  TimeZigsRefreshPresetButtons()
end


