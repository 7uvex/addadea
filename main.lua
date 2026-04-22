-- ============================================================
--  Street Life Remastered — Car Rob + Trash Farm Combined  v2.1
--  Place ID: 71600459831333
--
--  FIXES in v2.1:
--  • Sequence lock: car rob ALWAYS completes fully before trash
--    starts. DoCarRob waits until cars are loaded before running.
--  • Car counter bug: ProcessCar no longer counts skipped/failed
--    cars as successes. TpTo replaces StepWalkTo — no more silent
--    positioning failures that looked like success.
--  • Auto-start persistence: source re-captured at HOP time (not
--    just load time), so queue_on_teleport always gets the current
--    running code. Works across all hops reliably.
--  • Trash prompt spam: fires fireproximityprompt on every single
--    Heartbeat tick (fireEvery=0, no throttle). Confirmation only
--    marks done when the prompt's parent is destroyed or Enabled=false.
--  • PostHopStartDelay: 15s (was 25).
-- ============================================================

local LOADSTRING_URL = "https://raw.githubusercontent.com/7uvex/testy/refs/heads/main/main.lua"

-- ============================================================
--  PLACE ID GATE
-- ============================================================
local PLACE_ID = 71600459831333
if game.PlaceId ~= PLACE_ID then
    pcall(function()
        local sg=Instance.new("ScreenGui"); sg.Name="ComboWrongPlace"
        sg.Parent=game:GetService("CoreGui")
        local f=Instance.new("Frame",sg); f.Size=UDim2.new(0,280,0,60)
        f.Position=UDim2.new(0.5,-140,0,20); f.BackgroundColor3=Color3.fromRGB(18,18,20); f.BorderSizePixel=0
        Instance.new("UICorner",f).CornerRadius=UDim.new(0,8)
        local l=Instance.new("TextLabel",f); l.Size=UDim2.new(1,0,1,0); l.BackgroundTransparency=1
        l.Text="Combined Farm — wrong game\nSkipped (Place ID mismatch)"
        l.TextColor3=Color3.fromRGB(200,200,210); l.Font=Enum.Font.Gotham; l.TextSize=12
        task.delay(4,function() sg:Destroy() end)
    end)
    return
end

-- ============================================================
--  SELF-SOURCE CAPTURE  (re-called at hop time too)
-- ============================================================
local function CaptureSource()
    local src=nil
    pcall(function() if getscriptcontent then src=getscriptcontent() end end)
    if not src then
        pcall(function()
            if isfile and isfile("CarRobTrashCombined.lua") then
                src=readfile("CarRobTrashCombined.lua")
            end
        end)
    end
    return src
end
local SCRIPT_SRC=CaptureSource()

local function WriteAutoexec(src)
    if not src then return end
    local targets={
        "CarRobTrashCombined.lua",
        "autoexec/CarRobTrashCombined.lua",
        "autoexec\\CarRobTrashCombined.lua",
        "auto_exec/CarRobTrashCombined.lua",
        "workspace/autoexec/CarRobTrashCombined.lua",
    }
    for _,path in ipairs(targets) do
        pcall(function()
            local folder=path:match("^(.+)[/\\][^/\\]+$")
            if folder and isfolder and not isfolder(folder) then pcall(function() makefolder(folder) end) end
            if writefile then writefile(path,src) end
        end)
    end
end
WriteAutoexec(SCRIPT_SRC)

-- ============================================================
--  FLAGS
-- ============================================================
local ACTIVE_FLAG="ComboActive.flag"
local HOP_FLAG="ComboHopToggle.flag"
local TRASH_FLAG="ComboTrashToggle.flag"

local function WriteFlag(name,on)
    pcall(function() if writefile then writefile(name,on and "1" or "0") end end)
end
local function ReadFlag(name)
    local v=false
    pcall(function() if isfile and isfile(name) then v=readfile(name)=="1" end end)
    return v
end

local autoStart=ReadFlag(ACTIVE_FLAG)
local hopEnabled=ReadFlag(HOP_FLAG)
local trashEnabled=ReadFlag(TRASH_FLAG)

if _G.ComboAutoStart then
    _G.ComboAutoStart=nil; autoStart=true; WriteFlag(ACTIVE_FLAG,true)
end

-- ============================================================
--  SERVICES
-- ============================================================
local Players                = game:GetService("Players")
local UserInputService       = game:GetService("UserInputService")
local CoreGui                = game:GetService("CoreGui")
local TeleportService        = game:GetService("TeleportService")
local RunService             = game:GetService("RunService")
local ProximityPromptService = game:GetService("ProximityPromptService")
local LocalPlayer=Players.LocalPlayer

-- ============================================================
--  POSITIONS
-- ============================================================
local SAFE_POSITIONS={
    Vector3.new(561.21,52.43,-152.84), Vector3.new(444.73,52.41,-54.04),
    Vector3.new(761.87,52.43,-19.51),  Vector3.new(446.05,52.43,-269.80),
    Vector3.new(241.36,52.30,-422.35), Vector3.new(242.47,52.30,293.32),
    Vector3.new(332.19,52.30,-136.43),
}
local function NearestSafePos(worldPos)
    local best,bestD=SAFE_POSITIONS[1],math.huge
    for _,p in ipairs(SAFE_POSITIONS) do
        local d=(Vector3.new(p.X,0,p.Z)-Vector3.new(worldPos.X,0,worldPos.Z)).Magnitude
        if d<bestD then bestD=d; best=p end
    end
    return best
end

-- ============================================================
--  CONFIG
-- ============================================================
local S={
    FloatHeight=2.2, RaycastOffset=10, RaycastRange=20,
    SnapInterval=0.05, FireInterval=0.01, StayRadius=4.0,
    StayDuration=2.5, TpOffset=2.2, StandOffset=3.8,
    MaxCarRetries=4, SweepPasses=2, SweepPassWait=0.8,
    TrashDistances={2.5,3.5,4.5,5.5},
    TrashAngles={0,45,90,135,180,225,270,315},
    TrashStayDuration=3.5, TrashSearchDelay=0.05,
    CycleCooldown=4,
    PostHopStartDelay=15,  -- FIXED: was 25
    CarLoadWaitMax=20, CarLoadPollRate=1.0,
    AntiNoclipRayDown=6, AntiNoclipRayUp=2,
    AntiNoclipFloorSnapThresh=0.15, AntiNoclipVelThresh=80,
}

-- ============================================================
--  STATE
-- ============================================================
local Active=false; local farmLoopRunning=false
local cyclesCompleted=0; local totalHops=0
local OriginalCollisions={}

-- ============================================================
--  LOADING SCREEN SKIP
-- ============================================================
local function SkipLoadingScreen()
    local function fireSkipButtons(gui)
        for _,btn in ipairs(gui:GetDescendants()) do
            if btn:IsA("TextButton") or btn:IsA("ImageButton") then
                local t=(btn.Text or ""):lower(); local nm=btn.Name:lower()
                if t=="skip" or t=="x" or t=="close" or t=="play"
                or nm:find("skip") or nm:find("close") or nm=="x" or nm:find("exit") then
                    pcall(function() btn.MouseButton1Click:Fire() end)
                    pcall(function() btn.Activated:Fire() end)
                end
            end
        end
    end
    local function shouldKill(name)
        name=name:lower()
        return name:find("loading") or name:find("onboard") or name:find("daily")
            or name:find("reward")  or name:find("tutorial") or name:find("intro")
            or name:find("splash")  or name:find("welcome")  or name:find("cutscene")
            or name:find("street")
    end
    local function killGui(gui)
        task.wait(0.08); fireSkipButtons(gui); task.wait(0.15)
        pcall(function() gui.Enabled=false end); pcall(function() gui:Destroy() end)
    end
    local pg=LocalPlayer:FindFirstChild("PlayerGui")
    if pg then
        for _,gui in ipairs(pg:GetChildren()) do
            if gui:IsA("ScreenGui") and shouldKill(gui.Name) then task.spawn(killGui,gui) end
        end
    end
    task.spawn(function()
        local pg2=LocalPlayer:WaitForChild("PlayerGui",20); if not pg2 then return end
        pg2.ChildAdded:Connect(function(child)
            if child:IsA("ScreenGui") and shouldKill(child.Name) then task.spawn(killGui,child) end
        end)
        for _=1,160 do
            task.wait(0.5)
            for _,gui in ipairs(pg2:GetChildren()) do
                if gui:IsA("ScreenGui") and shouldKill(gui.Name) then task.spawn(killGui,gui) end
            end
        end
    end)
end
SkipLoadingScreen()

-- ============================================================
--  ANTI-NOCLIP
-- ============================================================
local antiNoclipSuspended=false
task.spawn(function()
    RunService.Heartbeat:Connect(function()
        if antiNoclipSuspended then return end
        local char=LocalPlayer.Character; if not char then return end
        local root=char:FindFirstChild("HumanoidRootPart"); if not root then return end
        for _,p in ipairs(char:GetDescendants()) do
            if p:IsA("BasePart") and not p.CanCollide then
                local n=p.Name
                if n=="HumanoidRootPart" or n=="Head" or n=="UpperTorso" or n=="LowerTorso"
                or n=="Torso" or n:find("Arm") or n:find("Leg") or n:find("Hand") or n:find("Foot") then
                    p.CanCollide=true
                end
            end
        end
        local params=RaycastParams.new()
        params.FilterType=Enum.RaycastFilterType.Blacklist
        params.FilterDescendantsInstances={char}
        local origin=root.Position+Vector3.new(0,S.AntiNoclipRayUp,0)
        local result=workspace:Raycast(origin,Vector3.new(0,-(S.AntiNoclipRayDown+S.AntiNoclipRayUp),0),params)
        if result then
            local floorY=result.Position.Y; local charBottom=root.Position.Y-3.0
            if charBottom<floorY-S.AntiNoclipFloorSnapThresh then
                local snapY=floorY+3.0+0.05
                root.CFrame=CFrame.new(Vector3.new(root.Position.X,snapY,root.Position.Z))
                    *(root.CFrame-root.CFrame.Position)
            end
        end
        local vel=root.AssemblyLinearVelocity
        if vel.Magnitude>S.AntiNoclipVelThresh then
            root.AssemblyLinearVelocity=vel.Unit*(S.AntiNoclipVelThresh*0.5)
        end
    end)
end)

-- ============================================================
--  GUI
-- ============================================================
local old=CoreGui:FindFirstChild("ComboFarmGUI"); if old then old:Destroy() end
local SG=Instance.new("ScreenGui"); SG.Name="ComboFarmGUI"; SG.ResetOnSpawn=false
SG.ZIndexBehavior=Enum.ZIndexBehavior.Sibling; SG.Parent=CoreGui

local mf=Instance.new("Frame",SG)
mf.Size=UDim2.new(0,340,0,455); mf.Position=UDim2.new(0.5,-170,0.5,-227)
mf.BackgroundColor3=Color3.fromRGB(10,10,12); mf.BorderSizePixel=0
Instance.new("UICorner",mf).CornerRadius=UDim.new(0,8)
do local s=Instance.new("UIStroke",mf); s.Color=Color3.fromRGB(30,30,34); s.Thickness=1 end

local tb=Instance.new("Frame",mf)
tb.Size=UDim2.new(1,0,0,44); tb.BackgroundColor3=Color3.fromRGB(14,14,17); tb.BorderSizePixel=0
Instance.new("UICorner",tb).CornerRadius=UDim.new(0,8)
do local d=Instance.new("Frame",tb); d.Size=UDim2.new(1,0,0,1); d.Position=UDim2.new(0,0,1,-1)
   d.BackgroundColor3=Color3.fromRGB(30,30,34); d.BorderSizePixel=0 end

local statusDot=Instance.new("Frame",tb)
statusDot.Size=UDim2.new(0,8,0,8); statusDot.Position=UDim2.new(0,16,0.5,-4)
statusDot.BackgroundColor3=Color3.fromRGB(100,100,110); statusDot.BorderSizePixel=0
Instance.new("UICorner",statusDot).CornerRadius=UDim.new(1,0)

do
    local t=Instance.new("TextLabel",tb); t.Size=UDim2.new(1,-100,1,0); t.Position=UDim2.new(0,32,0,0)
    t.BackgroundTransparency=1; t.Text="Car + Trash Combined"
    t.TextColor3=Color3.fromRGB(240,240,245); t.Font=Enum.Font.GothamMedium; t.TextSize=14
    t.TextXAlignment=Enum.TextXAlignment.Left
    local v=Instance.new("TextLabel",tb); v.Size=UDim2.new(0,50,1,0); v.Position=UDim2.new(1,-80,0,0)
    v.BackgroundTransparency=1; v.Text="v2.1"
    v.TextColor3=Color3.fromRGB(100,100,110); v.Font=Enum.Font.Gotham; v.TextSize=11
    v.TextXAlignment=Enum.TextXAlignment.Right
end

local closeBtn=Instance.new("TextButton",tb)
closeBtn.Size=UDim2.new(0,28,0,28); closeBtn.Position=UDim2.new(1,-34,0.5,-14)
closeBtn.Text="×"; closeBtn.TextColor3=Color3.fromRGB(160,160,170)
closeBtn.BackgroundColor3=Color3.fromRGB(22,22,26); closeBtn.BorderSizePixel=0
closeBtn.Font=Enum.Font.GothamMedium; closeBtn.TextSize=16
Instance.new("UICorner",closeBtn).CornerRadius=UDim.new(0,6)
closeBtn.MouseButton1Click:Connect(function() WriteFlag(ACTIVE_FLAG,false); Active=false; SG:Destroy() end)

local content=Instance.new("Frame",mf)
content.Size=UDim2.new(1,-24,1,-210); content.Position=UDim2.new(0,12,0,54)
content.BackgroundTransparency=1

local rowY=0
local function MkRow(label,valCol)
    local r=Instance.new("Frame",content); r.Size=UDim2.new(1,0,0,22); r.Position=UDim2.new(0,0,0,rowY)
    r.BackgroundTransparency=1; rowY=rowY+24
    local l=Instance.new("TextLabel",r); l.Size=UDim2.new(0.45,0,1,0); l.BackgroundTransparency=1
    l.Text=label; l.TextColor3=Color3.fromRGB(120,120,130); l.Font=Enum.Font.Gotham; l.TextSize=11
    l.TextXAlignment=Enum.TextXAlignment.Left
    local v=Instance.new("TextLabel",r); v.Size=UDim2.new(0.55,0,1,0); v.Position=UDim2.new(0.45,0,0,0)
    v.BackgroundTransparency=1; v.Text="—"; v.TextColor3=valCol or Color3.fromRGB(230,230,235)
    v.Font=Enum.Font.GothamMedium; v.TextSize=11; v.TextXAlignment=Enum.TextXAlignment.Right
    return v
end

local valStage  =MkRow("Stage",   Color3.fromRGB(120,180,255))
local valPhase  =MkRow("Phase",   Color3.fromRGB(120,180,255))
local valStatus =MkRow("Status",  Color3.fromRGB(230,230,235))
local valCars   =MkRow("Cars",    Color3.fromRGB(230,230,235))
local valTrash  =MkRow("Trash",   Color3.fromRGB(230,230,235))
local valCycles =MkRow("Cycles/Hops",Color3.fromRGB(230,230,235))
local valCurrent=MkRow("Current", Color3.fromRGB(230,230,235))
local valAction =MkRow("Action",  Color3.fromRGB(255,200,100))
local valMove   =MkRow("Move",    Color3.fromRGB(120,220,160))
local valHop    =MkRow("Hop method",Color3.fromRGB(160,160,170))

valStage.Text="Idle"; valPhase.Text="Idle"; valStatus.Text="Ready"
valCars.Text="0"; valTrash.Text="0"; valCycles.Text="0 / 0"
valCurrent.Text="—"; valAction.Text="—"; valMove.Text="—"; valHop.Text="Not attempted"

local function MkToggleRow(labelText,initialState,yFromBottom,onToggle)
    local row=Instance.new("Frame",mf); row.Size=UDim2.new(1,-24,0,32)
    row.Position=UDim2.new(0,12,1,-yFromBottom)
    row.BackgroundColor3=Color3.fromRGB(14,14,17); row.BorderSizePixel=0
    Instance.new("UICorner",row).CornerRadius=UDim.new(0,6)
    do local s=Instance.new("UIStroke",row); s.Color=Color3.fromRGB(30,30,34); s.Thickness=1 end
    local lbl=Instance.new("TextLabel",row); lbl.Size=UDim2.new(0.65,0,1,0); lbl.Position=UDim2.new(0,12,0,0)
    lbl.BackgroundTransparency=1; lbl.Text=labelText; lbl.TextColor3=Color3.fromRGB(200,200,210)
    lbl.Font=Enum.Font.GothamMedium; lbl.TextSize=11; lbl.TextXAlignment=Enum.TextXAlignment.Left
    local toggle=Instance.new("TextButton",row); toggle.Size=UDim2.new(0,52,0,22)
    toggle.Position=UDim2.new(1,-64,0.5,-11); toggle.BorderSizePixel=0
    toggle.Font=Enum.Font.GothamBold; toggle.TextSize=11; toggle.AutoButtonColor=false
    Instance.new("UICorner",toggle).CornerRadius=UDim.new(0,4)
    local state=initialState
    local function applyVisual()
        toggle.Text=state and "ON" or "OFF"
        toggle.TextColor3=state and Color3.fromRGB(18,18,22) or Color3.fromRGB(230,230,235)
        toggle.BackgroundColor3=state and Color3.fromRGB(120,220,160) or Color3.fromRGB(22,22,26)
        for _,c in ipairs(toggle:GetChildren()) do if c:IsA("UIStroke") then c:Destroy() end end
        if not state then local s=Instance.new("UIStroke",toggle); s.Color=Color3.fromRGB(34,34,38); s.Thickness=1 end
    end
    applyVisual()
    toggle.MouseButton1Click:Connect(function() state=not state; applyVisual(); if onToggle then onToggle(state) end end)
end

MkToggleRow("Trash Farm (after cars)",trashEnabled,140,function(s) trashEnabled=s; WriteFlag(TRASH_FLAG,s) end)
MkToggleRow("Server Hop after cycle", hopEnabled,  104,function(s) hopEnabled=s;   WriteFlag(HOP_FLAG,s)   end)

local btnRow=Instance.new("Frame",mf); btnRow.Size=UDim2.new(1,-24,0,36); btnRow.Position=UDim2.new(0,12,1,-52)
btnRow.BackgroundTransparency=1
local function MkBtn(text,primary,xOff)
    local b=Instance.new("TextButton",btnRow); b.Size=UDim2.new(0,146,1,0); b.Position=UDim2.new(0,xOff,0,0)
    b.Text=text; b.TextColor3=primary and Color3.fromRGB(18,18,22) or Color3.fromRGB(230,230,235)
    b.BackgroundColor3=primary and Color3.fromRGB(240,240,245) or Color3.fromRGB(22,22,26)
    b.BorderSizePixel=0; b.Font=Enum.Font.GothamBold; b.TextSize=11; b.AutoButtonColor=false
    Instance.new("UICorner",b).CornerRadius=UDim.new(0,6)
    if not primary then local s=Instance.new("UIStroke",b); s.Color=Color3.fromRGB(34,34,38); s.Thickness=1 end
    return b
end
local startBtn=MkBtn("START",true,0); local stopBtn=MkBtn("STOP",false,154)

do
    local drag,ds,sp=false,nil,nil
    tb.InputBegan:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 then drag=true; ds=i.Position; sp=mf.Position end end)
    UserInputService.InputChanged:Connect(function(i) if drag and i.UserInputType==Enum.UserInputType.MouseMovement then local d=i.Position-ds; mf.Position=UDim2.new(sp.X.Scale,sp.X.Offset+d.X,sp.Y.Scale,sp.Y.Offset+d.Y) end end)
    UserInputService.InputEnded:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 then drag=false end end)
end

local function SetDot(col) statusDot.BackgroundColor3=col end

-- ============================================================
--  NOCLIP
-- ============================================================
local function EnableNoclip()
    antiNoclipSuspended=true
    local char=LocalPlayer.Character; if not char then return end
    for _,p in ipairs(char:GetDescendants()) do
        if p:IsA("BasePart") and p.CanCollide then OriginalCollisions[p]=p.CanCollide; p.CanCollide=false end
    end
end
local function DisableNoclip()
    for p,c in pairs(OriginalCollisions) do pcall(function() if p and p.Parent then p.CanCollide=c end end) end
    OriginalCollisions={}; antiNoclipSuspended=false
end

-- ============================================================
--  MOVEMENT
-- ============================================================
local function GetGroundHeight(pos)
    local char=LocalPlayer.Character
    local params=RaycastParams.new(); params.FilterType=Enum.RaycastFilterType.Blacklist
    if char then params.FilterDescendantsInstances={char} end
    local result=workspace:Raycast(pos+Vector3.new(0,S.RaycastOffset,0),Vector3.new(0,-S.RaycastRange,0),params)
    if result then return result.Position.Y+S.FloatHeight end
    return pos.Y
end

-- Direct teleport — replaces StepWalkTo to eliminate silent positioning failures
local function TpTo(pos,label)
    local char=LocalPlayer.Character; if not char then return false end
    local root=char:FindFirstChild("HumanoidRootPart"); if not root then return false end
    local hum=char:FindFirstChildWhichIsA("Humanoid")
    valMove.Text="TP→"..(label or "?")
    if hum then hum.PlatformStand=true end
    EnableNoclip()
    root.CFrame=CFrame.new(pos)
    task.wait(0.12)
    DisableNoclip()
    if hum then hum.PlatformStand=false end
    task.wait(0.06)
    local arrived=(root.Position-pos).Magnitude<10
    valMove.Text=arrived and ("At "..(label or "?")) or ("Miss "..(label or "?"))
    return arrived
end

-- ============================================================
--  PROMPT HELPERS
-- ============================================================
local function PrepPrompt(p)
    if not p then return end
    pcall(function() p.HoldDuration=0; p.RequiresLineOfSight=false end)
end
local function PromptExists(p) return p~=nil and p.Parent~=nil and p.Enabled end

-- HoldAndFire: snap position every SnapInterval, fire every fireEvery seconds.
-- For trash: pass fireEvery=0 to fire every single Heartbeat tick.
local function HoldAndFire(prompt,standPos,confirmFn,label,duration,fireEvery)
    duration=duration or S.StayDuration
    fireEvery=fireEvery or S.FireInterval
    if not prompt or not prompt.Parent then return false end
    PrepPrompt(prompt)
    local char=LocalPlayer.Character; if not char then return false end
    local root=char:FindFirstChild("HumanoidRootPart"); if not root then return false end
    local deadline=os.clock()+duration
    local lastSnap,lastFire=0,0
    valAction.Text=label
    while os.clock()<deadline and Active do
        local now=os.clock()
        if now-lastSnap>=S.SnapInterval then
            lastSnap=now
            if (root.Position-standPos).Magnitude>S.StayRadius then
                EnableNoclip(); root.CFrame=CFrame.new(standPos); task.wait(0.02); DisableNoclip()
            end
        end
        if now-lastFire>=fireEvery then
            lastFire=now
            if not prompt.Parent then break end
            pcall(function() fireproximityprompt(prompt) end)
            pcall(function() prompt:InputHoldBegin() end)
            pcall(function() prompt:InputHoldEnd() end)
        end
        if confirmFn(prompt) then valAction.Text="✓ "..label; return true end
        RunService.Heartbeat:Wait()
    end
    valAction.Text="✗ "..label
    return confirmFn(prompt)
end

-- ============================================================
--  GLOBAL PROMPT HOOK
-- ============================================================
local HookEnabled=true; local promptFired={}
local function IsFarmPrompt(p)
    if not p then return false end
    local c=((p.ObjectText or "")..(p.ActionText or "")..(p.Name or "")):lower()
    return c:find("search") or c:find("trash") or c:find("grab") or c:find("cash")
end
ProximityPromptService.PromptShown:Connect(function(prompt,_)
    if not HookEnabled or not IsFarmPrompt(prompt) or promptFired[prompt] then return end
    PrepPrompt(prompt); promptFired[prompt]=true
    pcall(function() fireproximityprompt(prompt) end)
    local c; c=prompt.PromptHidden:Connect(function() promptFired[prompt]=nil; c:Disconnect() end)
end)
ProximityPromptService.PromptButtonHoldBegan:Connect(function(prompt,player)
    if not HookEnabled or player~=LocalPlayer or not IsFarmPrompt(prompt) then return end
    PrepPrompt(prompt); pcall(function() fireproximityprompt(prompt) end)
end)

-- ============================================================
--  CAR ROB
-- ============================================================
local function GetCarPrompt(carModel)
    local window=carModel:FindFirstChild("Window"); if not window then return nil,nil end
    local hPart=window:FindFirstChild("H")
    if not hPart or not hPart:IsA("BasePart") then return nil,nil end
    for _,c in ipairs(hPart:GetChildren()) do
        if c:IsA("ProximityPrompt") then PrepPrompt(c); return c,hPart end
    end
    return nil,nil
end

local function IsGrabCash(p)
    if not p then return false end
    local ot=(p.ObjectText or ""):lower()
    return ot:find("grab")~=nil or ot:find("cash")~=nil
end
local function IsGlassBroken(p) return not PromptExists(p) or IsGrabCash(p) end
local function IsCashGrabbed(p) return not PromptExists(p) or not IsGrabCash(p) end

local function FindAllCars()
    local cars={}; local seen={}
    for _,obj in ipairs(workspace:GetDescendants()) do
        if obj:IsA("Folder") and obj.Name=="Interactions" then
            for _,child in ipairs(obj:GetChildren()) do
                if child:IsA("Model") and child.Name=="Car Rob" and not seen[child] then
                    seen[child]=true; table.insert(cars,child)
                end
            end
        end
    end
    for _,obj in ipairs(workspace:GetDescendants()) do
        if obj:IsA("Model") and obj.Name=="Car Rob" and not seen[obj] then
            seen[obj]=true; table.insert(cars,obj)
        end
    end
    valCars.Text=tostring(#cars); return cars
end

-- Wait for cars to actually appear in workspace after a server hop
local function WaitForCars()
    local t0=os.clock()
    while os.clock()-t0<S.CarLoadWaitMax do
        local c=FindAllCars(); if #c>0 then return c end
        valStatus.Text="Waiting for cars to load…"; task.wait(S.CarLoadPollRate)
    end
    return FindAllCars()
end

local function ComputeStandPos(hPart)
    local hCF=hPart.CFrame; local hPos=hCF.Position
    local outsideXZ=hPos+hCF.LookVector*S.StandOffset
    local groundY=GetGroundHeight(outsideXZ)
    local standPos=Vector3.new(outsideXZ.X,groundY,outsideXZ.Z)
    if (standPos-hPos).Magnitude>12 then
        local safe=NearestSafePos(hPos)
        groundY=GetGroundHeight(Vector3.new(safe.X,0,safe.Z))
        standPos=Vector3.new(safe.X,groundY,safe.Z)
    end
    return standPos
end

local function WalkToWindow(hPart)
    local standPos=ComputeStandPos(hPart)
    local arrived=TpTo(standPos,"window")
    if not arrived then return nil end
    local char=LocalPlayer.Character; if not char then return nil end
    local root=char:FindFirstChild("HumanoidRootPart"); if not root then return nil end
    if (root.Position-hPart.Position).Magnitude>9 then return nil end
    return standPos
end

local function ProcessCar(car,carIdx,totalCars)
    local prompt,hPart=GetCarPrompt(car)
    if not prompt or not hPart then return "skipped" end
    if not PromptExists(prompt) then return "skipped" end
    local skipBreak=IsGrabCash(prompt)
    for attempt=1,S.MaxCarRetries do
        if not Active then return "failed" end
        valCurrent.Text=string.format("%s (%d/%d) [%d]",car.Name,carIdx,totalCars,attempt)
        valStatus.Text=string.format("Teleporting (attempt %d)",attempt)
        local standPos=WalkToWindow(hPart)
        if not standPos then valStatus.Text="Can't reach — retry"; task.wait(0.25); continue end
        if not skipBreak then
            valStatus.Text="Breaking glass…"
            if not HoldAndFire(prompt,standPos,IsGlassBroken,"BREAK",S.StayDuration) then
                valStatus.Text=string.format("Break failed (%d/%d)",attempt,S.MaxCarRetries)
                task.wait(0.2); continue
            end
        end
        prompt,_=GetCarPrompt(car)
        if not prompt then return "success" end
        local waited=0
        while waited<1.0 and PromptExists(prompt) and not IsGrabCash(prompt) do task.wait(0.05); waited=waited+0.05 end
        if not PromptExists(prompt) then return "success" end
        if not IsGrabCash(prompt) then skipBreak=false; task.wait(0.2); continue end
        valStatus.Text="Grabbing cash…"
        standPos=WalkToWindow(hPart) or standPos
        if HoldAndFire(prompt,standPos,IsCashGrabbed,"GRAB",S.StayDuration) then return "success" end
        skipBreak=true; task.wait(0.2)
    end
    return "failed"
end

local function CashSweep(passNum)
    valPhase.Text=string.format("Sweep %d/%d",passNum,S.SweepPasses); SetDot(Color3.fromRGB(255,220,80))
    local swept=0; local allCars=FindAllCars()
    for i,car in ipairs(allCars) do
        if not Active then break end
        local prompt,hPart=GetCarPrompt(car)
        if prompt and hPart and PromptExists(prompt) and IsGrabCash(prompt) then
            valCurrent.Text=string.format("Sweep %d: %s",passNum,car.Name)
            local standPos=WalkToWindow(hPart)
            if standPos and HoldAndFire(prompt,standPos,IsCashGrabbed,"GRAB",S.StayDuration) then swept=swept+1 end
        end
    end
    valStatus.Text=string.format("Sweep %d done +%d",passNum,swept); return swept
end

-- SEQUENCE GUARD: always waits for world load, always completes all passes.
local function DoCarRob()
    valStage.Text="Car Rob"; SetDot(Color3.fromRGB(120,180,255)); valPhase.Text="Waiting for cars"
    local cars=WaitForCars()
    if #cars==0 then valStatus.Text="No cars found — skipping"; task.wait(1); return false end
    valStatus.Text=string.format("%d cars found",#cars); task.wait(0.3)
    local successCount=0; local failedCars={}
    valPhase.Text="Main pass"
    for i,car in ipairs(cars) do
        if not Active then break end
        valStatus.Text=string.format("Car %d/%d (✓%d)",i,#cars,successCount)
        local result=ProcessCar(car,i,#cars)
        -- FIXED: only count actual successes
        if result=="success" then successCount=successCount+1
        elseif result=="failed" then table.insert(failedCars,car)
        end -- "skipped" is ignored
        task.wait(0.08)
    end
    if #failedCars>0 and Active then
        valPhase.Text="Mop-up"; valStatus.Text=string.format("Mopping %d cars",#failedCars); task.wait(0.3)
        for i,car in ipairs(failedCars) do
            if not Active then break end
            valCurrent.Text=string.format("Mop: %s",car.Name)
            if ProcessCar(car,i,#failedCars)=="success" then successCount=successCount+1 end
            task.wait(0.08)
        end
    end
    if Active then
        for pass=1,S.SweepPasses do
            if not Active then break end; task.wait(S.SweepPassWait); successCount=successCount+CashSweep(pass)
        end
    end
    valStatus.Text=string.format("✓ Car rob done (%d)",successCount)
    valCurrent.Text="—"; valAction.Text="—"; valMove.Text="—"
    return true
end

-- ============================================================
--  TRASH FARM
-- ============================================================
local function IsTrashPrompt(p)
    if not p then return false end
    local name=(p.Name or ""):lower(); local objText=(p.ObjectText or ""):lower()
    local actText=(p.ActionText or ""):lower(); local combined=name..objText..actText
    if combined:find("buy") or combined:find("purchase") or combined:find("shop") then return false end
    return combined:find("search") or combined:find("trash")
end

local function FindAllTrash()
    local found={}; local seen={}
    for _,obj in ipairs(workspace:GetDescendants()) do
        if obj:IsA("ProximityPrompt") and not seen[obj] and IsTrashPrompt(obj) and obj.Enabled then
            local part=obj.Parent
            if part and part:IsA("BasePart") then seen[obj]=true; table.insert(found,{prompt=obj,part=part,pos=part.Position}) end
        end
    end
    valTrash.Text=tostring(#found); return found
end

local function IsPositionClipping(pos)
    local params=RaycastParams.new(); params.FilterType=Enum.RaycastFilterType.Blacklist
    local char=LocalPlayer.Character; if char then params.FilterDescendantsInstances={char} end
    for _,dir in ipairs({Vector3.new(1,0,0),Vector3.new(-1,0,0),Vector3.new(0,0,1),Vector3.new(0,0,-1)}) do
        local r=workspace:Raycast(pos,dir,params)
        if r and (r.Position-pos).Magnitude<0.8 then return true end
    end
    return false
end

local function GetTrashStandPositions(trashPos)
    local positions={}; local char=LocalPlayer.Character
    for _,dist in ipairs(S.TrashDistances) do
        for _,angle in ipairs(S.TrashAngles) do
            local rad=math.rad(angle)
            local offset=Vector3.new(math.cos(rad)*dist,0,math.sin(rad)*dist)
            local candidate=trashPos+offset
            local params=RaycastParams.new(); params.FilterType=Enum.RaycastFilterType.Blacklist
            if char then params.FilterDescendantsInstances={char} end
            local ray=workspace:Raycast(candidate+Vector3.new(0,8,0),Vector3.new(0,-20,0),params)
            local groundY=ray and (ray.Position.Y+S.TpOffset) or (trashPos.Y+S.TpOffset)
            table.insert(positions,Vector3.new(candidate.X,groundY,candidate.Z))
        end
    end
    for i=#positions,2,-1 do local j=math.random(i); positions[i],positions[j]=positions[j],positions[i] end
    return positions
end

-- FIXED: only marks done when prompt is actually destroyed/disabled
local function IsTrashDone(prompt)
    if not prompt then return true end
    if not prompt.Parent then return true end
    if not prompt.Enabled then return true end
    return false
end

local function InteractWithTrash(trashData,idx,total)
    local prompt=trashData.prompt; local trashPos=trashData.pos
    if IsTrashDone(prompt) then return true end
    local positions=GetTrashStandPositions(trashPos)
    for _,standPos in ipairs(positions) do
        if not Active then return false end
        if IsTrashDone(prompt) then return true end
        if IsPositionClipping(standPos) then task.wait(0.01); continue end
        TpTo(standPos,string.format("trash%d",idx)); task.wait(0.04)
        local char=LocalPlayer.Character; local root=char and char:FindFirstChild("HumanoidRootPart")
        if not root then continue end
        if (root.Position-trashPos).Magnitude>9 then continue end
        valCurrent.Text=string.format("Trash %d/%d",idx,total)
        valStatus.Text=string.format("Searching %d/%d…",idx,total)
        -- FIXED: fireEvery=0 — fires on every single Heartbeat tick, no throttle
        local ok=HoldAndFire(prompt,standPos,IsTrashDone,
            string.format("Search %d",idx),S.TrashStayDuration,0)
        if ok then valStatus.Text=string.format("✓ Trash %d/%d",idx,total); return true end
        task.wait(0.03)
    end
    valStatus.Text=string.format("✗ Trash %d/%d",idx,total); return false
end

local function DoTrashFarm()
    valStage.Text="Trash Farm"; SetDot(Color3.fromRGB(180,120,255)); valPhase.Text="Scanning"
    local trashList=FindAllTrash()
    if #trashList==0 then valStatus.Text="No trash found"; task.wait(1); return false end
    valPhase.Text="Searching"; local done=0; local failed={}
    for i,t in ipairs(trashList) do
        if not Active then break end
        if InteractWithTrash(t,i,#trashList) then done=done+1 else table.insert(failed,t) end
        task.wait(S.TrashSearchDelay)
    end
    if #failed>0 and Active then
        valPhase.Text="Trash mop-up"
        for i,t in ipairs(failed) do
            if not Active then break end
            if InteractWithTrash(t,i,#failed) then done=done+1 end
            task.wait(S.TrashSearchDelay)
        end
    end
    valStatus.Text=string.format("✓ Trash done (%d/%d)",done,#trashList)
    valCurrent.Text="—"; valAction.Text="—"; valMove.Text="—"; return true
end

-- ============================================================
--  SERVER HOP — source re-captured at hop time
-- ============================================================
local function ServerHop()
    totalHops=totalHops+1
    valCycles.Text=string.format("%d / %d",cyclesCompleted,totalHops)
    valStage.Text="Hopping"; valPhase.Text="Queuing"; SetDot(Color3.fromRGB(200,150,255))
    WriteFlag(ACTIVE_FLAG,true)
    -- FIXED: re-capture source at hop time (not stale load-time capture)
    local src=CaptureSource() or SCRIPT_SRC
    if src then SCRIPT_SRC=src end
    local methods={}
    -- Tier 1: embedded source
    if src then
        local p='_G.ComboAutoStart=true\n'..src
        pcall(function() if queue_on_teleport then queue_on_teleport(p); table.insert(methods,"QoT+src") end end)
        pcall(function() if syn and syn.queue_on_teleport then syn.queue_on_teleport(p); table.insert(methods,"syn+src") end end)
        WriteAutoexec(src)
    end
    -- Tier 2: URL
    if LOADSTRING_URL~="" and not LOADSTRING_URL:find("PASTE_") then
        local p2=string.format('_G.ComboAutoStart=true; loadstring(game:HttpGet("%s"))()',LOADSTRING_URL)
        pcall(function() if queue_on_teleport then queue_on_teleport(p2); table.insert(methods,"QoT+URL") end end)
        pcall(function() if syn and syn.queue_on_teleport then syn.queue_on_teleport(p2); table.insert(methods,"syn+URL") end end)
    end
    table.insert(methods,"flag")
    valHop.Text=table.concat(methods,", ")
    valHop.TextColor3=#methods>1 and Color3.fromRGB(120,220,160) or Color3.fromRGB(255,180,60)
    valStatus.Text="Teleporting…"; task.wait(0.5)
    local ok=pcall(function() TeleportService:Teleport(PLACE_ID,LocalPlayer) end)
    if not ok then pcall(function() TeleportService:TeleportToPlaceInstance(PLACE_ID,game.JobId,LocalPlayer) end) end
    task.wait(10); valStatus.Text="Hop failed — continuing"
end

-- ============================================================
--  MAIN LOOP  — STRICTLY SEQUENTIAL: car → trash → hop
-- ============================================================
local function MainLoop()
    if farmLoopRunning then return end
    farmLoopRunning=true
    while Active do
        valCycles.Text=string.format("%d / %d",cyclesCompleted,totalHops)
        -- STAGE 1: Car rob — MUST complete before anything else
        DoCarRob()
        if not Active then break end
        -- STAGE 2: Trash — only after car rob fully done
        if trashEnabled then
            DoTrashFarm()
            if not Active then break end
        else
            valStage.Text="Trash: off"; task.wait(0.3)
        end
        -- Cycle complete
        cyclesCompleted=cyclesCompleted+1
        valCycles.Text=string.format("%d / %d",cyclesCompleted,totalHops)
        valStage.Text="Cycle done"; valPhase.Text="Cooldown"; SetDot(Color3.fromRGB(100,100,110))
        valStatus.Text=string.format("Cycle %d complete",cyclesCompleted)
        if not Active then break end
        -- STAGE 3: Hop — only after trash fully done
        if hopEnabled then
            task.wait(1); ServerHop(); task.wait(2)
        else
            for i=S.CycleCooldown,1,-1 do
                if not Active then break end
                valStatus.Text=string.format("Next in %ds…",i); task.wait(1)
            end
        end
    end
    DisableNoclip(); farmLoopRunning=false
    valStage.Text="Idle"; valPhase.Text="Idle"; SetDot(Color3.fromRGB(100,100,110))
    valStatus.Text="Stopped"; valCurrent.Text="—"; valAction.Text="—"; valMove.Text="—"
end

-- ============================================================
--  BUTTONS
-- ============================================================
local function StartFarm()
    if Active then return end
    Active=true; WriteFlag(ACTIVE_FLAG,true)
    startBtn.Text="RUNNING"; startBtn.BackgroundColor3=Color3.fromRGB(120,220,160)
    valStatus.Text="Starting…"; SetDot(Color3.fromRGB(120,220,160)); task.spawn(MainLoop)
end
local function StopFarm()
    Active=false; WriteFlag(ACTIVE_FLAG,false); DisableNoclip()
    startBtn.Text="START"; startBtn.BackgroundColor3=Color3.fromRGB(240,240,245)
    valStatus.Text="Stopped"; SetDot(Color3.fromRGB(100,100,110))
    valCurrent.Text="—"; valAction.Text="—"; valMove.Text="—"
end
startBtn.MouseButton1Click:Connect(StartFarm)
stopBtn.MouseButton1Click:Connect(StopFarm)

-- ============================================================
--  AUTO-START POST-HOP  (15s wait, FIXED from 25)
-- ============================================================
task.wait(0.5); FindAllCars()

if autoStart then
    task.spawn(function()
        valStage.Text="Post-hop wait"; valPhase.Text="Loading"; SetDot(Color3.fromRGB(255,180,60))
        for i=S.PostHopStartDelay,1,-1 do
            valStatus.Text=string.format("Auto-start in %ds…",i); task.wait(1)
        end
        local t0=os.clock()
        while os.clock()-t0<20 do
            if #FindAllCars()>0 then break end; task.wait(1)
        end
        valStatus.Text="✓ Auto-starting"; task.wait(0.5)
        if not Active then StartFarm() end
    end)
end

print("══════════════════════════════")
print(" Car + Trash Combined v2.1")
print(" FIXED: sequence lock, counter, trash spam, 15s start, hop persistence")
print("══════════════════════════════")
