-- Groups — by Cannonballdex

---@type Mq
local mq = require('mq')
local LCP = require('lib.LCP')
local ICONS = require('mq.Icons')
---@type ImGui
require 'ImGui'

local function ensure_dannet_loaded()
  print('\agPlugin \atMQ2DanNet \ay is required.')
  print('\ayLOADING.. \agPlugin \atDanNet')
  mq.cmd('/plugin dannet')
  -- give the plugin a moment to initialize
  mq.delay(3000)
end

if not mq.TLO.Plugin('mq2dannet')() then
  ensure_dannet_loaded()
end

-- reload tracking
local last_ini_raw = nil
-- Disable config debug highlight conflicts if available
pcall(function() io.configdebughighlightconflicts = false end)

local function printf(fmt, ...) print(string.format(fmt, ...)) end

-- Helpers --------------------------------------------------------------------
local function safe(f, ...)
  local ok, res = pcall(f, ...)
  if not ok then return nil end
  return res
end

local function split(inputstr, sep)
  if type(inputstr) ~= 'string' then return {} end
  sep = sep or '%s'
  local t = {}
  for field, s in string.gmatch(inputstr, "([^" .. sep .. "]*)(" .. sep .. "?)") do
    table.insert(t, field)
    if s == "" then return t end
  end
  return t
end

local function normalize(s)
  if not s then return '' end
  return tostring(s):gsub('%s+',''):lower()
end

local function file_exists(path)
  local f = io.open(path, "rb")
  if f then f:close() return true end
  return false
end

local function copy_file(src, dest)
  local inf = io.open(src, "rb")
  if not inf then return false end
  local data = inf:read("*a")
  inf:close()
  local outf = io.open(dest, "wb")
  if not outf then return false end
  outf:write(data)
  outf:close()
  return true
end

-- ImGui helper
local function HelpMarker(desc)
  if not desc then return end
  if ImGui.IsItemHovered() then
    ImGui.BeginTooltip()
    ImGui.PushTextWrapPos(ImGui.GetFontSize() * 35.0)
    ImGui.Text(desc)
    ImGui.PopTextWrapPos()
    ImGui.EndTooltip()
  end
end

-- Config / state ------------------------------------------------------------
-- Use groups.ini (as canonical settings file)
local SETTINGS_FILE = 'Groups.ini'
local MAX_GROUP_SLOTS = 6 -- indices 0..5

local args = { SETTINGS_FILE }
local settings = {}
local sections = {}
local config_dir, settings_path

local output = function(msg) print('\a-t[Groups] '..msg) end

-- GUI state
local openGUI = true
local shouldDrawGUI = true
local SaveGroup = ""    -- visible input: the suffix/label user types (we will prepend CleanName_ when saving)
local DeleteGroup = ""

-- Work queue flags
local pending_scan = false
local pending_scan_suspend = false

-- Pending pop request: set by UI thread, processed in loop (yieldable) thread
-- Structure: { targetID = number, owner = string, tType = string } or nil
local pending_pop = nil

-- Pending disband request queued by UI; processed on loop thread:
-- { groupName = string, members = { 'Member1', 'Member2', ... } }
local pending_disband = nil

-- Presence tracking / notifications
local presence_state = {}          -- map normalized member -> boolean (true = present)
local presence_owner = {}          -- map normalized member -> owner name when present (or nil)
local recent_notifications = {}    -- array of {msg=string, ts=os.time(), color={r,g,b,a}}
local NOTIFY_MAX = 40

-- Roles lookup
local Roles = {
  [1] = "MainTank", [2] = "MainAssist", [3] = "Puller", [4] = "MarkNpc", [5] = "MasterLooter",
  ["MainTank"] = 1, ["MainAssist"] = 2, ["Puller"] = 3, ["MarkNpc"] = 4, ["MasterLooter"] = 5
}

-- Settings load/save --------------------------------------------------------
local function save_settings()
  if not settings_path then return end
  safe(function() LCP.save(settings_path, settings) end)
end

local function refresh_sections_from_ini()
  local ini_raw = safe(function() return mq.TLO.Ini(args[1])() end) or ''
  -- only update sections if changed
  if ini_raw ~= last_ini_raw then
    sections = split(ini_raw, '|')
    last_ini_raw = ini_raw
    return true -- indicates changed
  end
  return false -- no change
end

local function load_settings()
  config_dir = mq.configDir:gsub('\\', '/') .. '/'

  -- canonical and legacy names
  local canonical = 'Groups.ini'
  local legacy = 'Crew.ini'

  local canonical_path = config_dir .. canonical
  local legacy_path = config_dir .. legacy

-- If legacy exists and canonical does not, copy legacy -> canonical
  if file_exists(legacy_path) and not file_exists(canonical_path) then
    local ok = copy_file(legacy_path, canonical_path)
    if ok then
      output(('Found %s and created %s (copied).'):format(legacy, canonical))
    else
      output(('Found %s but failed to copy to %s.'):format(legacy, canonical))
    end
  end

  -- Ensure canonical exists: if not, create empty settings file via LCP.save
  if not file_exists(canonical_path) then
    -- initialize empty settings table on disk
    settings = {}
    settings_path = canonical_path
    safe(function() LCP.save(settings_path, settings) end)
    output(('Created empty %s'):format(canonical))
  end

  -- Use canonical from now on
  SETTINGS_FILE = canonical
  args[1] = SETTINGS_FILE
  settings_path = config_dir .. SETTINGS_FILE

  -- Load settings if present
  if file_exists(settings_path) then
    settings = safe(function() return LCP.load(settings_path) end) or {}
  else
    settings = {}
    save_settings()
  end

  -- refresh and record initial INI raw
  safe(function()
    last_ini_raw = safe(function() return mq.TLO.Ini(args[1])() end) or ''
    sections = split(last_ini_raw, '|')
  end)
end

-- Utility: collect saved member names (normalized -> original)
local function collect_saved_members()
  local members = {}
  for _, group in pairs(settings or {}) do
    if type(group) == 'table' then
      for i = 0, MAX_GROUP_SLOTS - 1 do
        local m = group['Member' .. i]
        if m and m ~= '' then members[normalize(m)] = m end
      end
    end
  end
  return members
end

-- Helpers for leader parsing / quoting --------------------------------------
-- Get the leader for a saved group. Prefer stored Member0; otherwise parse the group name prefix before '_'
local function get_group_leader(groupName, groupTable)
  if type(groupTable) == 'table' then
    local leader = groupTable['Member0']
    if leader and leader ~= '' then return leader end
  end
  if type(groupName) == 'string' then
    local underscore_pos = groupName:find('_', 1, true)
    if underscore_pos then
      local leader = groupName:sub(1, underscore_pos - 1)
      if leader ~= '' then return leader end
    end
  end
  return ''
end

local function quote_name(name)
  if not name then return '""' end
  local escaped = tostring(name):gsub('"', '\\"')
  return ('"%s"'):format(escaped)
end

local function get_group_label(groupName)
  if type(groupName) ~= 'string' then return '' end
  local underscore_pos = groupName:find('_', 1, true)
  if not underscore_pos then return '' end
  local label = groupName:sub(underscore_pos + 1)
  return (label ~= '' and label) or ''
end

-- Class/level helpers -------------------------------------------------------
local function get_member_class_level(member)
  if not member or member == '' then return nil, nil end
  local sMerc = safe(function() return mq.TLO.Spawn(string.format('mercenary "%s"', member)) end)
  if sMerc and sMerc() and safe(function() return sMerc.CleanName and sMerc.CleanName() end) == member then
    local class = safe(function() return sMerc.Class and (sMerc.Class.ShortName and sMerc.Class.ShortName() or sMerc.Class()) end) or 'Merc'
    local level = safe(function() return sMerc.Level and sMerc.Level() end)
    return class, level
  end
  local sPC = safe(function() return mq.TLO.Spawn(string.format('pc "%s"', member)) end)
  if sPC and sPC() and safe(function() return sPC.CleanName and sPC.CleanName() end) == member then
    local class = safe(function() return sPC.Class and (sPC.Class.ShortName and sPC.Class.ShortName() or sPC.Class()) end) or 'PC'
    local level = safe(function() return sPC.Level and sPC.Level() end)
    return class, level
  end
  return nil, nil
end

local function format_member_label(member)
  local class, level = get_member_class_level(member)
  if class and level then return string.format('%s (%s %d)', member, tostring(class), tonumber(level)) end
  if class then return string.format('%s (%s)', member, tostring(class)) end
  return member
end

local function get_member_roles_string(memberTlo)
  if not memberTlo then return nil end
  local roles = {}
  for i = 1, 5 do
    local rn = Roles[i]
    if rn then
      local ok, val = pcall(function() if memberTlo[rn] then return memberTlo[rn]() end end)
      if ok and val then table.insert(roles, rn) end
    end
  end
  if #roles > 0 then return table.concat(roles, ',') end
  return nil
end

-- Merc TLO helpers ----------------------------------------------------------
local function tlo_merc_lookup_try_variants(member)
  if not member or member == '' then return nil end
  local tries = { member, ("'%s'"):format(member), ('"%s"'):format(member) }
  for _, key in ipairs(tries) do
    local ok, merc = pcall(function() return mq.TLO.Mercenary(key) end)
    if ok and merc and merc() then return merc end
  end
  return nil
end

local function merc_status_from_tlo_by_owner(owner)
  if not owner or owner == '' then return 'NONE' end
  local merc = tlo_merc_lookup_try_variants(owner)
  if not merc then return 'NONE' end

  local ok, val = pcall(function() return merc.Active and merc.Active() end)
  if ok and val then return 'ACTIVE' end
  ok, val = pcall(function() return merc.IsActive and merc.IsActive() end)
  if ok and val then return 'ACTIVE' end

  ok, val = pcall(function() return (merc.IsSuspended and merc.IsSuspended()) or (merc.Suspended and merc.Suspended()) end)
  if ok and val then return 'SUSPENDED' end

  ok, val = pcall(function() return merc.State and merc.State() end)
  if ok and val and tostring(val) ~= '' then
    local su = tostring(val):upper()
    if su:find('ACTIVE') then return 'ACTIVE' end
    if su:find('SUSPEND') then return 'SUSPENDED' end
    if su:find('DEAD') then return 'DEAD' end
  end

  ok, val = pcall(function() return merc.Status and merc.Status() end)
  if ok and val and tostring(val) ~= '' then
    local sl = tostring(val):lower()
    if sl:find('suspend') then return 'SUSPENDED' end
    if sl:find('active') then return 'ACTIVE' end
    if sl:find('dead') then return 'DEAD' end
  end

  return 'UNKNOWN'
end

-- Spawn scanning helpers ----------------------------------------------------
local function spawn_count_prefer_filter()
  local cnt = safe(function() return mq.TLO.SpawnCount('mercenary')() end)
  if not cnt or tonumber(cnt) == 0 then
    cnt = safe(function() return mq.TLO.SpawnCount()() end)
  end
  return tonumber(cnt) or 0
end

-- Action: suspend owner (local click or /dex remote)
-- Keep mq.delay here: it's safe when called from loop/worker thread
local function suspend_owner(ownerName)
  if not ownerName or ownerName == '' then return end
  local me = safe(function() return mq.TLO.Me.CleanName() end) or ''
  if normalize(ownerName) == normalize(me) then
    mq.cmd('/notify MMGW_ManageWnd MMGW_SuspendButton leftmouseup')
    mq.delay(60)
    printf('Clicked local suspend for %s', ownerName)
  else
    local on = tostring(ownerName):gsub('"','')
    mq.cmdf('/dex %s /notify MMGW_ManageWnd MMGW_SuspendButton leftmouseup', on)
    mq.delay(60)
    printf('Sent /dex suspend to %s', ownerName)
  end
end

-- helper: interpret spawn.State to determine active/suspended where possible
local function is_spawn_active(state)
  if not state or tostring(state) == '' then return nil end
  local su = tostring(state):upper()
  if su:find('SUSPEND') or su:find('SUSPENDED') or su:find('DEAD') then return false end
  if su:find('ACTIVE') or su:find('STAND') or su:find('FOLLOW') or su:find('SUMMON') or su:find('GUARD') then return true end
  return nil
end

-- Targeting helper for robust owner lookup (uses mq.delay, so only call from loop/worker)
local function wait_for_target_match(targetID, max_checks, delay_ms)
  max_checks = max_checks or 10
  delay_ms = delay_ms or 60
  for _ = 1, max_checks do
    mq.delay(delay_ms)
    local tID = safe(function() return mq.TLO.Target.ID() end)
    if tID and tonumber(tID) and tonumber(tID) == tonumber(targetID) then
      return true
    end
  end
  return false
end

-- Build merc spawn index with minimal targeting (patched to record owner names)
local function build_merc_spawn_index()
  local spawnIndex = { byOwner = {}, byClean = {}, ownerByClean = {} }
  local spawnCount = spawn_count_prefer_filter()
  if spawnCount == 0 then return spawnIndex end

  local prevTargetID = safe(function() return mq.TLO.Target.ID() end) or 0
  local needTargetIds = {}

  -- First pass: collect data exposed on the spawn (avoid targeting)
  for i = 1, spawnCount do
    local key = tostring(i) .. ', mercenary'
    local sp = safe(function() return mq.TLO.NearestSpawn(key) end)
    if not sp or not sp() then goto continue end

    local clean = safe(function() return sp.CleanName and sp.CleanName() end) or ''
    local owner = safe(function() return sp.Owner and sp.Owner() end) or ''
    local state = safe(function() return sp.State and sp.State() end) or ''
    local id = safe(function() return sp.ID and sp.ID() end) or 0

    local active = nil
    local stateUpper = tostring(state):upper()
    if stateUpper ~= '' then
      active = not (stateUpper:find('SUSPEND') or stateUpper:find('SUSPENDED') or stateUpper:find('DEAD'))
    else
      -- state blank: we can't be sure yet; we'll fallback to merc TLO if owner present
      if owner ~= '' then
        local status = merc_status_from_tlo_by_owner(owner) or 'UNKNOWN'
        active = tostring(status):upper():find('ACTIVE') and true or false
      end
    end

    local nclean = normalize(clean)
    local nowner = normalize(owner)
    if clean ~= '' then spawnIndex.byClean[nclean] = active end
    if owner ~= '' then spawnIndex.byOwner[nowner] = active end
    if clean ~= '' and owner ~= '' then spawnIndex.ownerByClean[nclean] = owner end

    -- only queue for targeting if Owner is empty and we have a valid ID
    if (not owner or owner == '') and tonumber(id) and tonumber(id) > 0 then
      table.insert(needTargetIds, tonumber(id))
    end

    ::continue::
  end

  -- Limit how many explicit target ops we do per scan to avoid spam
  local changedTarget = false
  local maxTargets = 8
  for idx = 1, math.min(#needTargetIds, maxTargets) do
    local id = needTargetIds[idx]
    mq.cmdf('/target id %d', id)
    changedTarget = true
    wait_for_target_match(id, 6, 40)

    local tOwner = safe(function() return mq.TLO.Target.Owner and mq.TLO.Target.Owner() end) or ''
    local tClean = safe(function() return mq.TLO.Target.CleanName and mq.TLO.Target.CleanName() end) or ''
    local tState = safe(function() return mq.TLO.Target.State and mq.TLO.Target.State() end) or ''

    local active = nil
    local tStateUpper = tostring(tState):upper()
    if tStateUpper ~= '' then
      active = not (tStateUpper:find('SUSPEND') or tStateUpper:find('SUSPENDED') or tStateUpper:find('DEAD'))
    else
      if tOwner ~= '' then
        local status = merc_status_from_tlo_by_owner(tOwner) or 'UNKNOWN'
        active = tostring(status):upper():find('ACTIVE') and true or false
      end
    end

    local ntClean = normalize(tClean)
    local ntOwner = normalize(tOwner)
    if tClean ~= '' then spawnIndex.byClean[ntClean] = active; spawnIndex.ownerByClean[ntClean] = tOwner end
    if tOwner ~= '' then spawnIndex.byOwner[ntOwner] = active end
    -- do not clear target here; we'll restore once after the loop
  end

  -- restore previous target once (only clear if we actually changed target)
  if prevTargetID and tonumber(prevTargetID) and tonumber(prevTargetID) > 0 then
    mq.cmdf('/target id %d', tonumber(prevTargetID))
  elseif changedTarget then
    mq.cmd('/target clear')
  end

  return spawnIndex
end

-- Worker that performs the pop (blocking operations) on the loop thread.
-- Accepts a pending table with fields targetID, owner, tType.
-- Patched to avoid clearing target when we didn't change it.
local function pop_target_merc_worker(pending)
  if not pending then return end
  local prevTargetID = safe(function() return mq.TLO.Target.ID() end) or 0
  local owner = pending.owner or ''
  local tType = pending.tType or ''
  local tID = pending.targetID or 0

  local changedTarget = false
  if tID and tonumber(tID) and tonumber(tID) > 0 then
    mq.cmdf('/target id %d', tonumber(tID))
    changedTarget = true
    wait_for_target_match(tID, 8, 60)
  end

  if tType == 'Mercenary' and (not owner or owner == '') then
    owner = safe(function() return mq.TLO.Target.Owner and mq.TLO.Target.Owner() end) or ''
  end

  if not owner or owner == '' then
    owner = safe(function() return mq.TLO.Target.CleanName and mq.TLO.Target.CleanName() end) or safe(function() return mq.TLO.Target.Name and mq.TLO.Target.Name() end) or ''
  end

  -- restore previous target (only clear if we changed it)
  if prevTargetID and tonumber(prevTargetID) and tonumber(prevTargetID) > 0 then
    mq.cmdf('/target id %d', tonumber(prevTargetID))
  elseif changedTarget then
    mq.cmd('/target clear')
  end

  if not owner or owner == '' then
    output('Could not determine owner to pop from target.')
    return
  end

  suspend_owner(owner)
end

-- Replace this function in your init.lua to batch targeting and stop 'Target cleared' spam
-- Patched version restores previous target only when appropriate
local function scan_and_suspend_saved_owners()
  local saved = collect_saved_members()
  if not saved or next(saved) == nil then
    output('No members saved in groups.ini to check.')
    return
  end

  local spawnCount = spawn_count_prefer_filter()
  if spawnCount == 0 then
    output('No mercenary spawns found in zone.')
    return
  end

  -- Collect spawn entries first (avoid targeting during collection)
  local entries = {}       -- array of { id=number, clean=str, owner=str, state=str }
  local needTargetIds = {} -- list of spawn ids with empty owner
  for i = 1, spawnCount do
    local key = tostring(i) .. ', mercenary'
    local sp = safe(function() return mq.TLO.NearestSpawn(key) end)
    if not sp or not sp() then goto continue end

    local id = safe(function() return sp.ID and sp.ID() end) or 0
    local clean = safe(function() return sp.CleanName and sp.CleanName() end) or ''
    local owner = safe(function() return sp.Owner and sp.Owner() end) or ''
    local state = safe(function() return sp.State and sp.State() end) or ''

    table.insert(entries, { id = tonumber(id) or 0, clean = clean, owner = owner, state = state })

    if (not owner or owner == '') and tonumber(id) and tonumber(id) > 0 then
      table.insert(needTargetIds, tonumber(id))
    end

    ::continue::
  end

  -- Batch-target a limited number of spawns to refresh owner info (reduce /target spam)
  local prevTargetID = safe(function() return mq.TLO.Target.ID() end) or 0
  local changedTarget = false
  local maxTargets = 8 -- reduce this to 0 to avoid targeting entirely
  for idx = 1, math.min(#needTargetIds, maxTargets) do
    local id = needTargetIds[idx]
    mq.cmdf('/target id %d', id)
    changedTarget = true
    wait_for_target_match(id, 6, 40)

    local tOwner = safe(function() return mq.TLO.Target.Owner and mq.TLO.Target.Owner() end) or ''
    local tClean = safe(function() return mq.TLO.Target.CleanName and mq.TLO.Target.CleanName() end) or ''
    local tState = safe(function() return mq.TLO.Target.State and mq.TLO.Target.State() end) or ''

    for _, e in ipairs(entries) do
      if e.id == id then
        if tOwner ~= '' then e.owner = tOwner end
        if tClean ~= '' then e.clean = tClean end
        if tState ~= '' then e.state = tState end
        break
      end
    end
  end

  -- restore previous target once (do not clear if we didn't change target)
  if prevTargetID and tonumber(prevTargetID) and tonumber(prevTargetID) > 0 then
    mq.cmdf('/target id %d', tonumber(prevTargetID))
  elseif changedTarget then
    mq.cmd('/target clear')
  end

  -- Now process entries exactly as before (determine active status, match saved members, and suspend)
  local acted = {}
  for _, e in ipairs(entries) do
    local clean = e.clean or ''
    local ownerFromSpawn = e.owner or ''
    local id = e.id or 0
    local state = e.state or ''

    -- determine active using spawn.State first
    local activeFromState = is_spawn_active(state)
    local isActive = nil
    if activeFromState == true then
      isActive = true
    elseif activeFromState == false then
      isActive = false
    else
      if ownerFromSpawn and ownerFromSpawn ~= '' then
        local status = merc_status_from_tlo_by_owner(ownerFromSpawn) or 'UNKNOWN'
        local up = tostring(status):upper()
        if up:find('ACTIVE') then isActive = true
        elseif up:find('SUSPEND') or up:find('DEAD') then isActive = false
        else isActive = nil end
      end
    end

    -- match saved membership by owner OR CleanName
    local normOwner = normalize(ownerFromSpawn)
    local normClean = normalize(clean)
    local matchedSaved = false
    local dedupeKey = nil
    local actionOwnerName = ownerFromSpawn

    if normOwner ~= '' and saved[normOwner] then
      matchedSaved = true
      dedupeKey = 'owner:' .. normOwner
    end

    if not matchedSaved and normClean ~= '' and saved[normClean] then
      matchedSaved = true
      dedupeKey = 'clean:' .. normClean
    end

    if matchedSaved and dedupeKey and not acted[dedupeKey] then
      -- ensure ownerName is present to /dex; if missing, skip
      if (not actionOwnerName or actionOwnerName == '') then
        printf('Matched saved entry by CleanName "%s" but owner unknown; skipping suspend for merc "%s"', clean, clean)
        acted[dedupeKey] = true
      else
        if isActive == nil then
          printf('Could not determine active status for %s (owner=%s, merc=%s); skipping', dedupeKey, tostring(actionOwnerName), tostring(clean))
          acted[dedupeKey] = true
        else
          if isActive then
            printf('Matched saved owner/clean "%s": suspending owner %s for merc %s', tostring(saved[normOwner] or saved[normClean] or dedupeKey), actionOwnerName, clean)
            suspend_owner(actionOwnerName)
          else
            printf('Matched saved owner/clean "%s" but merc %s is not active (state="%s"); skipping', tostring(saved[normOwner] or saved[normClean] or dedupeKey), clean, tostring(state))
          end
          acted[dedupeKey] = true
        end
      end
    end
  end

  if next(acted) == nil then
    output('No matching saved owners with ACTIVE mercs were found to suspend.')
  else
    local list = {}
    for k,_ in pairs(acted) do table.insert(list, tostring(k)) end
    output('\ayProcessed matches: \ag' .. table.concat(list, ', '))
  end
end

-- Returns (present:boolean, owner:string or nil)
local function get_member_presence_info(member, mercIndex)
  if not member or member == '' then return false, nil end
  -- If player's PC spawn exists, treat as present; owner not applicable
  local pcSpawn = safe(function() return mq.TLO.Spawn(string.format('pc "%s"', member)) end)
  if pcSpawn and pcSpawn() then
    return true, nil
  end
  mercIndex = mercIndex or { byOwner = {}, byClean = {}, ownerByClean = {} }
  local n = normalize(member)
  -- match by owner first
  if mercIndex.byOwner[n] == true then
    -- member is the owner name; show nil owner (they are the player)
    return true, nil
  end
  -- match by clean (merc name)
  if mercIndex.byClean[n] == true then
    local owner = mercIndex.ownerByClean and (mercIndex.ownerByClean[n] or nil) or nil
    return true, owner
  end
  return false, nil
end

-- Notification helpers
local function push_notification(msg, color)
  color = color or {0.9, 0.9, 0.9, 1}
  table.insert(recent_notifications, 1, { msg = msg, ts = os.time(), color = color })
  while #recent_notifications > NOTIFY_MAX do table.remove(recent_notifications) end
  output(msg)
end

-- Periodic presence check; called from loop (yieldable)
local function check_all_presence_and_notify()
  -- detect external INI changes (performed once per tick via this call)
  local ok, ini_raw = pcall(function() return mq.TLO.Ini(args[1])() end)
  ini_raw = (ok and ini_raw) and tostring(ini_raw) or ''
  if ini_raw ~= last_ini_raw then
    -- INI changed externally — reload settings and notify
    load_settings()
    push_notification(('Detected external change to %s — reloaded.'):format(args[1]), {1,1,0,1})
  end

  local mercIndex = build_merc_spawn_index()
  local members = collect_saved_members()
  for _, member in pairs(members) do
    local n = normalize(member)
    local present, owner = get_member_presence_info(member, mercIndex)
    local prev = presence_state[n]
    if prev == nil then
      -- initial population: record but do not notify
      presence_state[n] = present
      presence_owner[n] = owner
    else
      if prev ~= present or (owner ~= presence_owner[n]) then
        presence_state[n] = present
        presence_owner[n] = owner
        if present then
          if owner and owner ~= '' then
            push_notification(string.format('%s is now ONLINE (owner: %s)', member, owner), {0.2,1.0,0.2,1})
          else
            push_notification(string.format('%s is now ONLINE', member), {0.2,1.0,0.2,1})
          end
        else
          push_notification(string.format('%s is now OFFLINE', member), {0.6,0.6,0.6,1})
        end
      end
    end
  end
end

-- Help display function (bound to /groups help and /g help)
local function show_groups_help()
  output('Groups commands:')
  output('  /groups help (or /g help)           - Show this help')
  output('  /groups <name> save                 - Save current group as <YourCleanName>_<name>')
  output('  /groups <YourCleanName>_<name> delete - Delete the saved group with that exact section name')
  output('  /groups <YourCleanName>_<name>      - Form the saved group (must pass the exact saved section name)')
  output('  /groups_reload                       - Reload settings from INI')
  output('  /suspendmercs                        - Scan and suspend ACTIVE mercs for saved members')
  output('UI: Use the Groups UI to save/delete groups.')
  output('UI: Double-click members to target.')
  push_notification('Displayed Groups help in chat.', {0.2,1.0,0.2,1})
end

-- UI: groups command & save/delete ----------------------------------------
local function groups_cmd(name, action)
  if not name or name == '' then return end

  -- Normalize name input to string
  name = tostring(name)

  -- handle help requests (so "/groups help" works reliably)
  local lname = tostring(name):lower()
  if lname == 'help' or lname == '-h' or lname == '--help' then
    show_groups_help()
    return
  end
  if action and tostring(action):lower() == 'help' then
    show_groups_help()
    return
  end

  if action == 'save' then
    -- Ensure saved section is prefixed with player's CleanName_
    local me = safe(function() return mq.TLO.Me and mq.TLO.Me.CleanName() end) or ''
    local candidate = name

    if me ~= '' then
      -- If user passed a name that already starts with "Me_" or "Me", don't double-prefix.
      if not (candidate:sub(1, #me + 1) == (me .. '_') or candidate:sub(1, #me) == me) then
        candidate = me .. '_' .. candidate
      end
    end

    settings[candidate] = {}
    local members_count = safe(function() return mq.TLO.Group.Members() end) or 0
    for i = 0, members_count do
      local member = safe(function() return mq.TLO.Group.Member(i) end)
      if member and member() then
        local okName, nameVal = pcall(function()
          if member.CleanName then return member.CleanName() end
          if member.Name then return member.Name() end
          return nil
        end)
        if okName and nameVal and nameVal ~= '' then
          settings[candidate]['Member'..i] = nameVal
          settings[candidate]['Roles'..i] = get_member_roles_string(member)
        end
      end
    end
    save_settings()
    refresh_sections_from_ini()
    output('\ayMade group \"'..candidate..'\"...\ax')
  elseif action == 'delete' then
    settings[name] = nil
    save_settings()
    refresh_sections_from_ini()
    output('\ayDeleted group \"'..name..'\"...\ax')
  else
    if settings[name] ~= nil then
      local count = 0
      for i = 1, MAX_GROUP_SLOTS - 1 do
        local member = settings[name]['Member' .. i]
        if member ~= nil and member ~= '' then mq.cmdf('/invite %s', member); count = count + 1 end
      end
      repeat mq.delay(10) until (safe(function() return mq.TLO.Group.Members() end) or 0) == count
      for i = 0, MAX_GROUP_SLOTS - 1 do
        local roles = settings[name]['Roles' .. i]
        if roles ~= nil then
          roles = split(roles, ',')
          local member = settings[name]['Member' .. i]
          for _, v in pairs(roles) do
            mq.cmdf('/grouproles set %s %s', member, Roles[v])
            mq.delay(10)
          end
        end
      end
    else
      output('\arGroup \at\"'..name..'\" \ardoes not exist... \aytry again.')
      push_notification(('Group: %s does not exist...'):format(name), {1,0,0,1})
    end
  end
end

local function findspawn(member)
  if not member or member == '' then return 0 end
  local myMerc = safe(function() return mq.TLO.Spawn(string.format('mercenary \"%s\"', member)) end)
  if myMerc and myMerc() and safe(function() return myMerc.CleanName and myMerc.CleanName() end) == member then
    return safe(function() return myMerc.ID and myMerc.ID() end) or 0
  end
  local myPC = safe(function() return mq.TLO.Spawn(string.format('pc \"%s\"', member)) end)
  if myPC and myPC() and safe(function() return myPC.CleanName and myPC.CleanName() end) == member then
    return safe(function() return myPC.ID and myPC.ID() end) or 0
  end
  return 0
end

local function textEnabled(member)
  ImGui.PushStyleColor(ImGuiCol.Text, 0.690, 0.553, 0.259, 1)
  ImGui.PushStyleColor(ImGuiCol.HeaderHovered, 0.33, 0.33, 0.33, 0.5)
  ImGui.PushStyleColor(ImGuiCol.HeaderActive, 0.0, 0.66, 0.33, 0.5)
  local label = format_member_label(member)
  local selSpawn = ImGui.Selectable(label, false, ImGuiSelectableFlags.AllowDoubleClick)
  ImGui.PopStyleColor(3)
  if selSpawn and ImGui.IsMouseDoubleClicked(0) then
    local id = findspawn(member)
    if id and id > 0 then mq.cmdf('/tar id %s', id); printf('\ayTarget \ag%s',member) end
  end
end

-- ImGui main ---------------------------------------------------------------
local function main()
  openGUI, shouldDrawGUI = ImGui.Begin('Groups by Cannonballdex', openGUI)

  -- replace the existing notification drawing block with this wrapped version
  if #recent_notifications > 0 then
    if ImGui.CollapsingHeader('Notifications##groups_notifications') then
      for i = 1, math.min(#recent_notifications, NOTIFY_MAX) do
        local n = recent_notifications[i]
        ImGui.PushStyleColor(ImGuiCol.Text, n.color[1], n.color[2], n.color[3], n.color[4] or 1)

        -- Build the message once
        local msg = string.format('[%s] %s', os.date('%H:%M:%S', n.ts), n.msg)

        -- Determine available width in the content region and set wrap pos accordingly.
        local avail_w = ImGui.GetContentRegionAvail()
        ImGui.PushTextWrapPos(ImGui.GetCursorPosX() + (avail_w or 200))

        -- Use TextWrapped so text will wrap to the set wrap position / available region.
        ImGui.TextWrapped(msg)

        ImGui.PopTextWrapPos()
        ImGui.PopStyleColor()
      end

      if ImGui.SmallButton('Clear Notifications##groups_clear') then recent_notifications = {} end
      ImGui.Separator()
    end
  end

  ImGui.Spacing()
  
  -- Save handler: prepend CleanName_ invisibly when issuing the save command
  if ImGui.Button(string.format('%s Add Group', ICONS.FA_USER_PLUS)) then
    local suffix = tostring(SaveGroup or '')
    if suffix == '' then
      push_notification('Please enter a group label.', {1,0.2,0.2,1})
    else
      local me = safe(function() return mq.TLO.Me and mq.TLO.Me.CleanName() end) or ''
      local candidate = suffix

      -- If user typed a name that already begins with their CleanName or CleanName_ don't double-prefix
      if me ~= '' and (candidate:sub(1, #me + 1) == (me .. '_') or candidate:sub(1, #me) == me) then
        candidate = candidate
      else
        if me ~= '' then candidate = me .. '_' .. candidate end
      end

      mq.cmdf('/groups %s save', quote_name(candidate))
      push_notification(('Saved group: %s'):format(candidate), {0,1,0,1})
      refresh_sections_from_ini()
      -- clear the visible input (so the user types a new suffix next time)
      SaveGroup = ''
    end
  end
  ImGui.SameLine()
  ImGui.SetCursorPosX(110)
  ImGui.SetNextItemWidth(165)

  -- Visible input: only the suffix. We add CleanName_ invisibly when saving.
  SaveGroup, _ = ImGui.InputText('##SaveGroup', SaveGroup or '')
  HelpMarker('Save Group (the player CleanName_ prefix is added automatically).')
  ImGui.Spacing()

  if ImGui.Button(string.format(ICONS.FA_USERS)) then mq.cmd('/dgae /notify GroupWindow GW_DisbandButton leftmouseup') end
  HelpMarker('Disband All Groups')

  ImGui.SameLine()
  if ImGui.Button(string.format(ICONS.FA_USER_TIMES)) then mq.cmdf('/dex %s /notify MMGW_ManageWnd MMGW_SuspendButton leftmouseup', safe(function() return mq.TLO.Target.Owner and mq.TLO.Target.Owner() end) or '') end
  HelpMarker('Target Merc Sends Suspend Command to Owner')

  ImGui.SameLine()
  -- UI: set a pending_pop request; do not perform blocking waits here
  if ImGui.Button(string.format(ICONS.FA_SHIELD)) then
    local tID = safe(function() return mq.TLO.Target.ID() end) or 0
    local owner = safe(function() return mq.TLO.Target.Owner and mq.TLO.Target.Owner() end) or ''
    local tType = safe(function() return mq.TLO.Target.Type and mq.TLO.Target.Type() end) or ''
    pending_pop = { targetID = tonumber(tID) or 0, owner = owner, tType = tType }
  end
  HelpMarker('Target Player Sends Command to Un-Suspend Their Merc')

  ImGui.SameLine()
  if ImGui.Button(string.format(ICONS.MD_SECURITY)) then
    pending_scan = true
    pending_scan_suspend = true
  end
  HelpMarker('Suspend All Groups Mercs in Zone')

  ImGui.SameLine()
  if ImGui.Button(string.format(ICONS.MD_DONE)) then mq.cmd('/lua stop groups') end
  HelpMarker('Stop Groups')

  ImGui.SameLine()
  if ImGui.Button(string.format(ICONS.MD_DONE_ALL)) then mq.cmd('/dgae /lua stop groups') end
  HelpMarker('Stop Groups On All Toons')

  -- show target merc info if applicable
  if safe(function() return mq.TLO.Target and mq.TLO.Target() end) and safe(function() return mq.TLO.Target.Type and mq.TLO.Target.Type() end) == 'Mercenary' then
    ImGui.Text(string.format('Merc: %s', safe(function() return mq.TLO.Target.CleanName and mq.TLO.Target.CleanName() end) or '<none>'))
    ImGui.SameLine()
    ImGui.Text(string.format('Owner: %s', safe(function() return mq.TLO.Target.Owner and mq.TLO.Target.Owner() end) or '<none>'))
    ImGui.Separator()
  end

  ImGui.Text('Existing Groups')
  ImGui.Separator()

  if shouldDrawGUI then
    -- Group sections by leader clean name
    local leader_map = {}   -- leader -> list of groupNames (preserve order found in sections)
    local leader_order = {} -- array of leader names to preserve ordering

    for _, groupName in ipairs(sections or {}) do
      local group = settings[groupName]
      if group then
        local leader = get_group_leader(groupName, group) or ''
        if leader == '' then leader = '<Unknown>' end
        if not leader_map[leader] then
          leader_map[leader] = {}
          table.insert(leader_order, leader)
        end
        table.insert(leader_map[leader], groupName)
      end
    end

    if ImGui.BeginTabBar('Groups_Leaders_TabBar') then
      -- iterate leaders in discovered order for predictability
      for _, leader in ipairs(leader_order) do
        local groupList = leader_map[leader] or {}
        if ImGui.BeginTabItem(leader) then
          -- Within a leader tab, list that leader's saved groups
          for gi, groupName in ipairs(groupList) do
            local group = settings[groupName]
            if group ~= nil then
              ImGui.PushID(string.format('group_%s', groupName))

              ImGui.Separator()

              -- Use the full canonical saved section name (including CleanName_) as the button text
              local displayName = groupName

              local leaderName = get_group_leader(groupName, group)
              local iAmLeader = (safe(function() return mq.TLO.Me.CleanName() end) or '') == leaderName

              if iAmLeader then
                if ImGui.Button(displayName) then 
                  mq.cmdf('/groups %s', quote_name(groupName))
                  push_notification(('Queued join for online members of "%s"'):format(groupName), {0.8,0.4,0,1})
                end
                ImGui.SameLine()
                HelpMarker(('Form Group saved as: %s'):format(groupName))
              else
                if ImGui.Button(displayName) then
                  if leaderName ~= '' then
                    local leaderQuoted = quote_name(leaderName)
                    local groupQuoted = quote_name(groupName)
                    mq.cmdf('/dex %s /groups %s', leaderQuoted, groupQuoted)
                    mq.cmdf('/dex %s /dgtell all Loading Group', leaderQuoted)
                    mq.cmdf('/dex %s /lua run groups', leaderQuoted)
                    push_notification(('Sent /groups command to leader %s to form group "%s"'):format(leaderName, groupName), {0.8,0.4,0,1})
                  else
                    output('Could not determine leader for group "' .. tostring(groupName) .. '"')
                  end
                end
                ImGui.SameLine()
                HelpMarker(('Send Command To Leader to form Group (saved as: %s)'):format(groupName))
              end

              ImGui.SameLine()
              if ImGui.Button(string.format('%s Disband', ICONS.FA_USER_TIMES)) then
                local membersToDisband = {}
                for mi = 0, MAX_GROUP_SLOTS - 1 do
                  local m = group['Member' .. mi]
                  if m and m ~= '' then table.insert(membersToDisband, m) end
                end
                if #membersToDisband > 0 then
                  pending_disband = { groupName = groupName, members = membersToDisband }
                  push_notification(('Queued disband for %d members of "%s"'):format(#membersToDisband, groupName), {0.8,0.4,0,1})
                else
                  push_notification(('No saved members to disband for group "%s"'):format(groupName), {1,1,0,1})
                end
              end
              HelpMarker('Queue /dex <member> /disband to each saved group member')

              -- Delete group button (next to Disband)
              ImGui.SameLine()
              local delete_icon = ICONS.FA_TRASH or ICONS.FA_USER_TIMES
              if ImGui.Button(string.format('%s Delete', delete_icon)) then
                mq.cmdf('/groups %s delete', quote_name(groupName))
                push_notification(('Deleted group: %s'):format(groupName), {1,0,0,1})
                refresh_sections_from_ini()
              end
              HelpMarker('Delete this saved group from Groups.ini')

              -- Members and roles (show presence)
              for i = 0, MAX_GROUP_SLOTS - 1 do
                local member = group['Member' .. i]
                local roles = group['Roles' .. i]
                if member ~= nil and member ~= '' then
                  ImGui.PushID(string.format('member_%d_%s', i, member))

                  local n = normalize(member)
                  local present = presence_state[n]
                  local ownerName = presence_owner[n]
                  if present == true then
                    ImGui.TextColored(0.2, 1.0, 0.2, 1.0, 'Online')
                    if ownerName and ownerName ~= '' then
                      ImGui.SameLine()
                      ImGui.Text(string.format('Owner: %s', ownerName))
                    end
                  else
                    ImGui.TextColored(0.6, 0.6, 0.6, 1.0, 'Offline')
                  end

                  ImGui.SameLine()
                  ImGui.Text(string.format('Group Member %d: ', i+1))
                  ImGui.SameLine()
                  textEnabled(member)
                  HelpMarker('Double Click to Target')

                  ImGui.PopID()
                end
                if roles ~= nil then
                  ImGui.TextColored(0,1,0,1,'Roles %s: "%s"',ICONS.MD_ARROW_UPWARD, roles)
                end
              end

              ImGui.PopID() -- pop group id
            end
          end

          ImGui.EndTabItem()
        end
      end

      ImGui.EndTabBar()
    end
  end

  ImGui.End()
end

-- Setup & loop --------------------------------------------------------------
local function setup()
  mq.bind('/groups_reload', function()
    load_settings()
    push_notification(('Reloaded %s (manual).'):format(SETTINGS_FILE), {0.2,1,0.2,1})
  end)
  -- bind help commands
  mq.bind('/groups help', show_groups_help)
  -- command bindings
  mq.bind('/groups', groups_cmd)
  mq.bind('/suspendmercs', function() pending_scan = true; pending_scan_suspend = true end)
  load_settings()
  output('\atGroups - Loaded ' .. SETTINGS_FILE)
  output('\aoUsage: \at/groups help \ao(for commands).')
end

local function loop()
  local tick = 0
  while openGUI do
    -- process pending pop request (performed on loop thread so mq.delay/wait are allowed)
    if pending_pop then
      local ok, err = pcall(function()
        pop_target_merc_worker(pending_pop)
      end)
      if not ok then print('Error during pop worker: ' .. tostring(err)) end
      pending_pop = nil
    end

    -- process pending_disband (performed on loop thread so mq.delay/wait are allowed)
    if pending_disband then
      local ok, err = pcall(function()
        local g = pending_disband
        for _, m in ipairs(g.members) do
          local mqname = quote_name(m)
          mq.cmdf('/dex %s /disband', mqname)
          mq.delay(60) -- small delay to avoid flooding remote with commands
        end
        output(('Sent /disband to %d saved members of group "%s"'):format(#g.members, g.groupName))
      end)
      if not ok then print('Error processing pending_disband: ' .. tostring(err)) end
      pending_disband = nil
    end

    -- presence check once per second (loop delays 100ms)
    tick = tick + 1
    if tick >= 10 then
      tick = 0
      local ok, err = pcall(function() check_all_presence_and_notify() end)
      if not ok then print('Error during presence check: ' .. tostring(err)) end
    end

    if pending_scan then
      local do_suspend = pending_scan_suspend
      pending_scan = false
      pending_scan_suspend = false
      local ok, err = pcall(function()
        if do_suspend then
          scan_and_suspend_saved_owners()
        else
          output('Scan requested (no suspend) -- no action implemented.')
        end
      end)
      if not ok then print('Error during merc scan: ' .. tostring(err)) end
    end

    mq.delay(100)
  end
end

-- Init ----------------------------------------------------------------------
mq.imgui.init('groups', main)
setup()
loop()
