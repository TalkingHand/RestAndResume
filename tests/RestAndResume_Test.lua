-- Rest and Resume in-game test (pzt TEST_FILES only, not shipped). One client, every scenario.
-- Driver: RARTest.start() starts a coroutine on OnTick; RARTest.poll() re-queues itself (PZTest.step)
-- until all scenarios ended. Results: "[RARTest] PASS/FAIL" lines; failures also "[PZTest] FAIL".
-- Endurance is set directly to reach the stop thresholds quickly; one check uses real sitting regen.

RARTest = RARTest or {}
local T = RARTest
local R = function() return RestAndResume end

local function log(...)
	local parts = {}
	for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
	print("[RARTest] " .. table.concat(parts, " "))
end

T.pass, T.fail = 0, 0
local function check(ok, label, extra)
	if ok then T.pass = T.pass + 1 else T.fail = T.fail + 1 end
	log(ok and "PASS" or "FAIL", T.scenario or "", label, extra ~= nil and tostring(extra) or "")
	if not ok and PZTest and PZTest.fail then PZTest.fail("RARTest " .. tostring(T.scenario) .. " " .. label .. " " .. tostring(extra or "")) end
	return ok
end

local function p() return getPlayer() end
local function stats() return p():getStats() end
local function setEnd(v) stats():set(CharacterStat.ENDURANCE, v) end
local function getEnd() return stats():get(CharacterStat.ENDURANCE) end
local function moodle(t) return p():getMoodles():getMoodleLevel(t) end
local function queue() return ISTimedActionQueue.getTimedActionQueue(p()).queue end
local function current() return queue()[1] end
local function state() return R().states[p():getPlayerNum()] end

-- character state for timeouts: why could nothing start?
function T.diag(label)
	local pl = p()
	local parts = {}
	local function add(k, f) local ok, v = pcall(f); parts[#parts + 1] = k .. "=" .. (ok and tostring(v) or "?") end
	add("ctx", function() return pl:getCurrentActionContextStateName() end)
	add("state", function() local st = pl:getCurrentState(); return st and tostring(st):match("([%w_]+)@") or tostring(st) end)
	add("sitting", function() return pl:isSitting() end)
	add("sitGround", function() return pl:isSitOnGround() end)
	add("exStarted", function() return pl:getVariableBoolean("ExerciseStarted") end)
	add("exEnded", function() return pl:getVariableBoolean("ExerciseEnded") end)
	add("fitFinished", function() return pl:getVariableString("FitnessFinished") end)
	add("curExe", function() return pl:getFitness():getCurrentExe() end)
	add("javaActions", function() return pl:getCharacterActions():size() end)
	add("queue", function()
		local t = {}
		for _, a in ipairs(queue()) do t[#t + 1] = tostring(a.Type) .. (a:isStarted() and "*" or "") end
		return table.concat(t, ",")
	end)
	add("pos", function() return math.floor(pl:getX()) .. "," .. math.floor(pl:getY()) .. "," .. math.floor(pl:getZ()) end)
	add("endurance", function() return string.format("%.2f", getEnd()) end)
	log("DIAG", label, table.concat(parts, " "))
end

------------------------------------------------------------------ coroutine helpers
local function yield() coroutine.yield() end
local function waitTicks(n) for _ = 1, n do yield() end end
local function waitUntil(fn, ticks, label)
	for i = 1, ticks do
		local ok, res = pcall(fn)
		if ok and res then return true, i end
		yield()
	end
	if label then log("timeout:", label, ticks); T.diag(label) end
	return false
end

local function protect()
	local pl = p()
	pl:setInvisible(true)
	pl:setZombiesDontAttack(true)
	local list = getCell():getZombieList()
	for i = list:size() - 1, 0, -1 do
		local z = list:get(i)
		if z and z:DistTo(pl) < 60 then z:removeFromSquare(); z:removeFromWorld() end
	end
end

local function clearSquare(sq)
	if not sq then return end
	local objs = sq:getObjects()
	for i = objs:size() - 1, 1, -1 do
		local o = objs:get(i)
		if o and o ~= sq:getFloor() then sq:transmitRemoveItemFromSquare(o) end
	end
	sq:RecalcProperties()
end

local function addTree(x, y, z)
	local sq = getCell():getGridSquare(x, y, z)
	clearSquare(sq)
	local tree = IsoTree.new(sq, "e_americanholly_1_3")
	sq:AddTileObject(tree)
	sq:RecalcProperties()
	return tree
end

local function removeTree(tree)
	if tree and tree:getObjectIndex() >= 0 then
		local sq = tree:getSquare()
		sq:transmitRemoveItemFromSquare(tree)
	end
end

local function giveAxe()
	local pl = p()
	local inv = pl:getInventory()
	local axe = inv:getFirstTypeRecurse("Base.Axe") or inv:AddItem("Base.Axe")
	pl:setPrimaryHandItem(axe)
	pl:setSecondaryHandItem(axe)
	return axe
end

local function standUp()
	local pl = p()
	if pl:isSitting() then pl:setVariable("forceGetUp", true) end
	waitUntil(function() return not p():isSitting() end, 600, "stand up")
	waitTicks(30)
end

-- fresh start for a scenario: nothing queued, no rest state, fed, rested, standing
local function reset(name)
	T.scenario = name
	log("---- scenario", name)
	T.diag("before reset")
	local pl = p()
	-- a scenario that left the character in the exercise state makes every later one time out
	local okCtx, ctx = pcall(function() return pl:getCurrentActionContextStateName() end)
	if okCtx and ctx == "fitness" then
		check(false, "previous scenario left the character in FitnessState (recovering)")
		pl:setVariable("ExerciseStarted", false)
		pl:setVariable("ExerciseEnded", true)
		pl:SetVariable("FitnessFinished", "true")
		pcall(function() pl:getFitness():setCurrentExercise(nil) end)
		for _ = 1, 300 do
			if pl:getCurrentActionContextStateName() ~= "fitness" then break end
			yield()
		end
		T.diag("after fitness recovery")
	end
	protect()
	ISTimedActionQueue.clear(pl)
	pl:StopAllActionQueue()
	R().states = {}
	R().counts = {}
	R().overrides = { moodleLimit = 3, enabled = true }
	local s = stats()
	s:set(CharacterStat.HUNGER, 0)
	s:set(CharacterStat.THIRST, 0)
	s:set(CharacterStat.FATIGUE, 0)
	pl:getBodyDamage():RestoreToFullHealth()
	setEnd(1.0)
	waitTicks(10)
	standUp()
	ISTimedActionQueue.clear(pl)
	waitTicks(30)
	T.diag("after reset")
end

local function base()
	local pl = p()
	return math.floor(pl:getX()), math.floor(pl:getY()), math.floor(pl:getZ())
end

local function waitResting(label)
	local ok = waitUntil(function() local st = state(); return st and st.phase == "resting" end, 1500, label .. " resting")
	check(ok, label .. ": sitting and resting")
	check(p():isSitOnGround(), label .. ": isSitOnGround")
	return ok
end

------------------------------------------------------------------ scenarios

-- 1. exercise with the fitness window open (vanilla OK path)
local function fitnessUI()
	reset("1 fitness (window)")
	local pl = p()
	local ui = ISFitnessUI:new(0, 0, 600, 350, pl)
	ui:initialise()
	ui:addToUIManager()
	ui.selectedExe = "squats"
	ui:selectedNewExercise()
	ui.exeTime:setText("30")
	ui:onClick({ internal = "OK" })
	local ok = waitUntil(function() local c = current(); return c and c.Type == "ISFitnessAction" and c:isStarted() end, 900, "fitness start")
	check(ok, "exercise started")
	if not ok then ui:removeFromUIManager(); ISFitnessUI.instance[pl:getPlayerNum() + 1] = nil; return end
	waitTicks(180)
	setEnd(0.2)
	ok = waitUntil(function() local st = state(); return st and st.rec.kind == "fitness" end, 600, "fitness detect")
	check(ok, "stop detected as exercise (endurance 0.2, moodle " .. moodle(MoodleType.ENDURANCE) .. ")")
	if not ok then return end
	local rec = state().rec
	check(rec.exercise == "squats", "same exercise recorded", rec.exercise)
	check(rec.minutes >= 25 and rec.minutes <= 30, "remaining minutes", rec.minutes)
	if not waitResting("fitness") then return end
	-- real regen while sitting (no forced value): endurance must go up
	local e0 = getEnd()
	waitTicks(600)
	local e1 = getEnd()
	check(e1 > e0 + 0.005, "endurance regenerates while sitting", string.format("%.4f -> %.4f", e0, e1))
	check(state() ~= nil and state().phase == "resting", "still resting below the target")
	setEnd(0.97)
	ok = waitUntil(function() local c = current(); return state() == nil and c and c.Type == "ISFitnessAction" and c:isStarted() end, 1500, "fitness resume")
	check(ok, "same exercise started again")
	local c = current()
	if c and c.Type == "ISFitnessAction" then
		check(c.exercise == "squats", "resumed exercise type", c.exercise)
		check(c.timeToExe == rec.minutes, "resumed for the remaining minutes", tostring(c.timeToExe) .. " vs " .. tostring(rec.minutes))
	end
	local cnt = R().counts[pl:getPlayerNum()]
	check(cnt and cnt.n == 1, "repeat count 1", cnt and cnt.n)
	-- CANCEL button (vanilla: Java forceStop) must not resume
	setEnd(0.6)
	waitTicks(30)
	ui:onClick({ internal = "CANCEL" })
	waitTicks(240)
	check(state() == nil, "CANCEL button: no rest")
	ui:setVisible(false); ui:removeFromUIManager(); ISFitnessUI.instance[pl:getPlayerNum() + 1] = nil
end

-- 2. exercise without the window (our equip + queue path), dumbbell exercise
local function fitnessNoUI()
	reset("2 fitness (no window)")
	local pl = p()
	local data = FitnessExercises.exercisesType.squats
	ISTimedActionQueue.add(ISFitnessAction:new(pl, "squats", 20, data, data.type))
	local ok = waitUntil(function() local c = current(); return c and c.Type == "ISFitnessAction" and c:isStarted() end, 900, "fitness2 start")
	check(ok, "exercise started")
	if not ok then return end
	waitTicks(120)
	setEnd(0.2)
	ok = waitUntil(function() local st = state(); return st and st.rec.kind == "fitness" end, 600)
	check(ok, "stop detected")
	if not ok or not waitResting("fitness2") then return end
	setEnd(0.97)
	ok = waitUntil(function() local c = current(); return state() == nil and c and c.Type == "ISFitnessAction" and c:isStarted() end, 1500, "fitness2 resume")
	check(ok, "exercise started again without the window")
	-- let the resumed exercise really run (a stop in the same frame as the start left the
	-- character in FitnessState in run 025149)
	waitTicks(120)
	T.diag("resumed exercise running")
	-- 7c. time over: endMS in the past -> vanilla stops it, no resume
	local c = current()
	if c and c.Type == "ISFitnessAction" then
		setEnd(0.2) -- also tired, but the time is up first
		c.endMS = getGameTime():getCalender():getTimeInMillis() - 1
	end
	waitTicks(240)
	check(state() == nil, "time over: no rest even when tired")
	local idle = waitUntil(function() return p():getCurrentActionContextStateName() == "idle" end, 300, "idle after time over")
	check(idle, "back to idle after the exercise time ran out")
end

-- 3. vanilla tree chopping
local function chop()
	reset("3 vanilla chop")
	local x, y, z = base()
	local tree = addTree(x, y - 2, z)
	giveAxe()
	ISWorldObjectContextMenu.doChopTree(p(), tree)
	local ok = waitUntil(function() local c = current(); return c and c.Type == "ISChopTreeAction" and c:isStarted() end, 900, "chop start")
	check(ok, "chopping started")
	if not ok then removeTree(tree) return end
	waitTicks(300)
	local h0 = tree:getHealth()
	setEnd(0.05)
	ok = waitUntil(function() local st = state(); return st and st.rec.kind == "chop" end, 600, "chop detect")
	check(ok, "stop detected as chop (moodle " .. moodle(MoodleType.ENDURANCE) .. ")")
	if not ok then removeTree(tree) return end
	check(state().rec.x == x and state().rec.y == y - 2, "same tree square recorded")
	if not waitResting("chop") then removeTree(tree) return end
	local h1 = tree:getHealth()
	setEnd(0.97)
	ok = waitUntil(function() local c = current(); return state() == nil and c and c.Type == "ISChopTreeAction" and c:isStarted() end, 1500, "chop resume")
	check(ok, "chopping started again")
	local c = current()
	check(c and c.tree == tree, "same tree object")
	check(h1 <= h0, "tree damage kept while resting", h0 .. " -> " .. h1)
	waitTicks(400)
	local h2 = tree:getObjectIndex() >= 0 and tree:getHealth() or -1
	check(h2 < h1, "resumed chopping damages the same tree further", h1 .. " -> " .. h2)
	T.chopTree = tree
end

-- 4. AreaTasks continuous chopping: job blocked by RequiresEndurance, restarted with the same area
local function areaTasks()
	reset("4 AreaTasks chop")
	if not (AreaTasks and AreaTasks.WorkController and AreaTasks.Tasks and AreaTasks.Tasks.CutDownTree) then
		check(false, "AreaTasks loaded")
		return
	end
	removeTree(T.chopTree)
	local x, y, z = base()
	for yy = y - 6, y - 2 do for xx = x - 3, x + 3 do clearSquare(getCell():getGridSquare(xx, yy, z)) end end
	local trees = { addTree(x - 2, y - 4, z), addTree(x + 2, y - 4, z) }
	giveAxe()
	local bounds = AreaTasks.Core.makeBounds(x - 3, y - 5, x + 3, y - 3, z)
	local job = AreaTasks.WorkController.start(AreaTasks.Tasks.CutDownTree, p(), bounds, nil)
	check(job ~= nil, "AreaTasks job started")
	if not job then return end
	check(R().areaJobs[job] ~= nil, "start wrapper remembered the area")
	local ok = waitUntil(function() local c = current(); return c and c.Type == "ISChopTreeAction" and c:isStarted() end, 2400, "area chop start")
	check(ok, "job is chopping")
	if not ok then return end
	check(current().areaTasksObserver ~= nil, "native chop is observed by AreaTasks")
	waitTicks(200)
	setEnd(0.05)
	ok = waitUntil(function() local st = state(); return st and st.rec.kind == "areatasks" end, 600, "area detect")
	check(ok, "AreaTasks blocked(RequiresEndurance) detected")
	check(job.status == "blocked", "job ended blocked", job.status)
	check(AreaTasks.WorkController.activeByPlayer[0] == nil, "no job running while resting")
	if not ok then return end
	check(state().rec.kind == "areatasks", "not taken over by the vanilla chop adapter")
	if not waitResting("area") then return end
	setEnd(0.97)
	ok = waitUntil(function() return state() == nil and AreaTasks.WorkController.activeByPlayer[0] ~= nil end, 1500, "area resume")
	check(ok, "AreaTasks job started again")
	local job2 = AreaTasks.WorkController.activeByPlayer[0]
	if job2 then
		local info = R().areaJobs[job2]
		check(job2 ~= job and job2.task == job.task, "same task, new job")
		check(info and info.bounds.x1 == bounds.x1 and info.bounds.y2 == bounds.y2 and info.bounds.z == bounds.z, "same area")
		-- let it finish quickly
		for _, t in ipairs(trees) do if t:getObjectIndex() >= 0 then t:setHealth(1) end end
		ok = waitUntil(function() return AreaTasks.WorkController.activeByPlayer[0] == nil end, 3600, "area finish")
		for _, t in ipairs(trees) do if t:getObjectIndex() >= 0 then t:setHealth(1) end end
		check(ok and job2.status == "completed", "resumed job completed", job2.status)
		check(trees[1]:getObjectIndex() < 0 and trees[2]:getObjectIndex() < 0, "both trees in the area are down")
	end
end

-- start a chop and exhaust it, wait until resting; returns the tree
local function chopToRest(label)
	local x, y, z = base()
	local tree = addTree(x, y - 2, z)
	giveAxe()
	ISWorldObjectContextMenu.doChopTree(p(), tree)
	if not waitUntil(function() local c = current(); return c and c.Type == "ISChopTreeAction" and c:isStarted() end, 900, label .. " chop") then
		check(false, label .. ": chopping started")
		return tree, false
	end
	waitTicks(60)
	setEnd(0.05)
	if not waitUntil(function() local st = state(); return st and st.rec.kind == "chop" end, 600) then
		check(false, label .. ": detected")
		return tree, false
	end
	return tree, waitResting(label)
end

-- 5. zombie near while resting
local function zombie()
	reset("5 zombie")
	local tree, ok = chopToRest("zombie")
	if ok then
		local x, y, z = base()
		R().overrides.zombieRange = 12
		-- 4 tiles: inside the "any zombie, seen or not" radius (R.CLOSE = 5); whether the seated
		-- character can see it depends on facing and light, so the seen-range rule is not tested here
		local zs = addZombiesInOutfit(x + 4, y, z, 1, nil, 50)
		log("spawned zombies", zs and zs:size())
		ok = waitUntil(function() return state() == nil end, 900, "zombie cancel")
		check(ok, "zombie within 4 tiles cancels the rest")
		waitUntil(function() return not p():isSitting() end, 600)
		check(not p():isSitting(), "character stands up")
		waitTicks(120)
		local c = current()
		check(not (c and c.Type == "ISChopTreeAction"), "chopping not resumed")
	end
	protect()
	removeTree(tree)
end

-- 6. player stands up / does something else while resting
local function playerCancel()
	reset("6a stand up")
	local tree, ok = chopToRest("standup")
	if ok then
		p():setVariable("forceGetUp", true) -- same as the vanilla sit key while sitting
		ok = waitUntil(function() return state() == nil end, 600, "standup cancel")
		check(ok, "standing up cancels the resume")
		setEnd(0.97)
		waitTicks(300)
		local c = current()
		check(not (c and c.Type == "ISChopTreeAction"), "chopping not resumed after standing up")
	end
	removeTree(tree)

	reset("6b other action")
	tree, ok = chopToRest("other")
	if ok then
		local axe = p():getPrimaryHandItem()
		ISTimedActionQueue.add(ISUnequipAction:new(p(), axe, 50))
		ok = waitUntil(function() return state() == nil end, 600, "other cancel")
		check(ok, "another action cancels the resume")
		setEnd(0.97)
		waitTicks(300)
		local c = current()
		check(not (c and c.Type == "ISChopTreeAction"), "chopping not resumed after another action")
	end
	removeTree(tree)
end

-- 7. exercise stopped while in pain (muscle soreness): no resume
local function pain()
	reset("7 pain")
	local pl = p()
	local data = FitnessExercises.exercisesType.pushups
	ISTimedActionQueue.add(ISFitnessAction:new(pl, "pushups", 20, data, data.type))
	local ok = waitUntil(function() local c = current(); return c and c.Type == "ISFitnessAction" and c:isStarted() end, 900, "pain start")
	check(ok, "exercise started")
	if not ok then return end
	local bd = pl:getBodyDamage()
	for _, part in ipairs({ BodyPartType.UpperArm_L, BodyPartType.UpperArm_R, BodyPartType.Torso_Upper, BodyPartType.ForeArm_L, BodyPartType.ForeArm_R }) do
		bd:getBodyPart(part):setAdditionalPain(100)
	end
	waitUntil(function() return moodle(MoodleType.PAIN) > 3 end, 600, "pain moodle")
	log("pain moodle", moodle(MoodleType.PAIN))
	setEnd(0.2)
	waitTicks(300)
	check(moodle(MoodleType.PAIN) > 3, "pain moodle above 3", moodle(MoodleType.PAIN))
	check(state() == nil, "tired + pain: no rest/resume")
	local c = current()
	check(not (c and c.Type == "ISFitnessAction"), "exercise not restarted")
end

-- 8. action without an adapter: rest only
RARTestAction = ISBaseTimedAction:derive("RARTestAction")
function RARTestAction:isValid() return self.character:isEnduranceSufficientForAction() end
function RARTestAction:update() end
function RARTestAction:start() end
function RARTestAction:stop() ISBaseTimedAction.stop(self) end
function RARTestAction:perform() ISBaseTimedAction.perform(self) end
function RARTestAction:new(character)
	local o = ISBaseTimedAction.new(self, character)
	o.maxTime = -1
	return o
end

local function restOnly()
	reset("8 rest only")
	ISTimedActionQueue.add(RARTestAction:new(p()))
	local ok = waitUntil(function() local c = current(); return c and c.Type == "RARTestAction" and c:isStarted() end, 300, "test action")
	check(ok, "test action running")
	setEnd(0.05)
	ok = waitUntil(function() local st = state(); return st and st.rec.kind == "rest" end, 600, "rest detect")
	check(ok, "no-adapter action: rest started")
	if not ok or not waitResting("restonly") then return end
	setEnd(0.97)
	ok = waitUntil(function() return state() == nil end, 600, "rest end")
	check(ok, "rest ended after recovery")
	waitTicks(120)
	check(current() == nil, "nothing resumed")
	check(p():isSitOnGround(), "stays seated after rest-only")

	-- option off: no rest
	reset("8b rest only off")
	R().overrides.restOnly = false
	ISTimedActionQueue.add(RARTestAction:new(p()))
	waitUntil(function() local c = current(); return c and c:isStarted() end, 300)
	setEnd(0.05)
	waitTicks(300)
	check(state() == nil, "restOnly option off: no rest")
end

-- 9. limits: repeat count and moodle level
local function limits()
	reset("9a repeat limit")
	R().overrides.maxRepeats = 1
	local tree, ok = chopToRest("limit1")
	if ok then
		setEnd(0.97)
		ok = waitUntil(function() local c = current(); return state() == nil and c and c.Type == "ISChopTreeAction" and c:isStarted() end, 1500, "limit resume")
		check(ok, "first resume happens")
		waitTicks(60)
		setEnd(0.05)
		waitTicks(400)
		check(state() == nil, "second stop: limit reached, no rest")
		check(R().counts[p():getPlayerNum()] == nil, "count cleared")
	end
	removeTree(tree)

	reset("9b moodle limit while resting")
	R().overrides.moodleLimit = 1
	tree, ok = chopToRest("moodle")
	if ok then
		stats():set(CharacterStat.THIRST, 0.9)
		ok = waitUntil(function() return state() == nil end, 900, "moodle cancel")
		check(ok, "thirst above limit cancels the rest", moodle(MoodleType.THIRST))
	end
	removeTree(tree)

	reset("9c moodle limit at stop")
	R().overrides.moodleLimit = 0
	stats():set(CharacterStat.HUNGER, 0.5)
	waitTicks(60)
	local x, y, z = base()
	tree = addTree(x, y - 2, z)
	giveAxe()
	ISWorldObjectContextMenu.doChopTree(p(), tree)
	waitUntil(function() local c = current(); return c and c.Type == "ISChopTreeAction" and c:isStarted() end, 900)
	setEnd(0.05)
	waitTicks(300)
	check(state() == nil, "hungry at stop (limit 0): no rest", moodle(MoodleType.HUNGRY))
	removeTree(tree)
end

------------------------------------------------------------------ driver
local SCENARIOS = {
	{ "fitnessUI", fitnessUI }, { "fitnessNoUI", fitnessNoUI }, { "chop", chop }, { "areaTasks", areaTasks },
	{ "zombie", zombie }, { "playerCancel", playerCancel }, { "pain", pain }, { "restOnly", restOnly }, { "limits", limits },
	{ "end", function() reset("end") end },
}

-- one coroutine per scenario: an error ends that scenario only (no yield across pcall)
function T.onTick()
	if T.done then return end
	if not T.co then
		T.idx = (T.idx or 0) + 1
		local sc = SCENARIOS[T.idx]
		if not sc then
			T.scenario = "summary"
			log("SUMMARY pass=" .. T.pass .. " fail=" .. T.fail)
			T.done = true
			Events.OnTick.Remove(T.onTick)
			return
		end
		T.co = coroutine.create(sc[2])
	end
	local ok, err = coroutine.resume(T.co)
	if not ok then check(false, "scenario error", err) end
	if not ok or coroutine.status(T.co) == "dead" then T.co = nil end
end

function T.start()
	T.pass, T.fail, T.done, T.idx, T.co = 0, 0, false, 0, nil
	T.startedAt = getTimestamp()
	check(R() ~= nil and R().installed, "mod installed")
	check(AreaTasks ~= nil and R().areaInstalled, "AreaTasks adapter installed")
	Events.OnTick.Remove(T.onTick)
	Events.OnTick.Add(T.onTick)
	log("started")
end

function T.poll()
	if T.done then
		log("done pass=" .. T.pass .. " fail=" .. T.fail)
		return
	end
	if getTimestamp() - (T.startedAt or 0) > 2400 then
		check(false, "overall timeout")
		Events.OnTick.Remove(T.onTick)
		return
	end
	log("running", T.scenario, "pass=" .. T.pass, "fail=" .. T.fail)
	PZTest.step("wait 300")
	PZTest.step("lua RARTest.poll()")
end
