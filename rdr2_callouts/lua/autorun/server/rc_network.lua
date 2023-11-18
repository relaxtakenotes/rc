local enabled = CreateConVar("sv_rc_enabled", 1, FCVAR_ARCHIVE)
local ignore_list = {"npc_clawscanner", "npc_stalker", "npc_turret_floor", "npc_combinedropship", "npc_cscanner", "npc_turret_ceiling", "npc_combine_camera", "npc_crow", "npc_pigeon", "npc_seagull"}

util.AddNetworkString("rc_entityfirebullets")
util.AddNetworkString("rc_entitytakedamage")
util.AddNetworkString("rc_footstep")
util.AddNetworkString("rc_request_sound")
util.AddNetworkString("rc_stop_sound")
util.AddNetworkString("rc_stopsound_broadcast")
util.AddNetworkString("rc_sound_broadcast")
util.AddNetworkString("rc_enemies")

net.Receive("rc_request_sound", function(len, ply)
    if not enabled:GetBool() then return end

    local path = net.ReadString()

    if not string.StartsWith(path, "rc/") then return end

    //ply:EmitSound(path, 75, 100, 1, CHAN_STATIC, 0, 0)

    timer.Simple(0, function() 
        net.Start("rc_sound_broadcast", false)
        net.WriteEntity(ply)
        net.WriteString(path)
        net.Broadcast()
    end)
end)

net.Receive("rc_stop_sound", function(len, ply)
    if not enabled:GetBool() then return end

    local path = net.ReadString()

    if not string.StartsWith(path, "rc/") then return end

    timer.Simple(0, function() 
        net.Start("rc_stopsound_broadcast", false)
        net.WriteEntity(ply)
        net.WriteString(path)
        net.Broadcast()
    end)

    //ply:StopSound(path)
end)

hook.Add("PlayerFootstep", "rc_footstep", function(ply, ...) 
    if not enabled:GetBool() then return end

    net.Start("rc_footstep")
    net.WriteBool(ply:KeyPressed(IN_JUMP))
    net.Send(ply)
end)

hook.Add("EntityTakeDamage", "rc_hurt", function(target, dmg) 
    if not enabled:GetBool() then return end

    net.Start("rc_entitytakedamage")
    net.WriteEntity(target)
    net.WriteEntity(dmg:GetAttacker())
    net.WriteFloat(dmg:GetDamage())
    net.WriteBool(bit.band(dmg:GetDamageType(), DMG_FALL) == DMG_FALL)
    net.Broadcast()
end)

local function enemy_is_alerted_and_close(npc, ply)
    if npc:Disposition(ply) ~= D_HT then return false end
    if npc:GetPos():Distance(ply:GetPos()) > 1250 and not npc.am_alerted_was_close then return false end
    if npc:GetNPCState() ~= NPC_STATE_COMBAT and npc:GetNPCState() ~= NPC_STATE_ALERT and npc:GetActivity() ~= ACT_COMBAT_IDLE then return false end
    npc.am_alerted_was_close = true

    return true
end

local function npc_can_attack(npc)
    if not isfunction(npc.GetActiveWeapon) or npc:GetActiveWeapon() ~= NULL then return true end
    if npc:GetShootPos():Distance(npc:GetPos()) > 0 and bit.band(npc:CapabilitiesGet(), CAP_USE_WEAPONS) == CAP_USE_WEAPONS then return false end

    return true
end

hook.Add("FinishMove", "rc_threat_loop", function(ply, mv)
    if engine.TickCount() % 2 == 0 then return end

    if ply.rc_timeout and ply.rc_timeout > 0 then
        ply.rc_timeout = math.max(ply.rc_timeout - FrameTime() * 2, 0) -- frametime*2 cuz we're skipping half the ticks

        return
    end

    ply.rc_timeout = 1
    ply.enemies = {}

    if enabled:GetBool() then
        for _, npc in ipairs(ents.FindByClass("npc_*")) do
            if table.HasValue(ignore_list, npc:GetClass()) then continue end
            if not IsValid(npc) or not npc:IsNPC() or not npc.GetEnemy then continue end --print(IsValid(npc), npc:IsNPC(), npc.GetEnemy, " --- ", npc)
            if not npc_can_attack(npc) then continue end
            local target = npc:GetEnemy()
            if not target or not target:IsValid() then continue end

            if target == ply or enemy_is_alerted_and_close(npc, ply) then
                local player_pos = ply:EyePos()
                local npc_pos = npc:GetPos() + vector_up * 32
                local distance = player_pos:Distance(npc_pos)
        
                local tr = util.TraceLine({
                    start = player_pos,
                    endpos = npc_pos,
                    filter = {ply, npc},
                    mask = MASK_NPCWORLDSTATIC
                })
        
                if tr.Fraction <= 0.9 then
                    distance = distance ^ 1.2
                end

                if distance >= 5000 then continue end

                ply.enemies[npc] = true
            end
        end
    end

    net.Start("rc_enemies")
    net.WriteTable(ply.enemies)
    net.Send(ply)
end)

local function writeVectorUncompressed(vector)
    net.WriteFloat(vector.x)
    net.WriteFloat(vector.y)
    net.WriteFloat(vector.z)
end

local function network_gunshot_event(data)
    if not enabled:GetBool() then return end

    for i, ply in ipairs(player.GetAll()) do
        local disp = -1
        if data.Entity:IsNPC() then
            disp = data.Entity:Disposition(ply)
        end
        net.Start("rc_entityfirebullets", false)
            writeVectorUncompressed(data.Src)
            writeVectorUncompressed(data.Dir)
            writeVectorUncompressed(data.Vel) -- velocity
            writeVectorUncompressed(data.Spread)
            net.WriteEntity(data.Entity) -- to exclude them in MP. they're going to get hook data anyway
            net.WriteEntity(data.Weapon)
            net.WriteInt(disp, 4)
        net.Send(ply)
    end
end

hook.Add("EntityFireBullets", "rc_EntityFireBullets", function(attacker, data)
    if not enabled:GetBool() then return end

    if data.Spread.z == 0.125 then return end -- for my blood decal workaround for mw sweps

    local entity = NULL
    local weapon = NULL
    local weaponIsWeird = false
    local isSuppressed = false

    if attacker:IsPlayer() or attacker:IsNPC() then
        entity = attacker
        weapon = entity:GetActiveWeapon()
    else
        weapon = attacker
        entity = weapon:GetOwner()
        if entity == NULL then 
            entity = attacker
            weaponIsWeird = true
        end
    end

    if not weaponIsWeird and weapon != NULL and entity.GetShootPos != nil then -- should solve all of the issues caused by external bullet sources (such as the turret mod)
        local weaponClass = weapon:GetClass()
        local entityShootPos = entity:GetShootPos()

        if weaponClass == "mg_arrow" then return end -- mw2019 sweps crossbow
        if weaponClass == "mg_sniper_bullet" and data.Spread == Vector(0,0,0) then return end -- physical bullets in mw2019
        if weaponClass == "mg_slug" and data.Spread == Vector(0,0,0) then return end -- physical bullets in mw2019

        if data.Distance < 200 then return end -- melee

        if string.StartWith(weaponClass, "arccw_") then
            if data.Distance == 20000 then -- grenade launchers in arccw
                return
            end
            if GetConVar("arccw_bullet_enable"):GetInt() == 1 and data.Spread == Vector(0, 0, 0) then -- bullet physics in arcw
                return
            end
        end

        if string.StartWith(weaponClass, "arc9_") then
            if GetConVar("arc9_bullet_physics"):GetInt() == 1 and data.Spread == Vector(0, 0, 0) then -- bullet physics in arc9
                return
            end
        end

        if game.GetTimeScale() < 1 and data.Spread == Vector(0,0,0) and data.Tracer == 0 then return end -- FEAR bullet time

        if entity.rc_shotThisTick == nil then entity.rc_shotThisTick = false end
        if entity.rc_shotThisTick then return end
        entity.rc_shotThisTick = true
        timer.Simple(engine.TickInterval()*2, function() entity.rc_shotThisTick = false end)
    end

    network_gunshot_event({
        Src = data.Src,
        Dir = data.Dir,
        Vel = Vector(0,0,0),
        Spread = data.Spread,
        Entity = entity,
        Weapon = weapon
    })
end)

function arc9_rc_detour(args)
    if not enabled:GetBool() then return end
    
    local bullet = args[2]
    local attacker = bullet.Attacker

    if attacker.rc_shotThisTick == nil then attacker.rc_shotThisTick = false end
    if attacker.rc_shotThisTick then return end
    if table.Count(bullet.Damaged) != 0 or bullet.rc_detected then return end

    local weapon = bullet.Weapon
    local weaponClass = weapon:GetClass()
    local pos = attacker:GetShootPos()
    local ammotype = bullet.Weapon.Primary.Ammo
    local dir = bullet.Vel:Angle():Forward()
    local vel = bullet.Vel

    timer.Simple(0, function()
        local data = {}
        data.Src = pos
        data.Dir = dir
        data.Vel = vel
        data.Spread = Vector(0,0,0)
        data.Entity = attacker
        data.Weapon = attacker:GetActiveWeapon()
        network_gunshot_event(data)
    end)
    bullet.rc_detected = true
    attacker.rc_shotThisTick = true

    timer.Simple(engine.TickInterval()*2, function() attacker.rc_shotThisTick = false end)
end

hook.Add("InitPostEntity", "rc_create_physbullet_hooks", function()
    if ARC9 then
        function rc_wrapfunction(a)    -- a = old function
          return function(...)
            local args = { ... }
            arc9_rc_detour(args)
            return a(...)
          end
        end
        ARC9.SendBullet = rc_wrapfunction(ARC9.SendBullet)
    end

    if TFA then
        hook.Add("Think", "rc_detecttfaphys", function()
            if not enabled:GetBool() then return end

            local latestPhysBullet = TFA.Ballistics.Bullets["bullet_registry"][table.Count(TFA.Ballistics.Bullets["bullet_registry"])]
            if latestPhysBullet == nil then return end
            if latestPhysBullet["rc_detected"] then return end

            local weapon = latestPhysBullet["inflictor"]
            local weaponClass = weapon:GetClass()

            local pos = latestPhysBullet["bul"]["Src"]
            local ammotype = weapon.Primary.Ammo
            local dir = latestPhysBullet["velocity"]:Angle():Forward()
            local vel = latestPhysBullet["velocity"]
            local entity = latestPhysBullet["inflictor"]:GetOwner()

            if entity.rc_shotThisTick == nil then entity.rc_shotThisTick = false end
            if entity.rc_shotThisTick then return end
            entity.rc_shotThisTick = true
            timer.Simple(engine.TickInterval()*2, function() entity.rc_shotThisTick = false end)

            local data = {}
            data.Src = pos
            data.Dir = dir
            data.Vel = vel
            data.Spread = Vector(0,0,0)
            data.Entity = latestPhysBullet["inflictor"]:GetOwner()
            data.Weapon = latestPhysBullet["inflictor"]
            network_gunshot_event(data)

            latestPhysBullet["rc_detected"] = true
        end)
    end

    if ArcCW then
        hook.Add("Think", "rc_detectarccwphys", function()
            if not enabled:GetBool() then return end

            if ArcCW.PhysBullets[table.Count(ArcCW.PhysBullets)] == nil then return end
            local latestPhysBullet = ArcCW.PhysBullets[table.Count(ArcCW.PhysBullets)]
            if latestPhysBullet["rc_detected"] then return end
            if latestPhysBullet["Attacker"] == Entity(0) then return end
            local entity = latestPhysBullet["Attacker"]

            if entity.rc_shotThisTick == nil then entity.rc_shotThisTick = false end
            if entity.rc_shotThisTick then return end
            entity.rc_shotThisTick = true
            timer.Simple(engine.TickInterval()*2, function() entity.rc_shotThisTick = false end)

            local weapon = latestPhysBullet["Weapon"]
            local weaponClass = weapon:GetClass()

            local pos = latestPhysBullet["Pos"]
            local ammotype = weapon.Primary.Ammo
            local dir = latestPhysBullet["Vel"]:Angle():Forward()
            local vel = latestPhysBullet["Vel"]

            local data = {}
            data.Src = pos
            data.Dir = dir
            data.Vel = vel
            data.Spread = Vector(0,0,0)
            data.Entity = latestPhysBullet["Attacker"]
            data.Weapon = latestPhysBullet["Attacker"]:GetActiveWeapon()
            network_gunshot_event(data)
            
            latestPhysBullet["rc_detected"] = true
        end)
    end

    if MW_ATTS then -- global var from mw2019 sweps
        hook.Add("OnEntityCreated", "rc_detectmw2019phys", function(ent)
            if ent:GetClass() != "mg_sniper_bullet" and ent:GetClass() != "mg_slug" then return end
            timer.Simple(0, function()
                local attacker = ent:GetOwner()
                local entity = attacker
                local weapon = attacker:GetActiveWeapon()
                local pos = ent.LastPos
                local dir = (ent:GetPos() - ent.LastPos):GetNormalized()
                local vel = ent:GetAngles():Forward() * ent.Projectile.Speed
                local ammotype = "none"
                if weapon.Primary and weapon.Primary.Ammo then ammotype = weapon.Primary.Ammo end

                if entity.rc_shotThisTick == nil then entity.rc_shotThisTick = false end
                if entity.rc_shotThisTick then return end
                entity.rc_shotThisTick = true
                timer.Simple(engine.TickInterval()*2, function() entity.rc_shotThisTick = false end)

                local data = {}
                data.Src = pos
                data.Dir = dir
                data.Vel = vel
                data.Spread = Vector(0,0,0)
                data.Entity = attacker
                data.Weapon = attacker:GetActiveWeapon()

                network_gunshot_event(data)
            end)
        end)
    end

    hook.Remove("InitPostEntity", "rc_create_physbullet_hooks")
end)
