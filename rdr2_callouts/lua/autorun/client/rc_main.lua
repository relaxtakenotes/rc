/*
    Notes for people that wanna make their own sound packs with this:
       1) Don't use non-wav formats, as it'll break certain timings due to SoundDuration() not supporting anything else but wav (if you REALLY want non-wav, lmk)
       2) Conversion tools can be found in the github repo, precisely in rdr2_callouts/sound/rc/
       3) If you do not wish or can't include a certain event type, you can simply not create a folder for it. The mod will ignore it and wont try to use it.
       4) If you wish for more functionality, let me know or make it yourself.
          You can pull request improvements, fixes or changes to my github repo or post your own version wherever you want. No need to ask me for permission.
          (refer to the unlicense license if you're unsure. fyi i have it on almost every mod i made fully myself)
*/
 
local enabled = CreateConVar("cl_rc_enabled", 1, FCVAR_ARCHIVE)
local debug_enabled = CreateConVar("cl_rc_debug_enabled", 1, FCVAR_ARCHIVE)
local voice_name = CreateConVar("cl_rc_voice_name", "arthur", FCVAR_ARCHIVE)

local desired_timeout = 5
local timeout = 0

local battle_timer = 0

local enemies = {}
local local_enemies = {}
local networked_enemies = {}

local enemy_count = 0
local closest_enemy_distance = math.huge
local didnt_move_timer = 0
local didnt_shoot_timer = 0
local misses = 0

local sprinting_timer = 0
local sprint_recovered = true

local has_ammo = true
local has_ammo_last = true

local playing = false

local menu_open = false
local last_menu_open = false

local samples = util.JSONToTable(file.Read("!rc_samples.lua", "LUA"))
local samples_framerate = 256

local fchance = {}

local stroffset = 0
local function screen_text(text)
    stroffset = stroffset + 0.02
    debugoverlay.ScreenText(0.3, 0.3 + stroffset, text, FrameTime(), Color(255, 231, 152))
end

local events = {}

local function read_vector_uncompressed()
	local tempVec = Vector(0, 0, 0)
	tempVec.x = net.ReadFloat()
	tempVec.y = net.ReadFloat()
	tempVec.z = net.ReadFloat()
	return tempVec
end

local function find_sounds(pathstart, pathend)
    local result = file.Find("sound/"..pathstart..pathend, "GAME")
    
    for i, _path in ipairs(result) do
        local path = pathstart.._path
        result[i] = path
        fchance[path] = 1
    end

    return result
end

local function get_random_file_with_pattern(files, pattern, opposite)
    local matched_files = {}
    local count = 0

    for i, path in ipairs(files) do
        local match = string.match(path, pattern)
        if (not opposite and match) or (opposite and not match) then
            count = count + 1
            table.insert(matched_files, path) 
        end
    end

    if count <= 0 then
        return "none"
    end
    
    for i = 1, 100 do
        local path = matched_files[math.random(1, count)]
        for key, item in pairs(fchance) do
            if key != path then 
                fchance[key] = math.min(1, fchance[key] + 0.1)
            end
        end
        if fchance[path] > 0.9 then
            fchance[path] = math.max(0, fchance[path] - 0.25)
            return path
        end
    end
    
    return matched_files[math.random(1, count)]
end

local function play(path, volume)
    //EmitSound(path, LocalPlayer():EyePos(), -1, CHAN_VOICE, volume, 75, SND_DO_NOT_OVERWRITE_EXISTING_ON_CHANNEL, 100, 0)
    if (rdrm and (rdrm.in_deadeye or rdrm.in_killcam)) or LocalPlayer():Health() <= 0 then return end

    net.Start("rc_request_sound")
    net.WriteString(path)
    net.SendToServer()
end

local function stop(path)
    net.Start("rc_stop_sound")
    net.WriteString(path)
    net.SendToServer()
end

net.Receive("rc_sound_broadcast", function(len)
    local entity = net.ReadEntity()
    local path = net.ReadString()

    if samples[path] and IsValid(entity) then
        entity.current_samples = samples[path]
        entity.current_samples_tick = 0
        entity.current_samples_length = table.Count(samples[path])
    end
end)

// basically made crackhead classes right there.
// i have a friend who told me to use moonscript for a really long time now... here it'd be pretty good i feel like.

local function add_event(data)
    local files = find_sounds("rc/"..voice_name:GetString().."/"..data.name.."/", "*.wav")

    if table.Count(files) <= 0 then
        print("[RC] Couldn't find any sounds for the \""..data.name.."\"event! Not adding it.")
        return
    end

    events[data.name] = {
        pretty_name = data.pretty_name or data.name,
        files = files,
        timeout = 0,
        check_timeout = 0,
        desired_timeout = data.desired_timeout,
        chance = data.chance,
        should_play = function(self)
            local _should_play = true
            if isfunction(data.should_play) then
                _should_play = data.should_play(self)
            end
            return math.Rand(0, 1) > 1-self.chance and timeout <= 0 and self.timeout <= 0 and _should_play end,
        get_sound = data.get_sound,
        play = data.play or function(self)
            if playing then return end

            local path = self:get_sound()
            local lp = LocalPlayer()
        
            playing = true
            timer.Simple(math.Rand(0.4, 0.6), function()
                play(path, 1)
                timer.Simple(SoundDuration(path) + 0.2, function() playing = false end)
            end)
        end,
        manual = data.manual and true or false,
        visible = data.visible,
        ui_fade = 1,
        ui_fade_click = 1,
    }

    print("[RC] Added: ", data.pretty_name)
end

local function handle_event(name, concommand_forced)
    local event = events[name]

    if not event then
        print("[RC] Can't handle a non existing event: "..name)
        return
    end

    if not concommand_forced and not event.manual and not event:should_play() then
        return 
    end

    event:play()

    if not event.manual then 
        event.timeout = event.desired_timeout
        timeout = desired_timeout 
    end
end

local function add_events()
    events = {}
    
    add_event({
        name = "enemy_missed_player",
        pretty_name = "Enemy Near Miss",
        desired_timeout = 40,
        chance = 0.2,
        should_play = function(self) return battle_timer > 0 end,
        get_sound = function(self) 
            return get_random_file_with_pattern(self.files, "%w+")
        end
    })

    add_event({
        name = "player_missed_enemy",
        pretty_name = "Player Near Miss",
        desired_timeout = 40,
        chance = 0.2,
        should_play = function(self) return battle_timer > 0 end,
        get_sound = function(self) 
            return get_random_file_with_pattern(self.files, "%w+")
        end
    })

    add_event({
        name = "enemy_damaged_player",
        pretty_name = "Player Hurt",
        desired_timeout = 30,
        chance = 0.4,
        should_play = function(self) return battle_timer > 0 end,
        get_sound = function(self) 
            return get_random_file_with_pattern(self.files, "%w+")
        end
    })

    add_event({
        name = "enemy_damaged_player_huff",
        pretty_name = "Player Hurt (Huff)",
        desired_timeout = 5,
        chance = 0.8,
        manual = true,
        visible = false,
        play = function(self)
            if playing then return end

            local path = get_random_file_with_pattern(self.files, "%w+")
            local lp = LocalPlayer()
        
            playing = true
            timer.Simple(math.Rand(0.05, 0.1), function()
                play(path, 1)
                timer.Simple(SoundDuration(path) + 0.2, function()
                    playing = false
                    handle_event("enemy_damaged_player")
                end)
            end)
        end
    })

    add_event({
        name = "player_killed_enemy",
        pretty_name = "Killed an Enemy",
        desired_timeout = 30,
        chance = 0.35,
        visible = false,
        get_sound = function(self)
            if enemy_count > 1 then
                return get_random_file_with_pattern(self.files, "%w+")
            end

            return "rc_none"
        end
    })

    add_event({
        name = "player_taunt",
        pretty_name = "Taunt",
        desired_timeout = 50,
        chance = 0.3,
        should_play = function(self) return battle_timer > 0 end,
        get_sound = function(self)
            if didnt_move_timer > 10 and math.Rand(0,1) > 0.5 then
                return get_random_file_with_pattern(self.files, "NOT_MOVED_POS")
            end

            if didnt_shoot_timer > 10 and math.Rand(0,1) > 0.5 then
                return get_random_file_with_pattern(self.files, "STOPPED_SHOOTING")
            end

            local distance = closest_enemy_distance <= 500 and "NEAR" or "FAR"
            local multiple = enemy_count > 1 and "MULTIPLE_ENEMIES" or "SINGLE_ENEMY"

            local choices = {}

            table.insert(choices, get_random_file_with_pattern(self.files, "PLAYER_TAUNT_ENEMY"))
            table.insert(choices, get_random_file_with_pattern(self.files, "PLAYER_TAUNT_LAW_%w+_"..distance))
            table.insert(choices, get_random_file_with_pattern(self.files, "PLAYER_TAUNT_"..multiple.."_%w+_"..distance))

            return choices[math.random(1, 3)]
        end
    })

    add_event({
        name = "player_roughly_landed",
        pretty_name = "Rough Landing",
        desired_timeout = 3,
        manual = true,
        visible = false,
        play = function(self)
            if playing or self.timeout > 0 then return end

            local lp = LocalPlayer()

            local long_vocal = math.Rand(0, 1) > 0.5
            local path = long_vocal and get_random_file_with_pattern(self.files, "GET_UP_FROM_FALL") or get_random_file_with_pattern(self.files, "JUMP_LAND")
            local delay = long_vocal and math.Rand(0.2, 0.4) or math.Rand(0, 0.1)

            playing = true
            timer.Simple(delay, function()
                play(path, 1)
                timer.Simple(SoundDuration(path) + 0.2, function() playing = false end)
            end)
            timeout = self.desired_timeout
        end
    })

    add_event({
        name = "player_jumped",
        pretty_name = "Jump Huff",
        desired_timeout = 0,
        manual = true,
        visible = false,
        play = function(self)
            if playing then return end

            playing = true
            local path = get_random_file_with_pattern(self.files, "%w+")
            play(path, 1)
            timer.Simple(SoundDuration(path) + 0.2, function() 
                playing = false
            end)
        end
    })

    add_event({
        name = "player_has_no_ammo",
        pretty_name = "No Ammo",
        desired_timeout = 10,
        chance = 0.5,
        get_sound = function(self)
            if battle_timer > 0 then
                return get_random_file_with_pattern(self.files, "URGENT")
            end

            return get_random_file_with_pattern(self.files, "URGENT", true)
        end
    })

    add_event({
        name = "player_breathing",
        pretty_name = "Breathing",
        desired_timeout = 1.25,
        manual = true,
        visible = false,
        play = function(self)
            if playing or self.timeout > 0 then return end

            local lp = LocalPlayer()

            self.timeout = 1.25
            local inhale = get_random_file_with_pattern(self.files, "INHALE")
            local exhale = get_random_file_with_pattern(self.files, "EXHALE")
            
            playing = true

            play(inhale, 0.3)
            timer.Simple(SoundDuration(inhale) + math.Rand(0.1, 0.1), function()
                play(exhale, 0.3)
                timer.Simple(SoundDuration(exhale) + 0.2, function() playing = false end)
            end)
        end
    })

    add_event({
        name = "player_breathing_recovery",
        pretty_name = "Out of Breath",
        desired_timeout = 1.25,
        manual = true,
        visible = false,
        play = function(self)
            if playing or self.timeout > 0 then return end

            local lp = LocalPlayer()

            self.timeout = 1.25

            local second = get_random_file_with_pattern(self.files, "PART_B_")
            local third = get_random_file_with_pattern(self.files, "PART_C_")
            
            playing = true

            timer.Simple(math.Rand(0.2, 0.4), function() 
                play(second, 0.6)
                timer.Simple(SoundDuration(second) + math.Rand(0.1, 0.3), function() 
                    play(third, 0.6)
                    timer.Simple(SoundDuration(third) + 0.2, function() playing = false end)
                end)
            end)

            sprint_recovered = true
        end
    })

    add_event({
        name = "player_falling_high",
        pretty_name = "Fall Yelling",
        desired_timeout = 1.25,
        manual = true,
        visible = false,
        play = function(self)
            if playing or self.timeout > 0 then return end
            playing = true

            local path = get_random_file_with_pattern(self.files, "%w+")

            self.current_path = path // to stop it later if needed
            self.timeout = SoundDuration(path) + 0.2

            play(path, 1)

            timer.Simple(self.timeout - 0.2, function() 
                playing = false
            end)
        end
    })

    for pretty_name, name in pairs(
        {
        ["Threaten"] = "player_threaten", 
        ["Defuse"] = "player_defuse", 
        ["Good Morning"] = "player_greet_morning", 
        ["Hi"] = "player_greet_general", 
        ["Good evening"] = "player_greet_evening", 
        ["Farewell"] = "player_goodbye",
        ["Laugh"] = "player_laugh"
        }
    ) do
        add_event({
            name = name,
            pretty_name = pretty_name,
            desired_timeout = 1.25,
            manual = true,
            play = function(self)
                if playing or self.timeout > 0 then return end
                
                local path = get_random_file_with_pattern(self.files, "%w+")
                
                playing = true
                play(path, 1)
                timer.Simple(SoundDuration(path) + 0.2, function() 
                    playing = false
                end)
            end
        })
    end

    for pretty_name, name in pairs(
        {
            ["Shock Loud"] = "player_shocked_high", 
            ["Curse Loud"] = "player_curse_high",
            ["Shock Timid"] = "player_shocked_med", 
            ["Curse Timid"] = "player_curse_med",
        }
    ) do
        add_event({
            name = name,
            pretty_name = pretty_name,
            desired_timeout = 1.25,
            manual = true,
            play = function(self)
                if playing or self.timeout > 0 then return end
                
                local path = self.curse_type != nil and get_random_file_with_pattern(self.files, self.curse_type) or get_random_file_with_pattern(self.files, "%w+")

                playing = true
                play(path, 1)
                timer.Simple(SoundDuration(path) + 0.2, function() 
                    playing = false
                end)
            end
        })
    end
end

add_events()

cvars.AddChangeCallback(voice_name:GetName(), function(convar, oldvalue, newvalue) 
    add_events()
end, "rc_event_reload")

concommand.Add("rc_talk", function(ply, cmd, args, argstr)
    if not enabled:GetBool() then return end

    if args[2] then
        if args[1] == "player_curse" or args[1] == "player_shocked" then
            events[args[1]].curse_type = args[2] == "MED" and "MED" or "HIGH"
        end
    end
    handle_event(args[1], true)
end)

net.Receive("rc_enemies", function(len) 
    if not enabled:GetBool() then return end
    networked_enemies = net.ReadTable()
end)

net.Receive("rc_entityfirebullets", function(len)
    if not enabled:GetBool() then return end

    local src = read_vector_uncompressed()
	local dir = read_vector_uncompressed()
	local vel = read_vector_uncompressed()
	local spread = read_vector_uncompressed()
	local entity = net.ReadEntity()
	local weapon = net.ReadEntity()
    local disposition = net.ReadInt(4)

    if not IsValid(entity) then return end

    local lp = LocalPlayer()

    local shootpos = entity:EyePos()
    local tr = util.TraceLine({
        start = shootpos,
        endpos = shootpos + dir * 10000000,
        filter = entity,
        mask = MASK_SHOT
    })

    if IsValid(tr.Entity) and tr.Entity == lp then return end

    if entity == lp then
        // handle localplayer shooting... and perhaps missing
        didnt_shoot_timer = 0

        local entities = ents.FindInCone(tr.StartPos, dir, 10000000, 0.2)
        
        for i, ent in ipairs(entities) do
            if not IsValid(ent) or not (ent:IsNPC() or ent:IsPlayer()) or ent == lp then continue end

            local distance = ent:GetPos():Distance(lp:GetPos())
            if distance > 28284 or distance < 316 then
                continue
            end

            local ldistance, _, _ = util.DistanceToLine(tr.StartPos, tr.HitPos, ent:EyePos())
            if ldistance < 72 and tr.Entity != ent then
                handle_event("player_missed_enemy")
                if enemies[ent] == true then
                    battle_timer = 60
                    misses = misses + 1
                end
                return // we already missed someone, no point in looking for more people to yell at!
            end
        end
    else
        // handle enemies shooting at you
        if disposition != 1 then // 1 = D_HT, but when i compared it with D_HT, it didn't pass... wtf?
            return 
        end
    
        local ldistance, point, _ = util.DistanceToLine(tr.StartPos, tr.HitPos, lp:EyePos())
        
        if ldistance < 72 then
            if battle_timer <= 0 then
                handle_event("player_curse_high")
            else
                handle_event("enemy_missed_player")
            end
            local_enemies[entity] = true
            battle_timer = 60
        end
    end
end)

net.Receive("rc_entitytakedamage", function(len)
    if not enabled:GetBool() then return end

    local target = net.ReadEntity()
    local attacker = net.ReadEntity()
    local damage = net.ReadFloat()
    local is_fall_damage = net.ReadBool()

    local lp = LocalPlayer()

    if target == lp and not is_fall_damage then
        handle_event("enemy_damaged_player_huff")
        if attacker:IsNPC() or attacker:IsPlayer() and attacker != lp then
            local_enemies[attacker] = true
            battle_timer = 60
        end
    end

    if attacker == lp and (target:IsNPC() or target:IsPlayer()) then
        misses = math.max(0, misses - 2)
        if enemies[target] then
            battle_timer = 60
        end
    end

    if is_fall_damage and lp:Health() - damage > 0 then
        if events["player_falling_high"] and events["player_falling_high"].current_path then
            stop(events["player_falling_high"].current_path)
            events["player_falling_high"].current_path = nil
            events["player_falling_high"].timeout = 0
            playing = false
        end
        handle_event("player_roughly_landed")
    end
end)


gameevent.Listen("entity_killed")
hook.Add("entity_killed", "rc_entitykilled", function(data)
    if not enabled:GetBool() then return end

    local attacker = Entity(data.entindex_attacker)
    local victim = Entity(data.entindex_killed)

    local true_attacker = NULL
    local weapon = NULL
    
    if attacker:IsPlayer() or attacker:IsNPC() then
        true_attacker = attacker
        weapon = true_attacker:GetActiveWeapon()
    elseif IsValid(attacker) then
        weapon = attacker
        true_attacker = weapon:GetOwner()
        if true_attacker == NULL then 
            true_attacker = attacker
        end
    else
        return
    end

    local lp = LocalPlayer()

	if true_attacker == lp and (victim:IsNPC() or victim:IsPlayer()) and (enemies[victim] or battle_timer > 0) then
        handle_event("player_killed_enemy")
    end

    if victim == lp then
        local_enemies = {}
        networked_enemies = {}
        enemies = {}
        battle_timer = 0
        didnt_move_timer = 0
        didnt_shoot_timer = 0
        misses = 0
        sprinting_time = 0
    end
end)

net.Receive("rc_footstep", function(len)
    if not enabled:GetBool() then return end

    local jumped = net.ReadBool()

    if jumped and LocalPlayer():GetVelocity():Length2D() > 100 then
        handle_event("player_jumped")
    end
end)

hook.Add("Think", "rc_think", function()
    if not enabled:GetBool() then return end

    local lp = LocalPlayer()
    local pos = LocalPlayer():GetPos()
    local moving = lp:KeyDown(IN_FORWARD) or lp:KeyDown(IN_BACK) or lp:KeyDown(IN_MOVELEFT) or lp:KeyDown(IN_MOVERIGHT)

    battle_timer = math.max(0, battle_timer - FrameTime())
    timeout = math.max(0, timeout - FrameTime())

    // handle the enemy list and calculate closest enemy distance so we dont loop over it again 8)
    enemies = {}
    enemies = table.Merge(enemies, networked_enemies)
    enemies = table.Merge(enemies, local_enemies)

    closest_enemy_distance = math.huge
    enemy_count = 0
    for enemy, _ in pairs(enemies) do
        if not IsValid(enemy) then
            networked_enemies[enemy] = nil
            local_enemies[enemy] = nil
            enemies[enemy] = nil
            continue
        end
        enemy_count = enemy_count + 1
        closest_enemy_distance = math.min(closest_enemy_distance, enemy:GetPos():DistToSqr(pos))
    end
    closest_enemy_distance = math.sqrt(closest_enemy_distance)

    // stop battle smoothly if there're no enemies
    if enemy_count <= 0 and battle_timer > 0 then
        battle_timer = math.max(0, battle_timer - FrameTime() * battle_timer)
    end

    // reset some stuff when the battle is over
    if battle_timer <= 0 then
        misses = 0
    end

    // event timers
    for name, event in pairs(events) do
        if debug_enabled:GetBool() then
            screen_text(name..": "..tostring(event.timeout).." | "..tostring(event.check_timeout))
        end
        event.timeout = math.max(0, event.timeout - FrameTime())
        event.check_timeout = math.max(0, event.check_timeout - FrameTime())
    end

    // sprinting timer
    if lp:KeyDown(IN_SPEED) and moving then
        sprinting_timer = math.min(sprinting_timer + FrameTime(), 20)
    else
        sprinting_timer = math.max(0, sprinting_timer - FrameTime() * sprinting_timer * 2 - FrameTime())
    end

    // not moving timer
    if not moving and battle_timer > 0 then
        didnt_move_timer = didnt_move_timer + FrameTime()
    else
        didnt_move_timer = math.max(0, didnt_move_timer - FrameTime() * 2)
    end

    // not shooting timer
    if battle_timer > 0 then
        didnt_shoot_timer = didnt_shoot_timer + FrameTime() / 3
    else
        didnt_shoot_timer = 0
    end

    // player taunt specific check
    if events["player_taunt"] and events["player_taunt"].check_timeout <= 0 then 
        handle_event("player_taunt")
        events["player_taunt"].check_timeout = 10
    end

    // handle no ammo event
    local weapon = lp:GetActiveWeapon()
    if IsValid(weapon) and weapon:GetClass() != "weapon_rpg" then
        local ammotype = weapon:GetPrimaryAmmoType()
        has_ammo_last = has_ammo
        has_ammo = lp:GetAmmoCount(ammotype) > 0
        if ammotype == -1 then
            has_ammo = true
            has_ammo_last = true
        end
        if not has_ammo and has_ammo_last then
            handle_event("player_has_no_ammo")
        end
    end

    // handle sprinting
    if sprinting_timer <= 0 and not sprint_recovered then
        handle_event("player_breathing_recovery")
    end

    if sprinting_timer >= 20 then
        sprint_recovered = false
        handle_event("player_breathing")
    end

    // handle falling and then screaming like a little bitch 

    if lp:GetVelocity().z < -900 and lp:GetMoveType() == MOVETYPE_WALK then
        handle_event("player_falling_high")
    elseif events["player_falling_high"] and events["player_falling_high"].current_path then
        stop(events["player_falling_high"].current_path)
        events["player_falling_high"].current_path = nil
        events["player_falling_high"].timeout = 0
        playing = false
    end

    // debug
    if debug_enabled:GetBool() then
        screen_text("battle_timer: "..tostring(battle_timer))
        screen_text("timeout: "..tostring(timeout))
        screen_text("misses: "..tostring(misses))
        screen_text("sprinting_timer: "..tostring(sprinting_timer))
        screen_text("didnt_move_timer: "..tostring(didnt_move_timer))
        screen_text("didnt_shoot_timer: "..tostring(didnt_shoot_timer))
        screen_text("closest_enemy_distance: "..tostring(closest_enemy_distance))
        screen_text("playing: "..tostring(playing))
        screen_text("enemies: "..table.ToString(enemies))
        stroffset = 0
    end
end)

surface.CreateFont("rc_font", {
    font = "Chinese Rocks", --  Use the font-name which is shown to you by your operating system Font Viewer, not the file name
	extended = false,
	size = 18,
	weight = 400,
	blursize = 0,
	scanlines = 0,
	antialias = true,
	underline = false,
	italic = false,
	strikeout = false,
	symbol = false,
	rotary = false,
	shadow = false,
	additive = false,
	outline = false,
})

concommand.Add("rc_menu", function() 
    menu_open = not menu_open
    gui.EnableScreenClicker(menu_open)
end)

concommand.Add("+rc_menu", function() 
    menu_open = true
    gui.EnableScreenClicker(true)
end)

concommand.Add("-rc_menu", function() 
    menu_open = false
    gui.EnableScreenClicker(false)
end)

local last_mouse_down = false
local mouse_down = false

local animfrac = 0

local function pairsByKeys(t, f)
    local a = {}
    for n in pairs(t) do table.insert(a, n) end
    table.sort(a, f)
    local i = 0      -- iterator variable
    local iter = function ()   -- iterator function
        i = i + 1
        if a[i] == nil then return nil
        else return a[i], t[a[i]]
        end
    end
    return iter
end

local function is_hovered(box1x, box1y, box1w, box1h, box2x, box2y, box2w, box2h)
    return not (box1x > box2x + box2w - 1 or box1y > box2y + box2h - 1 or box2x > box1x + box1w - 1 or box2y > box1y + box1h - 1)
end

local max_width = 0

hook.Add("RenderScreenspaceEffects", "rc_ui", function()
    if not enabled:GetBool() then return end

    if menu_open then
        animfrac = math.min(1, animfrac + FrameTime() * 2)
    else
        animfrac = math.max(0, animfrac - FrameTime() * 2)
    end

    if animfrac <= 0 then return end

    local width = ScrW()
    local height = ScrH()

    local total_count = 0
    for name, event in pairs(events) do
        if event.visible == false then continue end
        total_count = total_count + 1
    end
    local count = 0

    local in_frac = math.ease.InQuad(1 - animfrac)

    surface.SetFont("rc_font")

    local px = 10
    local py = 15
    draw.RoundedBox(16, width * 0.1 - px, height * 0.5 + in_frac * height - total_count * 20 / 2 - py, max_width + px*2, total_count * 20 + py*2, Color(0,0,0,150))

    for name, event in pairsByKeys(events) do
        if event.visible == false then continue end

        local text_x = width * 0.1
        local text_y = count * 20 + height * 0.5 + in_frac * height - total_count * 20 / 2

        local text = (count+1)..": "..event.pretty_name
        surface.SetTextPos(text_x, text_y)

        local sx, sy = surface.GetTextSize(text)
        local mouse_x, mouse_y = gui.MouseX(), gui.MouseY()
        
        max_width = math.max(sx, max_width)
        
        event.ui_fade_click = math.Clamp(event.ui_fade_click + FrameTime(), 0.5, 1)
        if is_hovered(text_x, text_y, sx, sy, mouse_x, mouse_y, -1, -1) then
            event.ui_fade = math.Clamp(event.ui_fade - FrameTime() * 5, 0.5, 1)

            last_mouse_down = mouse_down
            mouse_down = input.IsMouseDown(MOUSE_FIRST)
            if last_mouse_down != mouse_down and mouse_down then
                handle_event(name, true)
                event.ui_fade_click = 0.5
            end
        else
            event.ui_fade = math.Clamp(event.ui_fade + FrameTime() * 5, 0.5, 1)
        end

        surface.SetTextColor(255, 255 * event.ui_fade * event.ui_fade_click, 255 * event.ui_fade * event.ui_fade_click, 220 + 35 * (1 - event.ui_fade) * 2)

        draw.SimpleTextOutlined(text, "rc_font", text_x, text_y, Color(255, 255 * event.ui_fade * event.ui_fade_click, 255 * event.ui_fade * event.ui_fade_click), nil, nil, 1, Color(0,0,0))

        count = count + 1
    end
end)

hook.Add("PreDrawOpaqueRenderables", "rc_mouth_move_animation", function()
    for i, ply in ipairs(player.GetAll()) do
        local flexes = {
            ply:GetFlexIDByName("jaw_drop"),
            ply:GetFlexIDByName("left_part"),
            ply:GetFlexIDByName("right_part"),
            ply:GetFlexIDByName("left_mouth_drop"),
            ply:GetFlexIDByName("right_mouth_drop")
        }

        ply.current_samples_tick = (ply.current_samples_tick or 0) + FrameTime() * samples_framerate / 2 // investigate why i have to divide by two here...

        if (ply.current_samples_length or 0) <= ply.current_samples_tick then 
            ply.current_samples = {}
            ply.current_samples_tick = 0
            ply.current_samples_length = 0
        end

        if ply.current_samples_length > 0 then
            ply.weight = math.Clamp(ply.current_samples[math.ceil(ply.current_samples_tick)] / 65535 * 2, 0, 2)
        else
            ply.weight = 0
        end

        ply.lerped_weight = Lerp((FrameTime() * 20 + FrameTime()) / 2, (ply.lerped_weight or 0), ply.weight)

        for k, v in ipairs(flexes) do
            ply:SetFlexWeight(v, ply.lerped_weight)
        end

        ply.lerped_weight = Lerp((FrameTime() * 20 + FrameTime()) / 2, (ply.lerped_weight or 0), ply.weight)
    end
end)