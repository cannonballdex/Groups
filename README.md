# Groups

Groups is a MacroQuest (mq) Lua/ImGui utility for saving, forming, managing and monitoring player groups and mercenaries in-game. This file (`init.lua`) is implemented and maintained by cannonballdex and provides an ImGui UI plus several MQ command bindings to work with saved groups persisted to an INI file.

This README is derived from the behavior and bindings implemented in `init.lua` (see source).

## Key features
- ImGui-based UI to view saved groups, save current group, form a saved group, queue remote disband, and delete saved groups.
- Persists saved groups to disk (canonical file: `Groups.ini` in `mq.configDir`) using lib.LIP.
- Save auto-prefix: saving with a suffix (e.g. `raid`) will automatically be saved as `<YourCleanName>_raid` if not already prefixed.
- Groups are shown in the UI organized into tabs labeled by each leader's CleanName (leader -> list of saved groups).
- Buttons display the full canonical INI section name (including the CleanName_ prefix) so actions operate on the exact saved section.
- Presence tracking: detects saved members coming online/offline and shows owner info for mercenaries where available; colored, wrapped notification panel in UI.
- Merc management: scan to suspend active mercs for saved owners (sends `/dex` + in-game Manage Window notifications), and UI support to pop (unsuspend) a merc via target + action.
- Non-blocking: long-running/blocked operations (targeting, suspend/pop, disband) are queued and executed by the worker loop to avoid UI blocking.
- Safe access: many mq/TLO calls are wrapped with pcall via a `safe()` helper to reduce runtime errors.

## Requirements
- MacroQuest (mq) with Lua support
- ImGui bindings available to Lua (mq.imgui)
- mq.Icons (icon constants used in the UI)
- lib/LIP.lua available for INI serialization/deserialization (the script requires `lib.LIP`)

## Installation
1. Copy `groups.lua` (or `init.lua` from this repo) and `LIP.lua` into a folder under your MacroQuest `lua` directory (for example `lua/groups`).
2. From inside the game or MQ console, run:
   ```
   /lua run groups
   ```
   The script initializes the ImGui window and worker loop automatically.
3. To stop on the current toon:
   ```
   /lua stop groups
   ```
   To stop across all toons:
   ```
   /dgae /lua stop groups
   ```

## Configuration / INI file
- Canonical settings filename: `Groups.ini` stored in your MQ config directory (value of `mq.configDir`).
- On first run, if `Groups.ini` doesn't exist but a legacy `Crew.ini` exists in the config dir, the script will copy the legacy file to `Groups.ini` (migration).
- The INI stores saved group sections (section name is canonical key, e.g. `Cannonball_raid`) and MemberN / RolesN entries.

## Commands (as implemented)
The script binds MQ commands in `init.lua`. Use lowercase commands shown below (they match the file's bindings):

- `/groups <name> [save|delete]`
  - Primary command. When `save` is passed, the current group is saved under the given name (the script prefixes your CleanName if necessary).
  - Examples:
    - `/groups raid save` → saved as `YourCleanName_raid`
    - `/groups YourCleanName_raid` → form that saved group (must provide the canonical saved section name)

- `/groups help`
  - Prints help text to chat describing the available commands.

- `/groups_reload`
  - Manually reload the INI / settings from disk.

- `/suspendmercs`
  - Queues the scan that will attempt to suspend ACTIVE mercenaries belonging to saved owners in zone (same action used by the UI Suspend button).

Notes:
- The UI provides many convenience buttons which call these same operations (Save, Delete, Disband, Suspend, Pop).
- Forming or deleting a group expects the exact saved section name (the UI shows the canonical names). Saving supports the suffix form and will add your CleanName_ prefix automatically.

## UI behaviors & controls
- Notification panel: shows timestamped, colorized, wrapped messages. Clear button provided.
- Left controls: inputs and buttons to Add Group (suffix input) and Delete Group (exact name), plus action buttons: Disband All, Suspend/Pop, Stop script.
- Main area: tabs per leader CleanName. Inside each tab the leader's saved groups are listed. For each group you can:
  - Form (locally if you are leader) or send remote /dex to leader to form.
  - Queue disband for saved members (sends `/dex <member> /disband` to each saved member).
  - Delete saved group (removes from INI).
  - See saved members with presence (Online/Offline) and owner info (for mercs).
  - Double-click a member to target their spawn (PC or merc).

## Merc and targeting behavior
- The script builds a merc spawn index to detect merc active/suspended states and owner names. To resolve missing owner info it may target a limited number of merc spawns.
- The scan targeting is rate-limited: the script limits explicit `/target id <id>` calls per scan (default maxTargets = 8) to reduce target spam.
- Suspend/pop actions are performed by simulating Manage Window clicks (via `/notify`) and by using `/dex <owner>` for remote operations.

## Safety & side effects
- The plugin issues in-game commands and simulates UI clicks (e.g. `/notify`, `/dex`, `/target`, `/dgae`). This can produce chat and target noise.
- The script uses defensive coding (pcall wrappers) to avoid crashes if TLO properties are absent.
- Throttles and limits exist to reduce spam, but be aware of the potential for noisy effects when performing scans or issuing remote commands.

## Troubleshooting
- If the ImGui window doesn't appear ensure `mq.imgui` is available and working in your MacroQuest setup.
- If you see errors related to `lib.LIP`, confirm `LIP.lua` is present in `lua/lib/LIP.lua` or adjust require paths.
- If the script appears unresponsive, stop it with `/lua stop groups` and check MQ logs or the console for messages.

## Files of interest
- `init.lua` (this script) — UI, worker loop, settings load/save, merc scanning, commands.
- `lib/LIP.lua` — INI load/save helper used for settings persistence (required).

## License & attribution
- The LIP INI parser contains contributions and attributions (see `LIP.lua` for license header).
- This implementation and rebranding are by cannonballdex and are derived from earlier MakeCrew/Crew code. See the top of `init.lua` for in-file attribution and change notes.
