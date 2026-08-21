-- gorf_sound_browser.lua
-- Gorf Program 2 native ROM sound browser for MAME 0.289+
--
-- Gorf boots normally, then the browser takes over the foreground with a small
-- Z80 loop in work RAM and a native Gorf drawchar UI.  Sound playback does not
-- use captured register streams, JSON libraries, WebAudio, or synthesized
-- approximations.  Every catalog entry is an embedded Program-2 music score
-- executed by Gorf's own ROM music interpreter.
--
-- While the browser owns the foreground, its HALT loop calls Gorf's native
-- busaround routine once after every interrupt.  This is required because the
-- Gorf music interpreter is foreground-serviced; interrupts alone do not
-- advance an active ROM score.
--
-- Lua does not write sound registers, capture sound streams, or synthesize audio.
-- It injects only the foreground/browser launcher code, reads the native Gorf
-- music-processor work arrays for status, and optionally asks MAME to record WAV.
--
-- Controls:
--   LEFT / RIGHT  cycle ALL / PRIMARY / SECONDARY
--   UP / DOWN     move selection
--   FIRE          play selected ROM score
--   1P START      exit MAME
--   2P START      play all / stop after current score
--
-- Console:
--   gswav() / gswav(true|false)  toggle/set per-score WAV capture
--   gsall()                       play all scores in current filter
--   gsstop()                      stop current score/play-all
--   gsplay(n)                     play visible score n
--   gslist()                      list visible ROM score catalog
--   gsinfo()                      show selected score details
--   gsaudit()                     dump selected score and music-engine state
--   gsstate()                     dump native Gorf music-processor state
--   gsdiag()                      dump fixed Gorf music-engine anchors
--   gsexit()                      exit MAME
--   gshelp()                      show commands

local VERSION = "0.4.1-20260814-1851"
local BUILD_FILE = "gorf_sound_browser.lua"

local C = {
  CPU_TAG = ":maincpu",

  -- Gorf input ports (reads) share port numbers with primary sound writes.
  COINPORT = 0x10,
  P1PORT = 0x12,

  -- Gorf Program-2 low-level music engine.
  -- These are fixed release-ROM entry points recovered from GORFOS/TERSE
  -- and confirmed by direct game callers in the Program-2 disassembly.
  MUSICFLAG = 0xD0AF,
  PRIMARY_MUSIC = 0xD0B1,
  SECONDARY_MUSIC = 0xD0E1,
  ENDMUS = 0x0B85,
  EMUSIC = 0x0B86,
  BUSAROUND = 0x0F7E,
  BMUSIC = 0x0FAC,
  PMUSIC = 0x0FC2,
  MMUSIC = 0x0FDB,
  MPMUSIC = 0x0FF0,

  -- Browser work RAM. Matches the proven speech-browser layout.
  IDLE_LOOP = 0xD400,
  DRAW_CODE = 0xD420,
  PLAY_CODE = 0xD700,
  DRAW_DATA = 0xD520,
  CALL_STACK = 0xD7E0,

  TAKEOVER_DELAY_SEC = 12.0,
  INPUT_INITIAL_REPEAT = 15,
  INPUT_REPEAT_RATE = 4,
  UI_ROWS = 7,
  UI_WIDTH = 27,
  WAV_POSTROLL_SEC = 0.15,

  -- Native completion/loop detection.  Finite scores end when Gorf's own
  -- music PC reaches ENDMUS.  For play-all only, a repeated non-consecutive
  -- native MUSPC marks a real score control-flow loop and ends that audition.
  LOOP_MIN_TRANSITIONS = 2,

  ATTR_BLUE = 0x0808,
  ATTR_YELLOW = 0x0408,
  ATTR_RED = 0x0C08,
}

local IDLE_LOOP_BYTES = {
  0xFB,                         -- $D400 EI
  0x76,                         -- $D401 HALT; resumes after each interrupt
  0xCD, 0x7E, 0x0F,             -- $D402 CALL $0F7E (busaround)
  0xC3, 0x01, 0xD4,             -- $D405 JP $D401
}

-- Currently established Program-2 score launch points proven by Gorf call sites.
-- These six entries are a seed catalog, not a claim that Gorf has only six
-- audible sound effects.  The full sound audit must also account for indirect
-- starts, parameterized starts, and distinct score paths/entry points.
local ROM_CATALOG = {
  { id="GORF_S_1354", name="SCORE 1354",          chip="secondary", mode="native", address=0x1354, trigger="bmusic", source="W_136D -> _B2MUSIC" },
  { id="GORF_P_136A", name="ATTRACT JOYSTICK FX", chip="primary",   mode="native", address=0x136A, trigger="pmusic", source="AM_TALK -> AM_FX -> pmusic" },
  { id="GORF_P_2669", name="SCORE 2669",          chip="primary",   mode="native", address=0x2669, trigger="bmusic", source="direct Program-2 caller -> bmusic" },
  { id="GORF_S_27A1", name="SCORE 27A1",          chip="secondary", mode="native", address=0x27A1, trigger="bmusic", source="direct Program-2 caller -> bmusic" },
  { id="GORF_S_8BA0", name="SCORE 8BA0",          chip="secondary", mode="native", address=0x8BA0, trigger="pmusic", source="direct Program-2 caller -> pmusic" },
  { id="GORF_S_9786", name="SCORE 9786",          chip="secondary", mode="native", address=0x9786, trigger="bmusic", source="direct Program-2 caller -> bmusic" },
}


local machine = manager.machine
local cpu = machine.devices[C.CPU_TAG]
if not cpu then error("[GORF SOUND] main CPU not found at " .. C.CPU_TAG) end
local program = cpu.spaces and cpu.spaces["program"] or nil
local io_space = cpu.spaces and cpu.spaces["io"] or nil
if not program then error("[GORF SOUND] main CPU program space is unavailable") end
if not io_space then error("[GORF SOUND] main CPU I/O space is unavailable") end

local S = {
  enabled = true,
  takeover = false,
  takeover_attempted = false,
  frame_subscription = nil,
  stop_subscription = nil,
  shortcuts = {},

  catalog = {},
  source_label = "GORF PROGRAM 2 ROM",
  filter = "all",
  selection = { all=1, primary=1, secondary=1 },
  window_first = { all=1, primary=1, secondary=1 },

  status = "WAITING FOR GORF INITIALIZATION",
  last_controls = 0,
  last_2p_start = false,
  hold_dir = 0,
  hold_frames = 0,

  playback = nil,
  batch = nil,

  wav_enabled = false,
  wav_active = false,
  wav_filename = nil,
  wav_stop_at = nil,

  ui_dirty = false,
  draw_count = 0,
  drawchar = nil,
  bmusic = C.BMUSIC,
  pmusic = C.PMUSIC,

}

local function printf(fmt, ...)
  print(string.format(fmt, ...))
end

local function hex2(v) return string.format("$%02X", v & 0xFF) end
local function hex4(v) return string.format("$%04X", v & 0xFFFF) end

local function machine_seconds()
  local ok, value = pcall(function() return machine.time:as_double() end)
  if ok then return value end
  return 0
end

local function read16(addr)
  local lo = program:read_u8(addr)
  local hi = program:read_u8((addr + 1) & 0xFFFF)
  return lo | (hi << 8)
end

local function chip_music_array(chip_name)
  return chip_name == "secondary" and C.SECONDARY_MUSIC or C.PRIMARY_MUSIC
end

-- ---------------------------------------------------------------------------
-- Native Gorf music-processor state
-- ---------------------------------------------------------------------------

local function native_processor_state(chip_name)
  local array = chip_name == "secondary" and C.SECONDARY_MUSIC or C.PRIMARY_MUSIC
  return {
    array = array,
    muspc = read16(array + 0x00),
    startpc = read16(array + 0x02),
    soundbox = program:read_u8(array + 0x04),
    multiple = program:read_u8(array + 0x07),
    mode08 = program:read_u8(array + 0x08),
    notetimer = program:read_u8(array + 0x2E),
    mst = program:read_u8(array + 0x2F),
  }
end

local function set_catalog(entries, label)
  S.catalog = entries
  S.source_label = label or "GORF PROGRAM 2 ROM"
  S.source_path = nil
  for _, filter in ipairs({"all", "primary", "secondary"}) do
    S.selection[filter] = 1
    S.window_first[filter] = 1
  end
  S.filter = "all"
  S.ui_dirty = true
end

local function install_rom_catalog()
  local entries = {}
  for _, src in ipairs(ROM_CATALOG) do
    local e = {}
    for k, v in pairs(src) do e[k] = v end
    entries[#entries + 1] = e
  end
  set_catalog(entries, "GORF PROGRAM 2 ROM")
end

-- ---------------------------------------------------------------------------
-- Gorf validation and native browser display
-- ---------------------------------------------------------------------------

local function find_drawchar()
  local fixed = {
    [0]=0xC5, [1]=0xE5, [2]=0xD5, [3]=0xD6, [4]=0x20,
    [7]=0xD6, [8]=0x0F, [9]=0xFE, [10]=0x0B,
    [13]=0xD6, [14]=0x07, [15]=0x6F, [16]=0x26, [17]=0x00,
    [18]=0x29, [19]=0x29, [20]=0x5D, [21]=0x54, [22]=0x29, [23]=0x19,
  }
  for base = 0x0000, 0x3FFF - 52 do
    local ok = true
    for off, byte in pairs(fixed) do
      if program:read_u8(base + off) ~= byte then ok = false; break end
    end
    if ok then
      local tail = {0xD1,0xE1,0x7C,0xC6,0x07,0x67,0xC1,0xC9}
      local tail_ok = false
      for t = 40, 48 do
        local m = true
        for i = 1, #tail do
          if program:read_u8(base + t + i - 1) ~= tail[i] then m=false; break end
        end
        if m then tail_ok = true; break end
      end
      if tail_ok then return base end
    end
  end
  return nil
end

local function rom_bytes(address, count)
  local out = {}
  for i = 0, count - 1 do
    out[#out + 1] = string.format("%02X", program:read_u8(address + i))
  end
  return table.concat(out, " ")
end

local function validate_program()
  -- English Program-2 SPK_INSERT signature. This first build is intentionally
  -- scoped to the resident English Gorf requested for testing.
  local insert_sig = {
    0x0F,0x3E,0x27,0x0D,0x1F,0x3A,0x2A,0x3E,
    0x19,0x35,0x23,0x09,0x21,0x0D,0x0D,0x3E
  }
  for i = 1, #insert_sig do
    if program:read_u8(0x115D + i - 1) ~= insert_sig[i] then
      return false, string.format("English Program-2 signature differs at %s", hex4(0x115D + i - 1))
    end
  end

  S.drawchar = find_drawchar()
  if not S.drawchar then return false, "Gorf drawchar signature not found" end

  -- Do not byte-scan pmusic. The first build did that and rejected the
  -- stock English ROM despite the release engine using the fixed Program-2
  -- low-level entries below. English SPK_INSERT plus drawchar remain the
  -- compatibility gate; the music addresses are architecture constants.
  if program:read_u8(C.ENDMUS) ~= 0x03 then
    return false, string.format("ENDMUS byte differs at %s", hex4(C.ENDMUS))
  end
  local score1354 = {0x14,0x86,0x10,0x10,0x06,0x10}
  for i = 1, #score1354 do
    if program:read_u8(0x1354 + i - 1) ~= score1354[i] then
      return false, string.format("score $1354 signature differs at %s", hex4(0x1354 + i - 1))
    end
  end
  local amfx = {0x02,0x56,0x13}
  for i = 1, #amfx do
    if program:read_u8(0x136A + i - 1) ~= amfx[i] then
      return false, string.format("AM_FX signature differs at %s", hex4(0x136A + i - 1))
    end
  end

  S.bmusic = C.BMUSIC
  S.pmusic = C.PMUSIC

  return true, string.format("drawchar=%s busaround=%s bmusic=%s pmusic=%s",
    hex4(S.drawchar), hex4(C.BUSAROUND), hex4(S.bmusic), hex4(S.pmusic))
end

local function install_idle_loop()
  for i = 1, #IDLE_LOOP_BYTES do program:write_u8(C.IDLE_LOOP + i - 1, IDLE_LOOP_BYTES[i]) end
  if cpu.state["HALT"] then cpu.state["HALT"].value = 0 end
  if cpu.state["IFF1"] then cpu.state["IFF1"].value = 1 end
  if cpu.state["IFF2"] then cpu.state["IFF2"].value = 1 end
  if cpu.state["SP"] then cpu.state["SP"].value = C.CALL_STACK end
  cpu.state["PC"].value = C.IDLE_LOOP
end

local function clear_video_ram()
  for addr = 0x4000, 0x7FFF do program:write_u8(addr, 0) end
end

local function foreground_idle()
  if not S.takeover or not cpu.state["PC"] then return false end
  local pc = cpu.state["PC"].value & 0xFFFF
  return pc >= C.IDLE_LOOP and pc <= (C.IDLE_LOOP + #IDLE_LOOP_BYTES - 1)
end

local function transliterate_for_gorf(text)
  local s = tostring(text or "")
  s = s:upper()
  local out = {}
  for i = 1, #s do
    local b = s:byte(i)
    if (b >= 0x30 and b <= 0x39) or (b >= 0x41 and b <= 0x5A) or b == 0x20 then
      out[#out + 1] = string.char(b)
    else
      out[#out + 1] = " "
    end
  end
  return table.concat(out)
end

local function fixed_native_text(text, width)
  local s = transliterate_for_gorf(text)
  if #s > width then s = s:sub(1, width) end
  if #s < width then s = s .. string.rep(" ", width - #s) end
  return s
end

local function native_center(text)
  local s = transliterate_for_gorf(text)
  if #s > C.UI_WIDTH then s = s:sub(1, C.UI_WIDTH) end
  local col = math.max(0, (C.UI_WIDTH - #s) // 2)
  return string.rep(" ", col) .. s .. string.rep(" ", C.UI_WIDTH - col - #s)
end

local function screen_line_x(row)
  return ((76 - row * 6) & 0xFF) << 8
end

local function centered_text_y(text)
  return 0x6000 - (#text * 0x0380)
end

local function visible_catalog()
  if S.filter == "all" then return S.catalog end
  local out = {}
  for _, e in ipairs(S.catalog) do
    if e.chip == S.filter then out[#out + 1] = e end
  end
  return out
end

local function selected_entry()
  local list = visible_catalog()
  local index = S.selection[S.filter] or 1
  return index, list[index], list
end

local function keep_selection_visible(index)
  local list = visible_catalog()
  local filter = S.filter
  if #list == 0 then
    S.selection[filter] = 0
    S.window_first[filter] = 1
    return
  end
  if index < 1 then index = 1 end
  if index > #list then index = #list end
  S.selection[filter] = index
  local first = S.window_first[filter] or 1
  if index < first then first = index
  elseif index > first + C.UI_ROWS - 1 then first = index - C.UI_ROWS + 1 end
  local max_first = math.max(1, #list - C.UI_ROWS + 1)
  if first < 1 then first = 1 end
  if first > max_first then first = max_first end
  S.window_first[filter] = first
end

local function status_line()
  local wav = S.wav_enabled and "WAV ON" or "WAV OFF"
  if S.batch then return string.format("PLAY ALL %d %s", S.batch.completed, wav) end
  if S.playback then
    if S.status == "LOOPING" then return "LOOPING " .. wav end
    return "PLAYING " .. wav
  end
  return "READY " .. wav
end

local function native_menu_lines()
  local list = visible_catalog()
  local selected = S.selection[S.filter] or 0
  local first = S.window_first[S.filter] or 1
  local max_first = math.max(1, #list - C.UI_ROWS + 1)
  if first < 1 then first = 1 end
  if first > max_first then first = max_first end
  S.window_first[S.filter] = first

  local lines = {}
  local filter_name = S.filter == "all" and "ALL" or (S.filter == "primary" and "PRIMARY" or "SECONDARY")
  lines[#lines + 1] = { row=0, text=native_center("GORF SOUND " .. filter_name), attr=C.ATTR_BLUE }

  local vmaj, vmin, vpatch = VERSION:match("^(%d+)%.(%d+)%.(%d+)")
  local short_version = vmaj and ("V" .. vmaj .. vmin .. vpatch) or "VER"
  lines[#lines + 1] = {
    row=1,
    text=string.rep(" ", math.max(0, C.UI_WIDTH - #short_version)) .. short_version,
    attr=C.ATTR_BLUE
  }

  if #list == 0 then
    lines[#lines + 1] = { row=2, text=native_center("NO SOUNDS IN FILTER"), attr=C.ATTR_RED }
    for row = 1, C.UI_ROWS - 1 do
      lines[#lines + 1] = { row=2 + row, text=string.rep(" ", C.UI_WIDTH), attr=C.ATTR_RED }
    end
  else
    for row = 0, C.UI_ROWS - 1 do
      local idx = first + row
      local e = list[idx]
      local line = string.rep(" ", C.UI_WIDTH)
      if e then
        local chip = e.chip == "secondary" and "S" or "P"
        line = string.format(" %02d %s %s", idx, chip, fixed_native_text(e.name, C.UI_WIDTH - 6))
      end
      lines[#lines + 1] = {
        row=2 + row,
        text=fixed_native_text(line, C.UI_WIDTH),
        attr=(idx == selected) and C.ATTR_YELLOW or C.ATTR_RED
      }
    end
  end

  lines[#lines + 1] = { row=9, text=native_center(status_line()), attr=C.ATTR_BLUE }
  lines[#lines + 1] = { row=10, text=native_center("UP DOWN SELECT FIRE PLAY"), attr=C.ATTR_YELLOW }
  lines[#lines + 1] = { row=11, text=native_center("LEFT RIGHT CHIP FILTER"), attr=C.ATTR_YELLOW }
  lines[#lines + 1] = {
    row=12,
    text=native_center(S.batch and "1P EXIT 2P STOP" or "1P EXIT 2P PLAY ALL"),
    attr=C.ATTR_YELLOW
  }
  return lines
end

local function write_native_draw_program(lines)
  if not S.drawchar then return false, "native drawchar unavailable" end

  local data = C.DRAW_DATA
  local strings = {}
  for _, line in ipairs(lines) do
    if #line.text > C.UI_WIDTH then return false, "native UI line too long" end
    local addr = data
    for i = 1, #line.text do program:write_u8(data, line.text:byte(i)); data = data + 1 end
    program:write_u8(data, 0); data = data + 1
    strings[#strings + 1] = addr
  end

  local code = {}
  local function emit(v) code[#code + 1] = v & 0xFF end
  local function emit16(v) emit(v); emit(v >> 8) end

  emit(0xF3); emit(0xDD); emit(0xE5); emit(0xFD); emit(0xE5) -- DI/PUSH IX/PUSH IY

  local call_sites = {}
  for i, line in ipairs(lines) do
    emit(0x01); emit16(line.attr)
    emit(0x11); emit16(screen_line_x(line.row))
    emit(0x21); emit16(centered_text_y(line.text))
    emit(0xDD); emit(0x21); emit16(strings[i])
    emit(0xCD); call_sites[#call_sites + 1] = #code + 1; emit16(0)
  end

  emit(0xFD); emit(0xE1); emit(0xDD); emit(0xE1); emit(0xFB)
  emit(0xC3); emit16(C.IDLE_LOOP + 1)

  local draw_string = C.DRAW_CODE + #code
  emit(0xDD); emit(0x7E); emit(0x00)
  emit(0xB7); emit(0xC8)
  emit(0xDD); emit(0x23)
  emit(0xDD); emit(0xE5)
  emit(0xCD); emit16(S.drawchar)
  emit(0xDD); emit(0xE1)
  emit(0x18); emit(0xF0)

  for _, pos in ipairs(call_sites) do
    code[pos] = draw_string & 0xFF
    code[pos + 1] = (draw_string >> 8) & 0xFF
  end

  if C.DRAW_CODE + #code >= C.DRAW_DATA then return false, "native UI code exceeds reserved RAM" end
  if data >= C.CALL_STACK - 0x40 or data > 0xD7FF then return false, "native UI strings exceed work RAM" end

  for i, b in ipairs(code) do program:write_u8(C.DRAW_CODE + i - 1, b) end
  return true
end

local function render_ui_native()
  if not S.takeover or not S.ui_dirty or not foreground_idle() then return end
  local ok, err = write_native_draw_program(native_menu_lines())
  if not ok then
    S.status = "ERROR: " .. err
    printf("[GORF SOUND] %s", err)
    S.ui_dirty = false
    return
  end
  if cpu.state["SP"] then cpu.state["SP"].value = C.CALL_STACK end
  if cpu.state["HALT"] then cpu.state["HALT"].value = 0 end
  cpu.state["PC"].value = C.DRAW_CODE
  S.ui_dirty = false
  S.draw_count = S.draw_count + 1
end

-- ---------------------------------------------------------------------------
-- Sound playback and WAV capture
-- ---------------------------------------------------------------------------

local function safe_slug(text)
  local s = tostring(text or "sound"):lower()
  s = s:gsub("[^a-z0-9]+", "_"):gsub("^_+", ""):gsub("_+$", "")
  if s == "" then s = "sound" end
  return s
end

local function wav_filename(entry)
  return string.format("gorf_sound_%s.wav", safe_slug(entry.id or entry.name))
end

local function stop_owned_wav(reason)
  if not S.wav_active then return end
  pcall(function() machine.sound:stop_recording() end)
  printf("[GORF SOUND] WAV %s: %s", reason or "saved", tostring(S.wav_filename or ""))
  S.wav_active = false
  S.wav_filename = nil
  S.wav_stop_at = nil
end

local function start_entry_wav(entry)
  if S.wav_active then return false, "browser WAV recorder is still active" end
  local already = false
  pcall(function() already = machine.sound.recording == true end)
  if already then return false, "MAME sound recorder is already active" end
  local name = wav_filename(entry)
  local ok, started = pcall(function() return machine.sound:start_recording(name) end)
  if not ok or not started then return false, "MAME could not start WAV " .. name end
  S.wav_active = true
  S.wav_filename = name
  S.wav_stop_at = nil
  printf("[GORF SOUND] WAV recording: %s", name)
  return true
end

local function service_wav_capture()
  if S.wav_active and S.wav_stop_at and machine_seconds() >= S.wav_stop_at then
    stop_owned_wav("saved")
    S.ui_dirty = true
  end
end

local run_native_stop

local function stop_sound(reason)
  if S.playback and S.playback.mode == "native" then
    local ok, err = run_native_stop()
    if not ok then
      printf("[GORF SOUND] native stop failed: %s", tostring(err))
      S.status = "STOP ERROR"
      S.ui_dirty = true
      return false
    end
  end
  if S.playback then
    printf("[GORF SOUND] STOP %s%s", tostring(S.playback.entry.name), reason and (" (" .. reason .. ")") or "")
  end
  S.playback = nil
  if S.wav_active and not S.wav_stop_at then S.wav_stop_at = machine_seconds() + C.WAV_POSTROLL_SEC end
  S.status = "READY"
  S.ui_dirty = true
  return true
end

local function emit_native_emusic(code, array, soundbox)
  local function emit(v) code[#code + 1] = v & 0xFF end
  local function emit16(v) emit(v); emit(v >> 8) end

  -- Exact setup used by Gorf's _EMUSIC/_E2MUSIC wrappers.  emusic itself
  -- performs the matching EXX before returning.
  emit(0xD9)                                  -- EXX
  emit(0x11); emit16(array)                   -- LD DE,music array
  emit(0x21); emit16(0x002F)                  -- LD HL,$002F (MST)
  emit(0x19)                                  -- ADD HL,DE
  emit(0x36); emit(0x01)                      -- LD (HL),1
  emit(0x21); emit16(0x0004)                  -- LD HL,$0004 (SOUNDBOX)
  emit(0x19)                                  -- ADD HL,DE
  emit(0x36); emit(soundbox)                  -- primary $18 / secondary $58
  emit(0xCD); emit16(C.EMUSIC)                -- CALL emusic
end

local function write_native_play_launcher(entry)
  local array = chip_music_array(entry.chip)
  local trigger = entry.trigger == "bmusic" and C.BMUSIC or C.PMUSIC
  local code = {}
  local function emit(v) code[#code + 1] = v & 0xFF end
  local function emit16(v) emit(v); emit(v >> 8) end

  emit(0xF3)                                  -- DI
  emit(0xDD); emit(0xE5)                     -- PUSH IX
  emit(0xFD); emit(0xE5)                     -- PUSH IY

  -- The browser auditions one score at a time.  Stop both native processors
  -- through Gorf's ROM emusic routine, then start the selected score using the
  -- same bmusic/pmusic entry used by its original game caller.
  emit_native_emusic(code, C.PRIMARY_MUSIC, 0x18)
  emit_native_emusic(code, C.SECONDARY_MUSIC, 0x58)

  emit(0x3E); emit(0x01)                     -- LD A,1
  emit(0x32); emit16(C.MUSICFLAG)             -- LD (MUSICFLAG),A
  emit(0x21); emit16(entry.address)           -- LD HL,score
  emit(0xFD); emit(0x21); emit16(array)       -- LD IY,selected music array
  emit(0xCD); emit16(trigger)                 -- CALL original bmusic/pmusic
  emit(0xFD); emit(0xE1)                     -- POP IY
  emit(0xDD); emit(0xE1)                     -- POP IX
  emit(0xFB)                                  -- EI
  emit(0xC3); emit16(C.IDLE_LOOP + 1)         -- JP HALT/service loop

  if C.PLAY_CODE + #code >= (C.CALL_STACK - 0x40) then return false, "native launcher exceeds reserved RAM" end
  for i, b in ipairs(code) do program:write_u8(C.PLAY_CODE + i - 1, b) end
  return true
end

local function write_native_stop_launcher()
  local code = {}
  local function emit(v) code[#code + 1] = v & 0xFF end
  local function emit16(v) emit(v); emit(v >> 8) end

  emit(0xF3)
  emit(0xDD); emit(0xE5)
  emit(0xFD); emit(0xE5)
  emit_native_emusic(code, C.PRIMARY_MUSIC, 0x18)
  emit_native_emusic(code, C.SECONDARY_MUSIC, 0x58)
  emit(0xAF)                                  -- XOR A
  emit(0x32); emit16(C.MUSICFLAG)             -- LD (MUSICFLAG),0
  emit(0xFD); emit(0xE1)
  emit(0xDD); emit(0xE1)
  emit(0xFB)
  emit(0xC3); emit16(C.IDLE_LOOP + 1)

  if C.PLAY_CODE + #code >= (C.CALL_STACK - 0x40) then return false, "native stop launcher exceeds reserved RAM" end
  for i, b in ipairs(code) do program:write_u8(C.PLAY_CODE + i - 1, b) end
  return true
end

run_native_stop = function()
  local ok, err = write_native_stop_launcher()
  if not ok then return false, err end
  if cpu.state["SP"] then cpu.state["SP"].value = C.CALL_STACK end
  if cpu.state["HALT"] then cpu.state["HALT"].value = 0 end
  cpu.state["PC"].value = C.PLAY_CODE
  return true
end

local function start_native(entry, index, source)
  local ok, err = write_native_play_launcher(entry)
  if not ok then return false, err end

  if cpu.state["SP"] then cpu.state["SP"].value = C.CALL_STACK end
  if cpu.state["HALT"] then cpu.state["HALT"].value = 0 end
  cpu.state["PC"].value = C.PLAY_CODE

  S.playback = {
    mode="native",
    entry=entry,
    index=index,
    source=source or "manual",
    start_time=machine_seconds(),
    music_array=chip_music_array(entry.chip),
    seen_running=false,
    last_pc=nil,
    pc_seen={},
    transitions=0,
    loop_detected=false,
    loop_pc=nil,
  }
  return true
end

local function start_entry(entry, index, source)
  if not S.takeover then return false, "browser has not taken over yet" end
  if not entry then return false, "no selected sound" end
  if S.playback then stop_sound("restart") end
  if S.wav_active then return false, "wait for current WAV to finish" end

  if S.wav_enabled then
    local ok, err = start_entry_wav(entry)
    if not ok then return false, err end
  end

  if entry.mode ~= "native" then return false, "ROM browser catalog contains a non-native entry" end
  local ok, err = start_native(entry, index, source)

  if not ok then
    if S.wav_active then stop_owned_wav("discarded") end
    return false, err
  end

  local chip = entry.chip == "secondary" and "SECONDARY" or "PRIMARY"
  printf("[GORF SOUND] PLAY %02d %s %s score=%s trigger=%s",
    index, chip, entry.name, hex4(entry.address), tostring(entry.trigger or "pmusic"):upper())
  S.status = "PLAYING"
  S.ui_dirty = true
  return true
end

local function finish_playback(reason)
  local p = S.playback
  if not p then return end
  local elapsed = machine_seconds() - p.start_time
  local ok, err = run_native_stop()
  if not ok then
    printf("[GORF SOUND] native stop failed at end of %s: %s", tostring(p.entry.name), tostring(err))
    S.status = "STOP ERROR"
    S.ui_dirty = true
    return
  end
  printf("[GORF SOUND] END %02d %s elapsed=%.3fs%s",
    p.index, tostring(p.entry.name), elapsed, reason and (" " .. reason) or "")
  S.playback = nil
  if S.wav_active then S.wav_stop_at = machine_seconds() + C.WAV_POSTROLL_SEC end
  S.status = "READY"
  S.ui_dirty = true
end

local function service_playback()
  local p = S.playback
  if not p then return end

  local pc = read16(p.music_array)
  if pc ~= C.ENDMUS then p.seen_running = true end

  -- The game's normal finite-score completion is authoritative.
  if p.seen_running and pc == C.ENDMUS then
    finish_playback("NATIVE END")
    return
  end

  -- Track only changes in Gorf's own MUSPC.  A repeated PC after at least two
  -- intervening score transitions is a native score control-flow cycle, not an
  -- audio/output heuristic.  Manual audition keeps the real loop running;
  -- play-all stops it through emusic after one detected cycle so it can advance.
  if pc ~= C.ENDMUS and pc ~= p.last_pc then
    p.transitions = p.transitions + 1
    local first_transition = p.pc_seen[pc]
    if first_transition and (p.transitions - first_transition) >= C.LOOP_MIN_TRANSITIONS then
      if not p.loop_detected then
        p.loop_detected = true
        p.loop_pc = pc
        printf("[GORF SOUND] LOOP %02d %s MUSPC=%s transitions=%d",
          p.index, tostring(p.entry.name), hex4(pc), p.transitions)
        if p.source == "batch" then
          finish_playback("NATIVE LOOP")
          return
        end
        S.status = "LOOPING"
        S.ui_dirty = true
      end
    else
      p.pc_seen[pc] = p.transitions
    end
    p.last_pc = pc
  end
end

local function set_wav_capture(value)
  if value == nil then value = not S.wav_enabled end
  S.wav_enabled = value == true
  printf("[GORF SOUND] WAV capture %s", S.wav_enabled and "ON" or "OFF")
  S.ui_dirty = true
  return S.wav_enabled
end

-- ---------------------------------------------------------------------------
-- Selection, play-all and controls
-- ---------------------------------------------------------------------------

local function move_selection(delta)
  local list = visible_catalog()
  if #list == 0 then return end
  local current = S.selection[S.filter] or 1
  if current < 1 then current = 1 end
  local n = current + delta
  if n < 1 then n = #list elseif n > #list then n = 1 end
  keep_selection_visible(n)
  S.status = "READY"
  S.ui_dirty = true
end

local FILTERS = { "all", "primary", "secondary" }
local function cycle_filter(delta)
  local at = 1
  for i, f in ipairs(FILTERS) do if f == S.filter then at = i; break end end
  at = at + delta
  if at < 1 then at = #FILTERS elseif at > #FILTERS then at = 1 end
  S.filter = FILTERS[at]
  local list = visible_catalog()
  local sel = S.selection[S.filter] or 1
  if #list == 0 then sel = 0 elseif sel < 1 or sel > #list then sel = 1 end
  S.selection[S.filter] = sel
  keep_selection_visible(sel)
  S.status = "READY"
  S.ui_dirty = true
end

local function start_play_all()
  if not S.takeover then print("[GORF SOUND] gsall(): browser has not taken over yet"); return false end
  if S.batch then print("[GORF SOUND] gsall(): play-all already active"); return false end
  if S.playback or S.wav_active then print("[GORF SOUND] gsall(): wait for current sound/WAV"); return false end
  local list = visible_catalog()
  if #list == 0 then print("[GORF SOUND] gsall(): no sounds in current filter"); return false end
  S.batch = { next_index=1, current_index=nil, completed=0, total=#list, stop_requested=false }
  printf("[GORF SOUND] play-all: %d sounds; WAV %s", #list, S.wav_enabled and "ON" or "OFF")
  S.ui_dirty = true
  return true
end

local function stop_play_all()
  if not S.batch then
    if S.playback then stop_sound("user stop"); return true end
    print("[GORF SOUND] gsstop(): nothing is playing")
    return false
  end
  S.batch.stop_requested = true
  if S.playback then
    print("[GORF SOUND] play-all will stop after current sound")
  elseif not S.wav_active then
    printf("[GORF SOUND] play-all stopped: %d/%d completed", S.batch.completed, S.batch.total)
    S.batch = nil
    S.ui_dirty = true
  end
  return true
end

local function service_batch()
  local b = S.batch
  if not b then return end

  if b.current_index and not S.playback and not S.wav_active then
    b.completed = b.completed + 1
    b.current_index = nil
    if b.stop_requested then
      printf("[GORF SOUND] play-all stopped: %d/%d completed", b.completed, b.total)
      S.batch = nil
      S.ui_dirty = true
      return
    end
  end

  if b.stop_requested and not b.current_index then
    printf("[GORF SOUND] play-all stopped: %d/%d completed", b.completed, b.total)
    S.batch = nil
    S.ui_dirty = true
    return
  end
  if b.current_index or S.playback or S.wav_active then return end

  local list = visible_catalog()
  if b.next_index > #list then
    printf("[GORF SOUND] play-all complete: %d sounds", b.completed)
    S.batch = nil
    S.ui_dirty = true
    return
  end

  local index = b.next_index
  b.next_index = b.next_index + 1
  b.current_index = index
  S.selection[S.filter] = index
  keep_selection_visible(index)
  local ok, err = start_entry(list[index], index, "batch")
  if not ok then
    printf("[GORF SOUND] play-all error at %d: %s", index, tostring(err))
    S.batch = nil
    S.ui_dirty = true
  end
end

local function read_controls()
  local raw = io_space:read_u8(C.P1PORT)
  local joy = (raw ~ 0x0F) & 0x0F
  local fire = ((raw & 0x10) == 0) and 0x10 or 0
  return joy | fire
end

local function read_1p_start()
  return ((~io_space:read_u8(C.COINPORT)) & 0x10) ~= 0
end

local function read_2p_start()
  return ((~io_space:read_u8(C.COINPORT)) & 0x20) ~= 0
end

local function process_inputs()
  if not S.takeover then return end

  local c = read_controls()
  local start2 = read_2p_start()
  local start2_pressed = start2 and not S.last_2p_start

  if S.batch then
    if start2_pressed then stop_play_all() end
    if read_1p_start() then machine:exit() end
    S.last_controls = c
    S.last_2p_start = start2
    return
  end

  if start2_pressed then start_play_all() end

  local pressed = c & (~S.last_controls) & 0x3F
  if (pressed & 0x04) ~= 0 then cycle_filter(-1) end
  if (pressed & 0x08) ~= 0 then cycle_filter(1) end

  local dir = 0
  if (c & 0x01) ~= 0 and (c & 0x02) == 0 then dir = -1
  elseif (c & 0x02) ~= 0 and (c & 0x01) == 0 then dir = 1 end

  if dir ~= 0 then
    if dir ~= S.hold_dir then
      S.hold_dir = dir
      S.hold_frames = 0
      move_selection(dir)
    else
      S.hold_frames = S.hold_frames + 1
      if S.hold_frames >= C.INPUT_INITIAL_REPEAT
          and ((S.hold_frames - C.INPUT_INITIAL_REPEAT) % C.INPUT_REPEAT_RATE) == 0 then
        move_selection(dir)
      end
    end
  else
    S.hold_dir = 0
    S.hold_frames = 0
  end

  if (pressed & 0x10) ~= 0 then
    local index, e = selected_entry()
    if e then
      if S.playback and S.playback.index == index and S.playback.entry == e then
        stop_sound("fire stop")
      else
        local ok, err = start_entry(e, index, "manual")
        if not ok then printf("[GORF SOUND] PLAY ERROR: %s", tostring(err)); S.status = "PLAY ERROR" end
      end
    end
  end

  if read_1p_start() then machine:exit() end
  S.last_controls = c
  S.last_2p_start = start2
end

-- ---------------------------------------------------------------------------
-- Console commands
-- ---------------------------------------------------------------------------

local function console_list()
  local list = visible_catalog()
  printf("[GORF SOUND] %s filter: %d entries; source=%s", S.filter:upper(), #list, S.source_label)
  for i, e in ipairs(list) do
    printf("[GORF SOUND] %02d %-9s %-24s ROM %s %s",
      i, e.chip:upper(), e.name, hex4(e.address), tostring(e.trigger):upper())
  end
  return #list
end

local function console_info()
  local index, e = selected_entry()
  if not e then print("[GORF SOUND] no selected sound"); return nil end
  printf("[GORF SOUND] selected %02d id=%s name=%s", index, tostring(e.id), tostring(e.name))
  printf("[GORF SOUND] chip=%s mode=NATIVE ROM", e.chip)
  printf("[GORF SOUND] ROM score=%s trigger=%s",
    hex4(e.address), tostring(e.trigger or "pmusic"):upper())
  if e.source then printf("[GORF SOUND] source=%s", e.source) end
  return e
end

local function console_play(index)
  index = math.floor(tonumber(index) or 0)
  local list = visible_catalog()
  if index < 1 or index > #list then
    printf("[GORF SOUND] gsplay(): index must be 1..%d", #list)
    return false
  end
  S.selection[S.filter] = index
  keep_selection_visible(index)
  local ok, err = start_entry(list[index], index, "console")
  if not ok then printf("[GORF SOUND] gsplay(): %s", tostring(err)) end
  return ok
end

local function console_audit()
  local index, e = selected_entry()
  if not e then print("[GORF SOUND] gsaudit(): no selected score"); return false end
  local array = chip_music_array(e.chip)
  printf("[GORF SOUND] AUDIT %02d %s %s", index, e.chip:upper(), e.name)
  printf("[GORF SOUND] score=%s trigger=%s source=%s",
    hex4(e.address), tostring(e.trigger):upper(), tostring(e.source or "--"))
  printf("[GORF SOUND] score bytes %s: %s", hex4(e.address), rom_bytes(e.address, 48))
  printf("[GORF SOUND] array=%s MUSPC=%s STARTPC=%s SOUNDBOX=%02X multiple=%02X mode08=%02X NOTETIMER=%02X MST=%02X",
    hex4(array), hex4(read16(array)), hex4(read16(array + 2)),
    program:read_u8(array + 4), program:read_u8(array + 7),
    program:read_u8(array + 8), program:read_u8(array + 0x2E), program:read_u8(array + 0x2F))
  printf("[GORF SOUND] MUSICFLAG=%02X busaround=%s emusic=%s bmusic=%s pmusic=%s",
    program:read_u8(C.MUSICFLAG), hex4(C.BUSAROUND), hex4(C.EMUSIC), hex4(C.BMUSIC), hex4(C.PMUSIC))
  return true
end

local function console_state()
  for _, chip_name in ipairs({"primary", "secondary"}) do
    local s = native_processor_state(chip_name)
    printf("[GORF SOUND] %-9s array=%s MUSPC=%s STARTPC=%s SOUNDBOX=%02X multiple=%02X mode08=%02X NOTETIMER=%02X MST=%02X",
      chip_name:upper(), hex4(s.array), hex4(s.muspc), hex4(s.startpc), s.soundbox,
      s.multiple, s.mode08, s.notetimer, s.mst)
  end
  printf("[GORF SOUND] MUSICFLAG=%02X", program:read_u8(C.MUSICFLAG))
  return true
end

local function console_diag()
  printf("[GORF SOUND] diagnostic: drawchar=%s busaround=%s emusic=%s bmusic=%s pmusic=%s",
    S.drawchar and hex4(S.drawchar) or "--", hex4(C.BUSAROUND), hex4(C.EMUSIC), hex4(C.BMUSIC), hex4(C.PMUSIC))
  printf("[GORF SOUND] ROM %s busaround: %s", hex4(C.BUSAROUND), rom_bytes(C.BUSAROUND, 26))
  printf("[GORF SOUND] ROM %s emusic: %s", hex4(C.EMUSIC), rom_bytes(C.EMUSIC, 36))
  printf("[GORF SOUND] ROM %s bmusic: %s", hex4(C.BMUSIC), rom_bytes(C.BMUSIC, 22))
  printf("[GORF SOUND] ROM %s pmusic: %s", hex4(C.PMUSIC), rom_bytes(C.PMUSIC, 26))
  printf("[GORF SOUND] MUSICFLAG=%02X P1+08=%02X P2+08=%02X",
    program:read_u8(C.MUSICFLAG),
    program:read_u8(C.PRIMARY_MUSIC + 0x08),
    program:read_u8(C.SECONDARY_MUSIC + 0x08))
  return true
end

local function print_console_commands()
  print("[GORF SOUND] console commands:")
  print("  gswav() / gswav(true|false)   WAV capture toggle/set")
  print("  gsall()                        play all in current filter")
  print("  gsstop()                       stop current sound/play-all")
  print("  gsplay(n)                      play visible item n")
  print("  gslist()                       list visible catalog")
  print("  gsinfo()                       selected ROM score details")
  print("  gsaudit()                      dump selected score/engine state")
  print("  gsstate()                      dump native Gorf processor state")
  print("  gsdiag()                       dump Gorf music-engine anchors")
  print("  gsexit()                       exit MAME")
  print("  gshelp()                       show this list")
end

local function install_console_shortcut(name, handler)
  local previous = rawget(_G, name)
  S.shortcuts[name] = { handler=handler, previous=previous, restore=previous ~= nil }
  rawset(_G, name, handler)
end

local function install_console_shortcuts()
  install_console_shortcut("gswav", function(value) return set_wav_capture(value) end)
  install_console_shortcut("gsall", function() return start_play_all() end)
  install_console_shortcut("gsstop", function() return stop_play_all() end)
  install_console_shortcut("gsplay", function(index) return console_play(index) end)
  install_console_shortcut("gslist", function() return console_list() end)
  install_console_shortcut("gsinfo", function() return console_info() end)
  install_console_shortcut("gsaudit", function() return console_audit() end)
  install_console_shortcut("gsstate", function() return console_state() end)
  install_console_shortcut("gsdiag", function() return console_diag() end)
  install_console_shortcut("gsexit", function() machine:exit() end)
  install_console_shortcut("gshelp", function() print_console_commands() end)
end

local function restore_console_shortcuts()
  for name, shortcut in pairs(S.shortcuts) do
    if rawget(_G, name) == shortcut.handler then
      if shortcut.restore then rawset(_G, name, shortcut.previous)
      else rawset(_G, name, nil) end
    end
  end
  S.shortcuts = {}
end

-- ---------------------------------------------------------------------------
-- Takeover and frame service
-- ---------------------------------------------------------------------------

local function takeover(reason)
  if S.takeover then return true end
  local ok, why = validate_program()
  if not ok then
    S.status = "PROGRAM VALIDATION FAILED"
    printf("[GORF SOUND] takeover refused: %s", why)
    return false
  end

  clear_video_ram()
  install_idle_loop()

  S.takeover = true
  local stop_ok, stop_err = run_native_stop()
  if not stop_ok then
    S.status = "NATIVE STOP FAILED"
    printf("[GORF SOUND] takeover refused: native stop failed: %s", tostring(stop_err))
    S.takeover = false
    return false
  end
  S.last_controls = 0
  S.last_2p_start = read_2p_start()
  S.hold_dir = 0
  S.hold_frames = 0
  S.playback = nil
  S.batch = nil
  S.status = "READY"
  S.ui_dirty = true

  printf("[GORF SOUND] browser takeover active (%s); %s", reason or "manual", why)
  printf("[GORF SOUND] catalog: %d entries; source=%s", #S.catalog, S.source_label)
  print("[GORF SOUND] controls: UP/DOWN select; LEFT/RIGHT chip filter; FIRE play/stop current; 1P exit; 2P play all/stop")
  return true
end

local function on_frame()
  if not S.enabled then return end

  if not S.takeover then
    if not S.takeover_attempted and machine_seconds() >= C.TAKEOVER_DELAY_SEC then
      S.takeover_attempted = true
      if takeover("auto") then render_ui_native() end
    end
    return
  end

  process_inputs()
  service_playback()
  service_wav_capture()
  service_batch()
  render_ui_native()
end

print("============================================================")
printf("[GORF SOUND] GORF SOUND BROWSER %s", VERSION)
printf("[GORF SOUND] takeover RAM: %s; UI code: %s; native launcher: %s; ROM patching: NONE",
  hex4(C.IDLE_LOOP), hex4(C.DRAW_CODE), hex4(C.PLAY_CODE))
printf("[GORF SOUND] Gorf Program-2 engine: bmusic=%s pmusic=%s",
  hex4(C.BMUSIC), hex4(C.PMUSIC))
printf("[GORF SOUND] native engine: busaround=%s emusic=%s bmusic=%s pmusic=%s", hex4(C.BUSAROUND), hex4(C.EMUSIC), hex4(C.BMUSIC), hex4(C.PMUSIC))
print("[GORF SOUND] playback: embedded Gorf ROM scores through the native music interpreter")
print("[GORF SOUND] Lua sound writes/capture/replay: NONE; completion monitor: native MUSPC only")
install_console_shortcuts()
print_console_commands()
print("============================================================")

install_rom_catalog()
printf("[GORF SOUND] ROM seed catalog: %d currently established top-level launch points", #S.catalog)

if emu.add_machine_frame_notifier then
  S.frame_subscription = emu.add_machine_frame_notifier(on_frame)
else
  emu.register_frame_done(on_frame, "gorf_sound_browser")
end

if emu.add_machine_stop_notifier then
  S.stop_subscription = emu.add_machine_stop_notifier(function()
    S.enabled = false
    if S.wav_active then stop_owned_wav("closed") end
    restore_console_shortcuts()
  end)
end

printf("[GORF SOUND] %s loaded from %s; Gorf boots normally, ROM browser takeover begins after %.1fs",
  VERSION, BUILD_FILE, C.TAKEOVER_DELAY_SEC)
