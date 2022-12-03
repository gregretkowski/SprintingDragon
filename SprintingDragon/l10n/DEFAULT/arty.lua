--local RU_MLRS_NAMES = {}
local RU_ARTY_NAMES = {"PLAN_SPH", "PLAN_2S9"}
--local US_ARTY_NAMES = {}
local US_ARTY_NAMES = {"ROC_M109", "ROC_120mm"}

local DANGER_CLOSE_RANGE_METERS = 500

ARTY:SetDebugOFF()
ARTY:SetReportOFF()
ARTY:SetMarkAssignmentsOn()
local allArties = {}
local allRedArties = {}
local allBlueArties ={}

-- create RU artillery
local ruArtyCount = 1
for _, unit in ipairs(RU_ARTY_NAMES) do
    local name = "msta" .. tostring(ruArtyCount)
    local arty = ARTY:New(unit, name):AddToCluster("ru_arty")
    table.insert(allArties, arty)
    table.insert(allRedArties, arty)
    ruArtyCount = ruArtyCount + 1
end


-- create US artillery
local usArtyCount = 1
for _, unit in ipairs(US_ARTY_NAMES) do
    local name = "us" .. tostring(usArtyCount)
    local arty = ARTY:New(unit, name):AddToCluster("us_arty")
    table.insert(allArties, arty)
    table.insert(allBlueArties, arty)
    usArtyCount = usArtyCount + 1
end


-- start arties
for _, arty in ipairs(allArties) do
    arty:Start()
end

-- automatic red artillery
local function copyTable(sourceTable)
    tableCopy = {}
    for orig_key, orig_value in pairs(sourceTable) do
        tableCopy[orig_key] = orig_value
    end
    return tableCopy
end

local function valuesToArray(tab)
    local arr = {}
    for k, v in pairs(tab) do
        table.insert(arr, v)
    end
    return arr
end

local function keysToArray(tab)
    local arr = {}
    for k, v in pairs(tab) do
        table.insert(arr, k)
    end
    return arr
end

function selectRandom(t)
    return t[math.random(1, #t)]
end
 

local function artyDetectionStateMachine(side, arties)
    local ARTY_DETECT_STATE = {
        PREP_UNIT_ARRAYS = 0,
        FETCHING_DETECTION_UNITS = 1,
        ASSIGN_FIRE_MISSIONS = 2
    }
    

    local otherSide = nil
    if side == coalition.side.BLUE then
        otherSide = coalition.side.RED
    else
        otherSide = coalition.side.BLUE
    end

    local unitIndex = 1
    local allUnits = {}
    local detectedUnits = {}

    local state = ARTY_DETECT_STATE.PREP_UNIT_ARRAYS

    local function prepUnitArray()
        allUnits = {}
        for _, unit in pairs(_DATABASE.UNITS) do
            if unit:GetCoalition() == side then
                table.insert(allUnits, unit)
            end
        end
        state = ARTY_DETECT_STATE.FETCHING_DETECTION_UNITS
        detectedUnits = {}
        return 1
    end

    local ARTY_RANGES_BY_TYPE = {
        ["SAU Msta"] = {30, 23500},
        ["SAU Gvozdika"] = {30, 15000},
        ["Smerch_HE"] = {20000, 70000},
        ["SAU 2-C9"] = {30, 15000},
        ["SAU Akatsia"] = {30, 17000},
        ["T155_Firtina"] = {30, 41000},
        ["M-109"] = {30, 22000},
        ["MLRS"] = {10000, 32000},
        ["Grad-URAL"] = {5000, 19000},
        ["Uragan_BM-27"] = {11500, 35800},
        ["SpGH_Dana"] = {30, 18500},
        ["2B11 mortar"] = {30, 6500},
        ["PLZ05"] = {60, 22000},
    }
    
    local function isWithinRange(unit, artyGroup)
        local units = artyGroup:GetUnits()
        if not units then
            return false
        end
        
        local artyRange = nil
        local unitIdx = 1
        while artyRange == nil and unitIdx < #units do
            local unit = units[unitIndex]
            artyRange = ARTY_RANGES_BY_TYPE[unit:GetTypeName()]
        end
        if artyRange == nil then
            return false
        end
        local minRange = artyRange[1]
        local maxRange = artyRange[2]
        local unitPos = unit:GetCoordinate()
        local artyPos = artyGroup:GetUnit(1):GetCoordinate()
        local distance = artyPos:Get2DDistance(unitPos)
        return distance >= minRange and distance <= maxRange
    end

    local function assignFireMission(arty, detectedUnitIds)
        local candidateUnitsIds = copyTable(detectedUnitIds)

        local artyGroup = GROUP:FindByName(arty.groupname)
        if not artyGroup then
            return
        end

        while #candidateUnitsIds > 0 do
            local idx = math.random(1, #candidateUnitsIds)
            local unit = detectedUnits[candidateUnitsIds[idx]]
            if isWithinRange(unit, artyGroup) then
                env.info("Assigning automatic fire mission for " .. arty.groupname .. " targeting " .. unit:GetName())
                arty:AssignTargetCoord(unit:GetCoordinate(), 100, 100, 20, 1) 
                return
            end
            table.remove(candidateUnitsIds, idx)
        end
    end

    local function isDangerClose(unit, detectedUnit)
        local x1 = unit:GetCoordinate()
        local x2 = detectedUnit:GetCoordinate()
        local distance = x1:Get2DDistance(x2)
        return distance < DANGER_CLOSE_RANGE_METERS
    end

    local function isInvisibleFlagSet(unit)
        local groupName = unit:GetGroup():GetName()
        if not groupName then
            return false
        end
        
        local firstWaypointTask = mist.getGroupRoute(groupName, true)[1]["task"]
        if not firstWaypointTask then
            return false
        end
        local isComboTask = firstWaypointTask["id"] == "ComboTask"
        if not isComboTask then
            return
        end

        local comboTasks = firstWaypointTask["params"]["tasks"]
        for idx, elem in ipairs(comboTasks) do
            local action = comboTasks[idx]["params"]["action"]
            if action and action["id"] == "SetInvisible" and action["params"]["value"] then
                return true
            end
        end
        return false
    end

    local function fetchingDetectedUnits()
        local unit = nil
        if unitIndex > #allUnits then
            unitIndex = 1
            state = ARTY_DETECT_STATE.ASSIGN_FIRE_MISSIONS
        end

        unit = allUnits[unitIndex]
         -- only fetch units detected visually, optically, or with radar
        local detectedByThisUnit = unit:GetDetectedUnitSet(true, true, true, false, false, false)
        detectedByThisUnit:ForEachUnit(function(detectedUnit)
            if not detectedUnit:IsGround() then
                return
            end

            -- only ensures that the calling unit does not bring arty down on top of its own head,
            -- does not check for other blue units (as this would be yet another nested loop and
            --  possibly expensive)
            if isDangerClose(unit, detectedUnit) then
                return
            end

            -- Previously it seemed as if the RED forces would detect invisible JTAC teams, 
            -- but can no longer repro. Leaving the check in here for now.
            if isInvisibleFlagSet(detectedUnit) then
                return
            end
            
            local isStopped = detectedUnit:GetVelocityMPS() < 0.01
            -- this check seems to be not needed, since GetDetectedUnitSet only returns hostiles
            local isOtherSide = detectedUnit:GetCoalition() == otherSide
            if isOtherSide and isStopped then
                local id = detectedUnit:GetID()
                if not detectedUnits[id] then
                    -- env.info("Adding unit " .. detectedUnit:GetName() .. " with ID " .. id .. " to detected units")
                    detectedUnits[id] = detectedUnit
                end
                detectedUnits[detectedUnit:GetID()] = detectedUnit
            end
        end)

        unitIndex = unitIndex + 1

        return .03
    end

    local function assignFireMissions()
        if timer.getAbsTime() - timer.getTime0() < 60*11 then
            return 20
        end

        local detectedUnitIds = keysToArray(detectedUnits)
        for _, arty in ipairs(arties) do
            if arty:GetState() == "CombatReady" then
                assignFireMission(arty, detectedUnitIds)
            end
        end
        state = ARTY_DETECT_STATE.FETCHING_DETECTION_UNITS
        return 20
    end

    local stateHandlers = {
        [ARTY_DETECT_STATE.PREP_UNIT_ARRAYS] = prepUnitArray,
        [ARTY_DETECT_STATE.FETCHING_DETECTION_UNITS] = fetchingDetectedUnits,
        [ARTY_DETECT_STATE.ASSIGN_FIRE_MISSIONS] = assignFireMissions,
    }

    local function stateHandler()
        local prevState = state
        local delay = stateHandlers[state]()
        -- if prevState ~= state then
        --     env.info("AutoArty state changed from " .. prevState .. " to " .. state .. " with delay " .. delay)
        -- end
        timer.scheduleFunction(stateHandler, {}, timer.getTime() + delay)
    end

    stateHandler()

end

artyDetectionStateMachine(coalition.side.RED, allRedArties)
artyDetectionStateMachine(coalition.side.BLUE, allBlueArties)
