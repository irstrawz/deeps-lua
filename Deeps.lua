--[[
* Deeps (Lua) - a damage meter for Ashita v4
*
* A pure-Lua replacement for the Deeps C++ plugin, which cannot load on
* Ashita 4.3 (it targets interface 4.16 and is missing the expDestroyPlugin
* export). Being an addon rather than a plugin, this one has no compiled
* component and so cannot break on an interface version bump.
*
* Reads the 0x28 action packet and attributes damage to party and alliance
* members.
*
* Commands:
*   /dps            - toggle the window
*   /dps reset      - clear all data
*   /dps party      - toggle party-only vs whole alliance
*   /dps idle <sec> - seconds of inactivity before data auto-clears (0 = never)
*   /dps width <px> - window width
*   /dps debug      - log every parsed action to chat
*   /dps help       - list commands
--]]

addon.name    = 'Deeps';
addon.author  = 'Lua damage meter for Ashita v4';
addon.version = '1.3.0';
addon.desc    = 'Damage meters for yourself, your party and your alliance.';

require('common');
local chat     = require('chat');
local imgui    = require('imgui');
local settings = require('settings');

----------------------------------------------------------------------
-- Configuration
----------------------------------------------------------------------
local defaults = T{
    showWindow   = T{ true },
    partyOnly    = T{ true },
    showAccuracy = T{ true },
    idleSeconds  = T{ 180 },
    windowWidth  = T{ 395 },
};

local config = settings.load(defaults);

-- A gap longer than this between two of a player's actions counts as
-- downtime rather than combat, and is left out of their DPS clock.
local ACTIVE_GAP = 10;

----------------------------------------------------------------------
-- Jobs
----------------------------------------------------------------------
-- Every pair is at least 0.216 apart in RGB distance, checked across all
-- 231 combinations, so no two jobs read as the same colour on a bar.
--
-- BLM is as close to black as is usable: the window background is dark, so
-- a true black bar would make the fill length impossible to judge. It is
-- still comfortably the darkest, with DRK lifted just clear of it.
local JOBS = {
    [1]  = { 'WAR', { 0.82, 0.16, 0.16 } },  -- red
    [2]  = { 'MNK', { 0.93, 0.55, 0.13 } },  -- orange
    [3]  = { 'WHM', { 0.96, 0.96, 0.93 } },  -- white
    [4]  = { 'BLM', { 0.24, 0.22, 0.30 } },  -- near-black
    [5]  = { 'RDM', { 0.95, 0.45, 0.55 } },  -- rose
    [6]  = { 'THF', { 0.65, 0.87, 0.25 } },  -- lime
    [7]  = { 'PLD', { 0.42, 0.72, 0.96 } },  -- sky blue
    [8]  = { 'DRK', { 0.60, 0.10, 0.22 } },  -- dark red
    [9]  = { 'BST', { 0.55, 0.36, 0.16 } },  -- brown
    [10] = { 'BRD', { 0.15, 0.72, 0.68 } },  -- teal
    [11] = { 'RNG', { 0.18, 0.60, 0.25 } },  -- green
    [12] = { 'SAM', { 0.90, 0.42, 0.30 } },  -- coral
    [13] = { 'NIN', { 0.22, 0.28, 0.62 } },  -- navy
    [14] = { 'DRG', { 0.72, 0.60, 0.95 } },  -- light purple
    [15] = { 'SMN', { 0.25, 0.88, 0.82 } },  -- aqua
    [16] = { 'BLU', { 0.25, 0.45, 0.90 } },  -- blue
    [17] = { 'COR', { 0.90, 0.78, 0.25 } },  -- gold
    [18] = { 'PUP', { 0.78, 0.68, 0.50 } },  -- tan
    [19] = { 'DNC', { 0.88, 0.30, 0.80 } },  -- magenta
    [20] = { 'SCH', { 0.55, 0.80, 0.60 } },  -- pale green
    [21] = { 'GEO', { 0.60, 0.62, 0.25 } },  -- olive
    [22] = { 'RUN', { 0.58, 0.30, 0.85 } },  -- violet
};

----------------------------------------------------------------------
-- Action packet layout.
--
-- Bit offsets from the start of the packet, header included.
--
--   bit  40   actor id                     (32)
--   bit  72   target count                 (10)
--   bit  82   category                     (4)
--   bit  86   param                        (10)
--   bit  96   unknown                      (10)
--   bit 106   recast                       (32)
--   bit 150   first target block
--
-- Each target block:
--   id (32), action count (4), then per action:
--     reaction (5), animation (12), effect (4), stagger (6),
--     param (17), message (10), unknown (31),
--     has additional effect (1)
--       -> animation (10), param (17), message (10)
--     has spike effect (1)
--       -> animation (10), param (14), message (10)
----------------------------------------------------------------------
local TARGET_START = 150;

-- Categories that resolve into damage. 7 and 8 are the "readies" and
-- "starts casting" announcements and carry an ability id in param, not a
-- damage figure, so they are deliberately absent.
local CATEGORY = {
    [1] = 'Melee',
    [2] = 'Ranged',
    [3] = 'Weaponskill',
    [4] = 'Magic',
    [6] = 'Ability',
};

-- Magic is the one category where param routinely is not damage. An
-- enfeeble or a debuff song lands on the enemy, so the target check cannot
-- filter it, and param carries the status effect id instead. A BRD casting
-- Elegy produced "msg=85 param=192", which was being counted as 192 damage.
--
-- So category 4 requires an explicit damage message. Anything not listed
-- here is treated as a status effect and ignored; /dps debug names the
-- message id, so a nuke that goes uncounted is easy to spot and add.
--   2   spell damage
--   252 magic burst damage
local MAGIC_DAMAGE = {
    [2] = true, [252] = true,
};

-- Pets additionally use the monster ability categories for blood pacts,
-- ready moves and automaton attacks. Safe to accept only because the actor
-- has already been confirmed to be a party member's pet.
local PET_CATEGORY = {
    [1] = true, [2] = true, [3] = true, [4] = true,
    [6] = true, [11] = true, [13] = true,
};

----------------------------------------------------------------------
-- Bit reader
----------------------------------------------------------------------
local function readBits(data, offset, length)
    local value = 0;
    local scale = 1;
    for i = 0, length - 1 do
        local absolute = offset + i;
        local byte = string.byte(data, math.floor(absolute / 8) + 1);
        if (byte == nil) then
            return value;
        end
        if (math.floor(byte / (2 ^ (absolute % 8))) % 2 == 1) then
            value = value + scale;
        end
        scale = scale * 2;
    end
    return value;
end

local function take(cursor, length)
    local value = readBits(cursor.data, cursor.pos, length);
    cursor.pos = cursor.pos + length;
    return value;
end

local function parseAction(data)
    local limit  = #data * 8;
    local cursor = { data = data, pos = 40 };

    local actor       = take(cursor, 32);
    local targetCount = take(cursor, 10);
    local category    = take(cursor, 4);

    if (targetCount < 1 or targetCount > 16) then
        return nil;
    end

    cursor.pos = TARGET_START;

    local targets = {};
    for _ = 1, targetCount do
        if (cursor.pos + 36 > limit) then
            break;
        end

        local id          = take(cursor, 32);
        local actionCount = take(cursor, 4);
        if (actionCount < 1 or actionCount > 16) then
            break;
        end

        local actions = {};
        for _ = 1, actionCount do
            if (cursor.pos + 87 > limit) then
                break;
            end

            take(cursor, 5);                      -- reaction
            take(cursor, 12);                     -- animation
            take(cursor, 4);                      -- effect
            take(cursor, 6);                      -- stagger
            local param   = take(cursor, 17);
            local message = take(cursor, 10);
            take(cursor, 31);                     -- unknown

            local extra = 0;
            if (take(cursor, 1) == 1) then        -- additional effect
                take(cursor, 10);
                extra = take(cursor, 17);
                take(cursor, 10);
            end
            if (take(cursor, 1) == 1) then        -- spike effect
                take(cursor, 10);
                take(cursor, 14);
                take(cursor, 10);
            end

            actions[#actions + 1] = { param = param, message = message, extra = extra };
        end

        targets[#targets + 1] = { id = id, actions = actions };
    end

    return { actor = actor, category = category, targets = targets };
end

----------------------------------------------------------------------
-- Party lookup
--
-- Members 0-5 are your party, 6-17 the rest of the alliance. Used both to
-- attribute damage to a name and, just as importantly, to recognise when
-- the *target* is a member - that is how cures and buffs are kept out of
-- the damage totals without maintaining a table of message ids.
----------------------------------------------------------------------
local function memberLookup()
    local party  = AshitaCore:GetMemoryManager():GetParty();
    local lookup = {};
    local last   = config.partyOnly[1] and 5 or 17;

    for i = 0, last do
        local ok, id, name, job = pcall(function ()
            return party:GetMemberServerId(i), party:GetMemberName(i), party:GetMemberMainJob(i);
        end);
        if (ok and id ~= nil and id ~= 0 and name ~= nil and name ~= '') then
            lookup[id] = { name = name, job = job };
        end
    end
    return lookup;
end

-- Pets act under their own server id, so anything they deal is credited to
-- nobody unless the pet is mapped back to its owner first. GetMemberTargetIndex
-- gives the owner's entity slot, GetPetTargetIndex that slot's pet, and
-- GetServerId turns the pet back into the id the action packet carries.
local function petLookup()
    local lookup = {};
    pcall(function ()
        local party  = AshitaCore:GetMemoryManager():GetParty();
        local entity = AshitaCore:GetMemoryManager():GetEntity();
        local last   = config.partyOnly[1] and 5 or 17;

        for i = 0, last do
            local serverId = party:GetMemberServerId(i);
            local name     = party:GetMemberName(i);
            if (serverId ~= nil and serverId ~= 0 and name ~= nil and name ~= '') then
                local ownerIndex = party:GetMemberTargetIndex(i);
                if (ownerIndex ~= nil and ownerIndex > 0) then
                    local petIndex = entity:GetPetTargetIndex(ownerIndex);
                    if (petIndex ~= nil and petIndex > 0) then
                        local petId = entity:GetServerId(petIndex);
                        if (petId ~= nil and petId ~= 0) then
                            lookup[petId] = { name = name, job = party:GetMemberMainJob(i) };
                        end
                    end
                end
            end
        end
    end);
    return lookup;
end

-- Every id that counts as "one of ours" for the purpose of ignoring actions
-- aimed at it. Pets are included so that curing or buffing a pet is not
-- mistaken for damage dealt to an enemy.
local function allMembers(pets)
    local party  = AshitaCore:GetMemoryManager():GetParty();
    local lookup = {};
    for i = 0, 17 do
        local ok, id = pcall(function () return party:GetMemberServerId(i); end);
        if (ok and id ~= nil and id ~= 0) then
            lookup[id] = true;
        end
    end
    if (pets ~= nil) then
        for id, _ in pairs(pets) do
            lookup[id] = true;
        end
    end
    return lookup;
end

----------------------------------------------------------------------
-- Tracking
----------------------------------------------------------------------
local tracker = {
    players = {},
    order   = {},
    total   = 0,
    active  = 0,
    lastAt  = nil,
};

local selected  = nil;
local debugMode = false;

local function resetTracker()
    tracker.players = {};
    tracker.order   = {};
    tracker.total   = 0;
    tracker.active  = 0;
    tracker.lastAt  = nil;
    selected        = nil;
end

local function entryFor(name, job)
    local entry = tracker.players[name];
    if (entry == nil) then
        entry = {
            name    = name,
            job     = job,
            damage  = 0,
            hits    = 0,
            misses  = 0,
            best    = 0,
            active  = 0,
            lastAt  = nil,
            shown   = 0,
            sources = {},
            swings  = {},
        };
        tracker.players[name] = entry;
        tracker.order[#tracker.order + 1] = entry;
    end
    if (job ~= nil and job ~= 0) then
        entry.job = job;
    end
    return entry;
end

local function record(name, job, label, damage, swingKind)
    local now = os.clock();

    if (tracker.lastAt ~= nil and config.idleSeconds[1] > 0) then
        if ((now - tracker.lastAt) > config.idleSeconds[1]) then
            resetTracker();
        end
    end

    local entry = entryFor(name, job);
    label = label or 'Other';

    if (damage > 0) then
        entry.damage         = entry.damage + damage;
        entry.sources[label] = (entry.sources[label] or 0) + damage;
        tracker.total        = tracker.total + damage;
        if (damage > entry.best) then
            entry.best = damage;
        end
    end

    -- Melee and ranged attacks are the only things we can reliably score for
    -- accuracy: one action per swing or shot, zero damage meaning it did not
    -- connect. Weaponskills, spells and abilities can miss too, but they do
    -- not map cleanly onto an attempt count.
    if (swingKind ~= nil) then
        local bucket = entry.swings[swingKind];
        if (bucket == nil) then
            bucket = { hits = 0, misses = 0 };
            entry.swings[swingKind] = bucket;
        end
        if (damage > 0) then
            bucket.hits = bucket.hits + 1;
            entry.hits  = entry.hits + 1;
        else
            bucket.misses = bucket.misses + 1;
            entry.misses  = entry.misses + 1;
        end
    end

    -- Advance the combat clocks, skipping over downtime.
    if (entry.lastAt ~= nil) then
        local gap = now - entry.lastAt;
        if (gap > 0 and gap <= ACTIVE_GAP) then
            entry.active = entry.active + gap;
        end
    end
    entry.lastAt = now;

    if (tracker.lastAt ~= nil) then
        local gap = now - tracker.lastAt;
        if (gap > 0 and gap <= ACTIVE_GAP) then
            tracker.active = tracker.active + gap;
        end
    end
    tracker.lastAt = now;
end

----------------------------------------------------------------------
-- Packet handling
----------------------------------------------------------------------
ashita.events.register('packet_in', 'deeps_packet_in', function (e)
    if (e.id ~= 0x0028) then
        return;
    end

    local ok, err = pcall(function ()
        local action = parseAction(e.data);
        if (action == nil) then
            return;
        end

        local members = memberLookup();
        local pets    = petLookup();

        local actor  = members[action.actor];
        local viaPet = false;
        if (actor == nil) then
            actor  = pets[action.actor];
            viaPet = (actor ~= nil);
        end
        if (actor == nil) then
            return;         -- not one of ours
        end

        local everyone = allMembers(pets);

        for _, target in ipairs(action.targets) do
            -- A member on the receiving end means a cure, a buff or friendly
            -- fire - never something to add to a damage meter.
            if (everyone[target.id] == nil) then
                for _, act in ipairs(target.actions) do
                    local damage = act.param + act.extra;

                    -- Work out what this action counts as before recording it,
                    -- so debug output can report the decision rather than just
                    -- the raw fields.
                    local label, swingKind, ignoredWhy;
                    if (viaPet == true) then
                        -- Pets also use the monster ability categories for
                        -- blood pacts and ready moves. Their output is kept
                        -- under one label rather than mixed into the owner's
                        -- own melee, and their swings are left out of the
                        -- owner's accuracy.
                        if (PET_CATEGORY[action.category] ~= nil) then
                            label = 'Pet';
                        end
                    elseif (CATEGORY[action.category] ~= nil) then
                        label = CATEGORY[action.category];
                        if (action.category == 1) then
                            swingKind = 'Melee';
                        elseif (action.category == 2) then
                            swingKind = 'Ranged';
                        end
                    end

                    -- Reject magic whose message is not a damage message; the
                    -- number is a status effect id, not a hit.
                    if (label ~= nil) and (action.category == 4)
                        and (MAGIC_DAMAGE[act.message] == nil) then
                        label      = nil;
                        ignoredWhy = 'status effect, not damage';
                    end

                    if (debugMode == true) then
                        local outcome;
                        if (label == nil) then
                            outcome = ignoredWhy and ('IGNORED - ' .. ignoredWhy) or 'IGNORED';
                        elseif (damage > 0) then
                            outcome = ('COUNTED +%d as %s'):fmt(damage, label);
                        else
                            outcome = ('no damage (%s)'):fmt(label);
                        end
                        print(chat.header(addon.name):append(chat.message(
                            ('debug: %s%s cat=%d msg=%d param=%d extra=%d -> %s'):fmt(
                                actor.name, viaPet and ' (pet)' or '',
                                action.category, act.message, act.param, act.extra, outcome))));
                    end

                    if (label ~= nil) then
                        record(actor.name, actor.job, label, damage, swingKind);
                    end
                end
            end
        end
    end);

    if (not ok and debugMode == true) then
        print(chat.header(addon.name):append(chat.message('error: ' .. tostring(err))));
    end
end);

----------------------------------------------------------------------
-- Rendering
----------------------------------------------------------------------
local function jobInfo(entry)
    local info = JOBS[entry.job or 0];
    if (info ~= nil) then
        return info[1], { info[2][1], info[2][2], info[2][3], 1.0 };
    end

    -- Unknown job: fall back to a stable colour derived from the name so
    -- two players never share a bar colour by accident.
    local hash = 0;
    for i = 1, #entry.name do
        hash = (hash * 31 + string.byte(entry.name, i)) % 360;
    end
    local h = hash / 60;
    local x = 0.55 * (1 - math.abs((h % 2) - 1));
    local r, g, b;
    if     (h < 1) then r, g, b = 0.55, x, 0;
    elseif (h < 2) then r, g, b = x, 0.55, 0;
    elseif (h < 3) then r, g, b = 0, 0.55, x;
    elseif (h < 4) then r, g, b = 0, x, 0.55;
    elseif (h < 5) then r, g, b = x, 0, 0.55;
    else                r, g, b = 0.55, 0, x;
    end
    return '---', { r + 0.25, g + 0.25, b + 0.25, 1.0 };
end

local function shortNumber(value)
    if (value >= 1000000) then
        return ('%.2fm'):fmt(value / 1000000);
    elseif (value >= 10000) then
        return ('%.1fk'):fmt(value / 1000);
    end
    return ('%d'):fmt(value);
end

local function clockText(seconds)
    return ('%d:%02d'):fmt(math.floor(seconds / 60), math.floor(seconds % 60));
end

local DIM    = { 0.62, 0.62, 0.62, 1.0 };
local TEXT   = { 1.0, 1.0, 1.0, 1.0 };
local SHADOW = { 0.0, 0.0, 0.0, 1.0 };

-- ImGui has no text outline, so draw the string eight times in black around
-- the target position and once in white on top. Keeps row text legible over
-- bright job colours like COR yellow without dimming the bars themselves.
local OUTLINE = {
    { -1, -1 }, { 0, -1 }, { 1, -1 },
    { -1,  0 },            { 1,  0 },
    { -1,  1 }, { 0,  1 }, { 1,  1 },
};

local function outlinedText(x, y, text)
    for _, offset in ipairs(OUTLINE) do
        imgui.SetCursorPosX(x + offset[1]);
        imgui.SetCursorPosY(y + offset[2]);
        imgui.TextColored(SHADOW, text);
    end
    imgui.SetCursorPosX(x);
    imgui.SetCursorPosY(y);
    imgui.TextColored(TEXT, text);
end

ashita.events.register('d3d_present', 'deeps_present', function ()
    if (config.showWindow[1] ~= true) then
        return;
    end

    imgui.SetNextWindowBgAlpha(0.75);
    imgui.SetNextWindowSize({ config.windowWidth[1], -1 }, ImGuiCond_Always);

    if (imgui.Begin('Deeps', true, bit.bor(ImGuiWindowFlags_NoDecoration))) then
        local partyDps = 0;
        if (tracker.active > 1) then
            partyDps = tracker.total / tracker.active;
        end

        imgui.Text(('Deeps   %s'):fmt(shortNumber(tracker.total)));
        imgui.SameLine();
        local head = ('%.0f dps   %s'):fmt(partyDps, clockText(tracker.active));
        local headWidth = imgui.CalcTextSize(head);
        imgui.SetCursorPosX(imgui.GetCursorPosX() + imgui.GetColumnWidth() - headWidth);
        imgui.TextColored(DIM, head);
        imgui.Separator();

        if (tracker.total == 0) then
            imgui.TextColored(DIM, 'Waiting for damage...');
        else
            -- table.sort is not stable, so equal damage leaves the relative
            -- order of two rows undefined and they swap places every frame.
            -- Falling back to the name gives a total order, which pins tied
            -- players in place instead of letting them flicker.
            table.sort(tracker.order, function (a, b)
                if (a.damage ~= b.damage) then
                    return a.damage > b.damage;
                end
                return a.name < b.name;
            end);

            local best = tracker.order[1].damage;
            if (best <= 0) then best = 1; end

            for rank, entry in ipairs(tracker.order) do
                if (entry.damage > 0) then
                    local share = (entry.damage / tracker.total) * 100;
                    -- A player who acts less often than the 10s gap window
                    -- never builds up a combat clock of their own, which
                    -- would otherwise read as a flat 0 dps. Fall back to the
                    -- party's clock so the figure stays meaningful.
                    local denominator = entry.active;
                    if (denominator < 1) then
                        denominator = tracker.active;
                    end
                    local dps = 0;
                    if (denominator > 1) then
                        dps = entry.damage / denominator;
                    end

                    -- Ease the bar toward its true length instead of snapping,
                    -- and keep a sliver visible for small contributors.
                    local target = entry.damage / best;
                    if (target < 0.04) then target = 0.04; end
                    entry.shown = entry.shown + ((target - entry.shown) * 0.12);

                    local abbrev, color = jobInfo(entry);

                    local rowY = imgui.GetCursorPosY();

                    imgui.PushStyleColor(ImGuiCol_PlotHistogram, color);
                    imgui.ProgressBar(entry.shown, { -1, 19 }, '');
                    imgui.PopStyleColor(1);

                    local clicked = (imgui.IsItemClicked ~= nil) and imgui.IsItemClicked() or false;
                    local nextY   = imgui.GetCursorPosY();

                    local label = ('%d. %s'):fmt(rank, entry.name);

                    local stats = ('%s  %s  %.0f%%  %.0f dps'):fmt(
                        abbrev, shortNumber(entry.damage), share, dps);

                    if (config.showAccuracy[1] == true) then
                        local swings = entry.hits + entry.misses;
                        if (swings > 0) then
                            stats = ('%s  %.0f%% hit'):fmt(stats, (entry.hits / swings) * 100);
                        else
                            stats = ('%s     -- hit'):fmt(stats);
                        end
                    end

                    -- Overlay the row text on top of the bar: name hard left,
                    -- figures hard right, so both columns stay scannable.
                    outlinedText(14, rowY + 2, label);

                    -- Let the cursor settle where the right-aligned figures
                    -- belong, then read that position back so the outline
                    -- passes can be placed absolutely around it.
                    imgui.SameLine();
                    local statsWidth = imgui.CalcTextSize(stats);
                    imgui.SetCursorPosX(imgui.GetCursorPosX() + imgui.GetColumnWidth() - statsWidth - 4);
                    local statsX = imgui.GetCursorPosX();

                    outlinedText(statsX, rowY + 2, stats);

                    -- Rewinding the cursor to overlay text means ImGui never
                    -- saw an item at the row's full height. Submitting an
                    -- empty one tells it how far the window actually grew.
                    imgui.SetCursorPosY(nextY);
                    if (imgui.Dummy ~= nil) then
                        imgui.Dummy({ 0, 0 });
                    end

                    if (clicked) then
                        if (selected == entry.name) then
                            selected = nil;
                        else
                            selected = entry.name;
                        end
                    end

                    if (selected == entry.name) then
                        imgui.Indent(16);
                        for kind, bucket in pairs(entry.swings) do
                            local attempts = bucket.hits + bucket.misses;
                            if (attempts > 0) then
                                imgui.TextColored(DIM, ('%s acc  %.1f%%  (%d of %d)'):fmt(
                                    kind, (bucket.hits / attempts) * 100, bucket.hits, attempts));
                            end
                        end
                        imgui.TextColored(DIM, ('best hit   %s'):fmt(shortNumber(entry.best)));
                        imgui.TextColored(DIM, ('combat     %s'):fmt(clockText(entry.active)));
                        for label, amount in pairs(entry.sources) do
                            imgui.TextColored(DIM, ('%s  %s  (%.0f%%)'):fmt(
                                label, shortNumber(amount), (amount / entry.damage) * 100));
                        end
                        imgui.Unindent(16);
                        imgui.Spacing();
                    end
                end
            end
        end
    end
    imgui.End();
end);

----------------------------------------------------------------------
-- Commands
----------------------------------------------------------------------
local function say(message)
    print(chat.header(addon.name):append(chat.message(message)));
end

ashita.events.register('command', 'deeps_command', function (e)
    local args = e.command:args();
    if (#args == 0 or not args[1]:any('/dps', '/deeps')) then
        return;
    end

    e.blocked = true;

    if (#args == 1) then
        config.showWindow[1] = not config.showWindow[1];
        settings.save();
        return;
    end

    if (args[2]:any('reset')) then
        resetTracker();
        say('cleared.');
        return;
    end

    if (args[2]:any('party')) then
        config.partyOnly[1] = not config.partyOnly[1];
        settings.save();
        say(config.partyOnly[1] and 'tracking your party only.' or 'tracking the whole alliance.');
        return;
    end

    if (args[2]:any('acc', 'accuracy')) then
        config.showAccuracy[1] = not config.showAccuracy[1];
        settings.save();
        say(config.showAccuracy[1] and 'accuracy column shown.' or 'accuracy column hidden.');
        return;
    end

    if (args[2]:any('width')) then
        local width = tonumber(args[3]);
        if (width == nil or width < 200) then
            say('usage: /dps width <pixels>   (minimum 200)');
            return;
        end
        config.windowWidth[1] = width;
        settings.save();
        say(('width set to %d.'):fmt(width));
        return;
    end

    if (args[2]:any('idle')) then
        local seconds = tonumber(args[3]);
        if (seconds == nil) then
            say('usage: /dps idle <seconds>   (0 disables auto-clear)');
            return;
        end
        config.idleSeconds[1] = seconds;
        settings.save();
        if (seconds > 0) then
            say(('data clears after %d seconds of no damage.'):fmt(seconds));
        else
            say('auto-clear disabled.');
        end
        return;
    end

    if (args[2]:any('debug')) then
        debugMode = not debugMode;
        say('debug logging ' .. (debugMode and 'on' or 'off'));
        return;
    end

    say('/dps              - toggle the window');
    say('/dps reset        - clear all data');
    say('/dps party        - party only vs whole alliance');
    say('/dps acc          - show or hide the accuracy column');
    say('/dps width <px>   - window width');
    say('/dps idle <sec>   - auto-clear after inactivity (0 = never)');
    say('/dps debug        - log every parsed action');
end);

ashita.events.register('unload', 'deeps_unload', function ()
    settings.save();
end);
