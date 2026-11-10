-- Rest and Resume (client only)
-- When a repeating action stops because the character is out of breath, sit on the ground,
-- rest until endurance is back and start the same work again.
-- Detection: ISBaseTimedAction.stop (common path) + per-action adapters.
-- Adapters: ISFitnessAction (exercise), ISChopTreeAction (vanilla tree chopping),
-- AreaTasks jobs blocked with IGUI_AreaTasks_RequiresEndurance.
-- Anything else that ends at the max endurance moodle: rest only, no resume.
-- Exercise whose time ran out: started again for the same time (option), after resting if tired.
-- See _devnotes/RestAndResume-design.md and vanilla-deps.txt.

RestAndResume = RestAndResume or {}
local R = RestAndResume
R.states = R.states or {}   -- playerNum -> state
R.counts = R.counts or {}   -- playerNum -> { key = ..., n = ... }
R.loopCounts = R.loopCounts or {} -- playerNum -> { key = ..., n = ... } (exercise continued after its time ran out)

local function log(...)
	local parts = {}
	for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
	print("[RestAndResume] " .. table.concat(parts, " "))
end
R.log = log

------------------------------------------------------------------------
-- Options (per client: PZAPI.ModOptions, saved in ModOptions.ini)
------------------------------------------------------------------------
local DEFAULTS = {
	enabled = true,
	recoverPct = 95,
	zombieRange = 12,
	maxRepeats = 5,
	moodleLimit = 2,
	showText = true,
	restOnly = true,
	continueOnTimeUp = true,
	maxLoops = 5,
}
R.overrides = R.overrides or {} -- tests set values here

local options
if PZAPI and PZAPI.ModOptions then
	options = PZAPI.ModOptions:create("RestAndResume", getText("IGUI_RestAndResume_Title"))
	options:addTickBox("enabled", getText("IGUI_RestAndResume_Enabled"), DEFAULTS.enabled,
		getText("IGUI_RestAndResume_Enabled_tooltip"))
	options:addSlider("recoverPct", getText("IGUI_RestAndResume_RecoverPct"), 30, 100, 5, DEFAULTS.recoverPct,
		getText("IGUI_RestAndResume_RecoverPct_tooltip"))
	options:addSlider("zombieRange", getText("IGUI_RestAndResume_ZombieRange"), 1, 40, 1, DEFAULTS.zombieRange,
		getText("IGUI_RestAndResume_ZombieRange_tooltip"))
	options:addSlider("maxRepeats", getText("IGUI_RestAndResume_MaxRepeats"), 1, 30, 1, DEFAULTS.maxRepeats,
		getText("IGUI_RestAndResume_MaxRepeats_tooltip"))
	options:addSlider("moodleLimit", getText("IGUI_RestAndResume_MoodleLimit"), 0, 3, 1, DEFAULTS.moodleLimit,
		getText("IGUI_RestAndResume_MoodleLimit_tooltip"))
	options:addTickBox("showText", getText("IGUI_RestAndResume_ShowText"), DEFAULTS.showText,
		getText("IGUI_RestAndResume_ShowText_tooltip"))
	options:addTickBox("restOnly", getText("IGUI_RestAndResume_RestOnly"), DEFAULTS.restOnly,
		getText("IGUI_RestAndResume_RestOnly_tooltip"))
	options:addTickBox("continueOnTimeUp", getText("IGUI_RestAndResume_ContinueOnTimeUp"), DEFAULTS.continueOnTimeUp,
		getText("IGUI_RestAndResume_ContinueOnTimeUp_tooltip"))
	options:addSlider("maxLoops", getText("IGUI_RestAndResume_MaxLoops"), 1, 20, 1, DEFAULTS.maxLoops,
		getText("IGUI_RestAndResume_MaxLoops_tooltip"))
end

function R.opt(id)
	if R.overrides[id] ~= nil then return R.overrides[id] end
	local o = options and options:getOption(id)
	if o and o.getValue then
		local v = o:getValue()
		if v ~= nil then return v end
	end
	return DEFAULTS[id]
end

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------
local function moodle(p, t) return p:getMoodles():getMoodleLevel(t) end
local function endurance(p) return p:getStats():get(CharacterStat.ENDURANCE) end

local function say(p, key, good, ...)
	if not R.opt("showText") then return end
	local text = getText(key, ...)
	if good then HaloTextHelper.addGoodText(p, text) else HaloTextHelper.addBadText(p, text) end
end

-- hunger / thirst / tired / injured above the option level. Not pain: muscle stiffness from exercise
-- raises the pain moodle (2-3 after a long workout) and stopped every rest after it, while vanilla
-- chopping ignores pain; wounds still show as INJURED. Exercise keeps vanilla's pain > 3 rule.
local LIMIT_MOODLES = { "HUNGRY", "THIRST", "TIRED", "INJURED" }
function R.moodleOver(p)
	local limit = R.opt("moodleLimit")
	for _, name in ipairs(LIMIT_MOODLES) do
		local t = MoodleType[name]
		if t and moodle(p, t) > limit then return name, moodle(p, t) end
	end
	return nil
end

-- a zombie that ends the rest: one the player can see within the option range (spotted list,
-- filled by IsoPlayer.updateLOS with sight cone/light/LOS), or any zombie within CLOSE tiles,
-- seen or not (one coming up behind a seated character is not in the spotted list)
R.CLOSE = 5
local function liveZombieWithin(list, px, py, r2)
	if not list then return nil end
	for i = 0, list:size() - 1 do
		local z = list:get(i)
		if z and instanceof(z, "IsoZombie") and not z:isDead() then
			local dx, dy = z:getX() - px, z:getY() - py
			if dx * dx + dy * dy <= r2 then return z end
		end
	end
	return nil
end

function R.zombieNear(p)
	local range = R.opt("zombieRange")
	local px, py = p:getX(), p:getY()
	local z = liveZombieWithin(p:getSpottedList(), px, py, range * range)
	if z then return z, "seen" end
	local close = math.min(range, R.CLOSE)
	z = liveZombieWithin(getCell():getZombieList(), px, py, close * close)
	if z and math.abs(z:getZ() - p:getZ()) < 1 then return z, "close" end
	return nil
end

local function queueEmpty(p)
	local q = ISTimedActionQueue.queues[p]
	return (q == nil or #q.queue == 0) and p:getCharacterActions():isEmpty()
end

local function isLocalPlayer(c)
	return c and instanceof(c, "IsoPlayer") and c:isLocalPlayer()
end

------------------------------------------------------------------------
-- Adapters. detect(action, player) -> record or nil (read-only, runs inside stop)
-- record = { kind, key, label, resume = function(player, record) -> bool }
------------------------------------------------------------------------
R.adapters = R.adapters or {}

-- Exercise. ISFitnessAction:update forceStops for movement, time, climbing/aiming/furniture and
-- for the endurance moodle above ISFitnessUI.enduranceLevelThreshold. We mark the endurance case
-- just before the vanilla update runs, so CANCEL (Java forceStop) and other reasons stay unmarked.
local function fitnessTired(a)
	local c = a.character
	if c:pressedMovement(true) then return false end
	if c:isClimbing() or c:isAiming() or c:isSittingOnFurniture() or c:getVehicle() then return false end
	if a.endMS and getGameTime():getCalender():getTimeInMillis() > a.endMS then return false end
	return moodle(c, MoodleType.ENDURANCE) > ISFitnessUI.enduranceLevelThreshold
end
R.fitnessTired = fitnessTired

-- the exercise time ran out (ISFitnessAction:update endMS check) and nothing the player did stops it
local function fitnessTimeUp(a)
	local c = a.character
	if c:pressedMovement(true) then return false end
	if c:isClimbing() or c:isAiming() or c:isSittingOnFurniture() or c:getVehicle() then return false end
	return a.endMS ~= nil and getGameTime():getCalender():getTimeInMillis() > a.endMS
end
R.fitnessTimeUp = fitnessTimeUp

local function fitnessUI(p)
	local ui = ISFitnessUI.instance and ISFitnessUI.instance[p:getPlayerNum() + 1]
	if ui and ui:isVisible() and ui.player == p then return ui end
	return nil
end

-- actions queued behind the stopped one (vanilla resetQueue cancels them): the player wanted something else
local function otherQueued(a, p)
	local q = ISTimedActionQueue.queues[p]
	if not q then return false end
	for _, x in ipairs(q.queue) do
		if x ~= a then return true end
	end
	return false
end

-- exercise whose time ran out: same exercise for the time first chosen
local function detectTimeUp(a, p)
	if not R.opt("continueOnTimeUp") then return nil end
	if moodle(p, MoodleType.PAIN) > 3 then
		log("exercise time over but pain", moodle(p, MoodleType.PAIN), "- not continuing")
		return nil
	end
	if otherQueued(a, p) then
		log("exercise time over, other action queued - not continuing")
		return nil
	end
	local minutes = tonumber(a.timeToExe)
	if not minutes or minutes < 1 then return nil end
	local rec = {
		kind = "fitness", loop = true, key = "loop:" .. tostring(a.exeDataType), label = tostring(a.exeDataType),
		exercise = a.exercise, exeDataType = a.exeDataType, minutes = minutes,
		chained = a._rarChain == true,
		tired = moodle(p, MoodleType.ENDURANCE) > ISFitnessUI.enduranceLevelThreshold,
	}
	-- fitness window open, not tired: keep the window from re-equipping the old items (it would queue
	-- equip actions right before our restart); they are handed back to the window after the restart,
	-- or given back to it on cancel so it re-equips them as vanilla does
	local ui = fitnessUI(p)
	if ui and not rec.tired and ui.currentExercice then
		rec.uiStash = { exe = ui.currentExercice, items = ui.itemsToReequip }
		ui.currentExercice = nil
		ui.itemsToReequip = {}
	end
	return rec
end

local function restoreUIStash(p, rec)
	local s = rec and rec.uiStash
	if not s then return end
	rec.uiStash = nil
	local ui = fitnessUI(p) or (ISFitnessUI.instance and ISFitnessUI.instance[p:getPlayerNum() + 1])
	if not ui then return end
	ui.itemsToReequip = s.items or {}
	ui.currentExercice = s.exe -- ISFitnessUI:update re-equips them now that no exercise runs
end
R.restoreUIStash = restoreUIStash

-- mark the exercise we just queued: true when it continues a time-up chain (its own time-up then
-- keeps the loop count), false/nil when it is the player's own exercise resumed after resting
-- exercises in the queue, also the one the window's OK path holds back behind ISWaitWhileGettingUp
-- (ISTimedActionQueue.addGetUpAndThen: setOnComplete(ISTimedActionQueue.add, action) -> onCompleteArgs.p1)
local function queuedFitness(p)
	local list = {}
	local q = ISTimedActionQueue.queues[p]
	for _, x in ipairs(q and q.queue or {}) do
		if x.Type == "ISFitnessAction" then
			list[#list + 1] = x
		elseif x.Type == "ISWaitWhileGettingUp" then
			local held = x.onCompleteArgs and x.onCompleteArgs.p1
			if type(held) == "table" and held.Type == "ISFitnessAction" then list[#list + 1] = held end
		end
	end
	return list
end

local function markChain(p, chain)
	for _, x in ipairs(queuedFitness(p)) do x._rarChain = chain end
end

R.adapters.ISFitnessAction = {
	detect = function(a, p)
		if not a._rarTired then
			if a._rarTimeUp then return detectTimeUp(a, p) end
			return nil
		end
		-- vanilla blocks starting exercise above pain level 3 (ISFitnessUI:updateButtons)
		if moodle(p, MoodleType.PAIN) > 3 then
			log("exercise stopped tired but pain", moodle(p, MoodleType.PAIN), "- no resume")
			return nil
		end
		local now = getGameTime():getCalender():getTimeInMillis()
		local minutes = math.floor((a.endMS - now) / 60000)
		if minutes < 1 then return nil end
		return {
			kind = "fitness", key = "fitness:" .. tostring(a.exeDataType), label = tostring(a.exeDataType),
			exercise = a.exercise, exeDataType = a.exeDataType, minutes = minutes,
			chain = a._rarChain == true,
		}
	end,
	-- vanilla refuses to start exercise above the threshold (ISFitnessAction:isValidStart)
	ready = function(p) return moodle(p, MoodleType.ENDURANCE) <= ISFitnessUI.enduranceLevelThreshold end,
	resume = function(p, r)
		local exeData = FitnessExercises.exercisesType[r.exercise]
		if not exeData then return false end
		if r.loop and moodle(p, MoodleType.PAIN) > 3 then
			log("pain", moodle(p, MoodleType.PAIN), "- not starting the exercise again")
			return false
		end
		local ui = ISFitnessUI.instance and ISFitnessUI.instance[p:getPlayerNum() + 1]
		if ui and ui:isVisible() and ui.player == p then
			-- vanilla OK button path: equips the prop, puts bags away, re-equips afterwards
			ui.selectedExe = r.exercise
			ui:selectedNewExercise()
			ui.exeTime:setText(tostring(r.minutes))
			ui:onClick({ internal = "OK" })
			if r.loop then
				-- the window re-equips what the player held before the first exercise, not the prop
				if r.uiStash then ui.itemsToReequip = r.uiStash.items or {}; r.uiStash = nil end
				if #queuedFitness(p) == 0 then return false end
				markChain(p, true)
				return true
			end
			markChain(p, r.chain)
			return true
		end
		if exeData.item then
			if not p:getInventory():contains(exeData.item, true) then return false end
			local inHand = (p:getPrimaryHandItem() and p:getPrimaryHandItem():getType() == exeData.item)
			if not inHand then
				ISWorldObjectContextMenu.equip(p, p:getPrimaryHandItem(), exeData.item, true, exeData.prop == "twohands")
			end
		end
		local action = ISFitnessAction:new(p, r.exercise, r.minutes, exeData, exeData.type)
		action._rarChain = r.loop or r.chain
		ISTimedActionQueue.add(action)
		return true
	end,
}

-- Vanilla tree chopping: isValid() turns false when isEnduranceSufficientForAction() is false
-- (endurance moodle at max). Trees chopped by an AreaTasks job carry areaTasksObserver;
-- the AreaTasks adapter handles those.
R.adapters.ISChopTreeAction = {
	detect = function(a, p)
		if a.areaTasksObserver then return nil end
		if p:isEnduranceSufficientForAction() then return nil end
		local tree = a.tree
		if not tree or tree:getObjectIndex() < 0 then return nil end
		local sq = tree:getSquare()
		if not sq then return nil end
		return {
			kind = "chop", key = string.format("chop:%d,%d,%d", sq:getX(), sq:getY(), sq:getZ()),
			label = "tree", tree = tree, x = sq:getX(), y = sq:getY(), z = sq:getZ(),
		}
	end,
	ready = function(p) return p:isEnduranceSufficientForAction() end,
	resume = function(p, r)
		local sq = getCell():getGridSquare(r.x, r.y, r.z)
		local tree = sq and sq:getTree()
		if not tree or tree:getObjectIndex() < 0 then
			log("tree is gone, nothing to resume")
			return false
		end
		-- vanilla: walk next to it, equip the best axe if needed, queue ISChopTreeAction
		ISWorldObjectContextMenu.doChopTree(p, tree)
		return not queueEmpty(p)
	end,
}

------------------------------------------------------------------------
-- Detection on the common stop path
------------------------------------------------------------------------
local function priority(kind)
	if kind == "areatasks" then return 3 end
	if kind == "rest" then return 0 end
	return 2
end

-- start (or replace) the rest cycle for this player
function R.begin(p, rec)
	if not R.opt("enabled") then return end
	if p:isDead() or p:isAsleep() or p:getVehicle() then return end
	local num = p:getPlayerNum()
	local cur = R.states[num]
	if cur and priority(cur.rec.kind) > priority(rec.kind) then restoreUIStash(p, rec) return end
	local over, level = R.moodleOver(p)
	if over then
		log("not resting:", over, "moodle", level, "above limit", R.opt("moodleLimit"), "for", rec.kind, rec.key)
		say(p, "IGUI_RestAndResume_Moodle", false)
		restoreUIStash(p, rec)
		return
	end
	if rec.loop then return R.beginLoop(p, num, rec) end
	local count = R.counts[num]
	if not count or count.key ~= rec.key then
		count = { key = rec.key, n = 0 }
		R.counts[num] = count
	end
	if rec.kind ~= "rest" and count.n >= R.opt("maxRepeats") then
		log("repeat limit reached for", rec.key, count.n)
		say(p, "IGUI_RestAndResume_LimitReached", false)
		R.counts[num] = nil
		return
	end
	R.states[num] = { rec = rec, phase = "sit", ticks = 0, player = p }
	log("detected", rec.kind, rec.key, "endurance", string.format("%.3f", endurance(p)))
	if rec.kind == "rest" then
		say(p, "IGUI_RestAndResume_RestOnly_Text", true)
	else
		say(p, "IGUI_RestAndResume_Resting", true)
	end
end

-- exercise time ran out: count the chain, then rest first (tired) or start again right away
function R.beginLoop(p, num, rec)
	local lc = R.loopCounts[num]
	if not rec.chained or not lc or lc.key ~= rec.key then
		lc = { key = rec.key, n = 0 }
		R.loopCounts[num] = lc
	end
	local max = math.floor(R.opt("maxLoops"))
	if lc.n >= max then
		log("loop limit reached for", rec.key, lc.n .. "/" .. max)
		say(p, "IGUI_RestAndResume_LoopLimitReached", false, tostring(lc.n))
		R.loopCounts[num] = nil
		restoreUIStash(p, rec)
		return
	end
	R.states[num] = { rec = rec, phase = rec.tired and "sit" or "start", ticks = 0, player = p }
	log("detected", "timeup", rec.key, "tired", tostring(rec.tired), "loop", (lc.n + 1) .. "/" .. max,
		"endurance", string.format("%.3f", endurance(p)))
	if rec.tired then say(p, "IGUI_RestAndResume_Resting", true) end
end

-- start the recorded work again (after resting or right away); counts and reports
local function doResume(num, st)
	local p = st.player
	local rec = st.rec
	R.states[num] = nil
	local count, lc
	if rec.loop then
		lc = R.loopCounts[num]
		if lc and lc.key == rec.key then lc.n = lc.n + 1 end
		R.counts[num] = nil -- a new run of the exercise: tired restarts count from zero again
	else
		count = R.counts[num]
		if count and count.key == rec.key then count.n = count.n + 1 end
	end
	local ok, res = pcall(rec.resume, p, rec)
	if ok and res then
		if rec.loop then
			local max = tostring(math.floor(R.opt("maxLoops")))
			log("continued", rec.kind, rec.key, "loop", tostring(lc and lc.n or "?") .. "/" .. max, "minutes", rec.minutes)
			say(p, "IGUI_RestAndResume_Continued", true, tostring(lc and lc.n or 1), max)
		else
			log("resumed", rec.kind, rec.key, "count", count and count.n or "?")
			say(p, "IGUI_RestAndResume_Resumed", true)
		end
	else
		log("resume failed", rec.kind, rec.key, ok and "" or tostring(res))
		R.counts[num] = nil
		R.loopCounts[num] = nil
		restoreUIStash(p, rec)
		say(p, "IGUI_RestAndResume_ResumeFailed", false)
	end
end

-- generic rest-only rule: the action is no longer valid and the endurance moodle is at max
local function restOnlyDetect(a, p)
	if not R.opt("restOnly") then return nil end
	if a.areaTasksObserver then return nil end
	if p:isEnduranceSufficientForAction() then return nil end
	if p:pressedMovement(true) then return nil end
	local ok, valid = pcall(a.isValid, a)
	if not ok or valid then return nil end
	return { kind = "rest", key = "rest:" .. tostring(a.Type), label = tostring(a.Type) }
end

function R.onStop(a)
	if not R.opt("enabled") then return end
	local p = a.character
	if not isLocalPlayer(p) then return end
	if a._rarOwn then return end
	local st = R.states[p:getPlayerNum()]
	if st and st.phase ~= "resting" and st.phase ~= "sit" then return end
	local adapter = R.adapters[a.Type]
	local rec
	if adapter then
		rec = adapter.detect(a, p)
		if rec then rec.resume = adapter.resume; rec.ready = adapter.ready end
	else
		rec = restOnlyDetect(a, p)
		if rec then log("rest only (no adapter):", rec.label) end
	end
	if rec then R.begin(p, rec) end
end

------------------------------------------------------------------------
-- AreaTasks adapter
------------------------------------------------------------------------
R.areaJobs = R.areaJobs or setmetatable({}, { __mode = "k" }) -- job -> { task, bounds, dest }

local function copyBounds(b)
	local c = {}
	for k, v in pairs(b) do c[k] = v end
	return c
end

local function areaResume(p, r)
	local dest = nil
	if r.dest then
		dest = getCell():getGridSquare(r.dest.x, r.dest.y, r.dest.z)
		if not dest then
			log("AreaTasks destination square not loaded")
			return false
		end
	end
	local job = AreaTasks.WorkController.start(r.task, p, r.bounds, dest)
	return job ~= nil
end

function R.onAreaTaskFinished(job, outcome)
	if outcome ~= "blocked" then return end
	local p = job.playerObj
	if not isLocalPlayer(p) then return end
	if job.blockedReason ~= getText("IGUI_AreaTasks_RequiresEndurance") then return end
	local info = R.areaJobs[job]
	if not info then
		log("AreaTasks job blocked by endurance but its area is unknown - rest only")
		R.begin(p, { kind = "rest", key = "rest:AreaTasks", label = "AreaTasks" })
		return
	end
	local b = info.bounds
	R.begin(p, {
		kind = "areatasks",
		key = string.format("area:%s:%s,%s,%s,%s,%s", tostring(info.task.id), tostring(b.x1), tostring(b.y1),
			tostring(b.x2), tostring(b.y2), tostring(b.z)),
		label = tostring(info.task.id), task = info.task, bounds = info.bounds, dest = info.dest,
		resume = areaResume,
		ready = function(pl) return pl:isEnduranceSufficientForAction() end,
	})
end

local function installAreaTasks()
	if not (AreaTasks and AreaTasks.WorkController and type(AreaTasks.WorkController.start) == "function") then
		log("AreaTasks not found - AreaTasks adapter off")
		return
	end
	if not R.areaInstalled then
		R.areaInstalled = true
		local WC = AreaTasks.WorkController
		local orig = WC.start
		WC.start = function(task, playerObj, bounds, destinationSquare, ...)
			local job = orig(task, playerObj, bounds, destinationSquare, ...)
			if job and type(bounds) == "table" then
				R.areaJobs[job] = {
					task = task, bounds = copyBounds(bounds),
					dest = destinationSquare and {
						x = destinationSquare:getX(), y = destinationSquare:getY(), z = destinationSquare:getZ(),
					} or nil,
				}
			end
			return job
		end
	end
	if Events.AreaTaskFinished then
		Events.AreaTaskFinished.Remove(R.onAreaTaskFinished)
		Events.AreaTaskFinished.Add(R.onAreaTaskFinished)
		log("AreaTasks adapter on")
	else
		log("Events.AreaTaskFinished missing - AreaTasks adapter off")
	end
end

------------------------------------------------------------------------
-- Rest cycle (OnTick)
------------------------------------------------------------------------
function R.cancel(num, reasonKey, why, standUp)
	local st = R.states[num]
	if not st then return end
	R.states[num] = nil
	R.counts[num] = nil
	R.loopCounts[num] = nil
	local p = st.player
	restoreUIStash(p, st.rec)
	log("cancelled:", why)
	if reasonKey then say(p, reasonKey, false) end
	if standUp and p:isSitting() then p:setVariable("forceGetUp", true) end
end

local SIT_TIMEOUT = 900  -- ticks to get seated after the stop
local STAND_TIMEOUT = 600
local START_DELAY = 30    -- ticks after a time-up stop before starting again
local START_TIMEOUT = 300 -- stop waiting for the exercise state to end after this

local function tickPlayer(num, st)
	local p = st.player
	if not p or p:isDead() or p:isAsleep() or p:getVehicle() then
		R.cancel(num, nil, "player unavailable", false)
		return
	end
	st.ticks = st.ticks + 1

	if st.phase == "sit" then
		if p:pressedMovement(true) then return R.cancel(num, "IGUI_RestAndResume_Cancelled", "moved before sitting", false) end
		if R.zombieNear(p) then return R.cancel(num, "IGUI_RestAndResume_Zombie", "zombie before sitting", false) end
		if p:isSitOnGround() then
			st.phase = "resting"; st.ticks = 0
			log("sitting, endurance", string.format("%.3f", endurance(p)))
			return
		end
		if st.ticks > SIT_TIMEOUT then return R.cancel(num, nil, "could not sit", false) end
		if queueEmpty(p) and st.ticks % 30 == 0 then
			p:reportEvent("EventSitOnGround")
		end
		return
	end

	if st.phase == "resting" then
		if not p:isSitOnGround() then return R.cancel(num, "IGUI_RestAndResume_Cancelled", "stood up", false) end
		if p:pressedMovement(true) then return R.cancel(num, "IGUI_RestAndResume_Cancelled", "movement", true) end
		if not queueEmpty(p) then return R.cancel(num, "IGUI_RestAndResume_Cancelled", "other action", false) end
		if st.ticks % 10 == 0 then
			if R.zombieNear(p) then return R.cancel(num, "IGUI_RestAndResume_Zombie", "zombie", true) end
			local over = R.moodleOver(p)
			if over then return R.cancel(num, "IGUI_RestAndResume_Moodle", over, true) end
		end
		if endurance(p) * 100 >= R.opt("recoverPct") and (not st.rec.ready or st.rec.ready(p)) then
			log("recovered, endurance", string.format("%.3f", endurance(p)))
			if st.rec.kind == "rest" then
				R.states[num] = nil
				say(p, "IGUI_RestAndResume_Recovered", true)
				return
			end
			st.phase = "stand"; st.ticks = 0
			p:setVariable("forceGetUp", true)
		end
		return
	end

	if st.phase == "stand" then
		if R.zombieNear(p) then return R.cancel(num, "IGUI_RestAndResume_Zombie", "zombie while standing", false) end
		if p:isSitting() then
			if st.ticks > STAND_TIMEOUT then return R.cancel(num, nil, "could not stand", false) end
			if st.ticks % 60 == 0 then p:setVariable("forceGetUp", true) end
			return
		end
		if not queueEmpty(p) then return R.cancel(num, nil, "player queued something else", false) end
		doResume(num, st)
		return
	end

	-- exercise time ran out, not tired: let the exercise state end, then start it again
	if st.phase == "start" then
		if p:pressedMovement(true) then return R.cancel(num, "IGUI_RestAndResume_Cancelled", "moved before continuing", false) end
		if st.ticks % 10 == 0 then
			if R.zombieNear(p) then return R.cancel(num, "IGUI_RestAndResume_Zombie", "zombie before continuing", false) end
			local over = R.moodleOver(p)
			if over then return R.cancel(num, "IGUI_RestAndResume_Moodle", over, false) end
		end
		if st.ticks < START_DELAY then return end
		if not queueEmpty(p) then return R.cancel(num, nil, "player queued something else", false) end
		-- tired by now (the moodle can lag the stop): vanilla would refuse to start, rest first
		if st.rec.ready and not st.rec.ready(p) then
			log("tired before continuing - resting first")
			st.rec.tired = true
			st.phase = "sit"; st.ticks = 0
			say(p, "IGUI_RestAndResume_Resting", true)
			return
		end
		-- vanilla ISFitnessAction:waitToStart waits for IdleState anyway; give the outro some time
		local okCtx, ctx = pcall(function() return p:getCurrentActionContextStateName() end)
		if okCtx and ctx == "fitness" and st.ticks < START_TIMEOUT then return end
		doResume(num, st)
	end
end

function R.onTick()
	for num, st in pairs(R.states) do
		tickPlayer(num, st)
	end
end

------------------------------------------------------------------------
-- Install
------------------------------------------------------------------------
local function install()
	if R.installed then return end
	R.installed = true

	local origStop = ISBaseTimedAction.stop
	ISBaseTimedAction.stop = function(self, ...)
		local ok, err = pcall(R.onStop, self)
		if not ok then log("onStop error", tostring(err)) end
		return origStop(self, ...)
	end

	local origUpdate = ISFitnessAction.update
	ISFitnessAction.update = function(self, ...)
		if not self._rarTired and isLocalPlayer(self.character) then
			local ok, tired = pcall(fitnessTired, self)
			if ok and tired then self._rarTired = true end
			if not self._rarTired and not self._rarTimeUp then
				local ok2, up = pcall(fitnessTimeUp, self)
				if ok2 and up then self._rarTimeUp = true end
			end
		end
		return origUpdate(self, ...)
	end
	log("installed")
end

-- ISBaseTimedAction / ISFitnessAction / ISChopTreeAction live in shared/, ISTimedActionQueue,
-- ISFitnessUI and ISWorldObjectContextMenu in client/: all loaded before OnGameStart.
Events.OnGameStart.Add(function()
	install()
	installAreaTasks()
	Events.OnTick.Remove(R.onTick)
	Events.OnTick.Add(R.onTick)
end)
