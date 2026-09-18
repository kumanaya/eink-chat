-- Minimal stub of KOReader's UIManager, for tests/test_engine.lua.
-- Methods (":"), because the engine calls UIManager:scheduleIn(...).
local M = {}
function M:scheduleIn() end
function M:unschedule() end
function M:setDirty() end
function M:show() end
function M:close() end
return M
