-- Minimal stub of KOReader's ffi/util, for tests/test_engine.lua.
--
-- Deliberately mirrors the real module: ffi/util has NO writeToFile (the engine
-- used to call it and broke on the device). If that ever comes back, the unit
-- test fails here instead of on the Kindle.
local M = {}
function M.execute() return 0 end
function M.template(s, t) return (s:gsub("%%(%w+)", t)) end
return M
