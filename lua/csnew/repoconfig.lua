local dotnet = require("csnew.dotnet")

local M = {}

local cache = {}

function M.load()
	local root = dotnet.workspace_root()
	local path = root .. "/.csnew.lua"
	local stat = vim.uv.fs_stat(path)
	if not stat then
		cache[root] = nil
		return nil
	end

	local entry = cache[root]
	if entry and entry.sec == stat.mtime.sec and entry.nsec == stat.mtime.nsec then
		if entry.denied then
			return nil
		end
		return entry.config
	end

	local contents = vim.secure.read(path)
	if not contents then
		cache[root] = { sec = stat.mtime.sec, nsec = stat.mtime.nsec, denied = true }
		return nil
	end

	local chunk, load_err = load(contents, "@" .. path, "t", {})
	if not chunk then
		if not entry or entry.notify ~= load_err then
			vim.notify("csnew: invalid .csnew.lua\n" .. load_err, vim.log.levels.ERROR)
		end
		cache[root] = { sec = stat.mtime.sec, nsec = stat.mtime.nsec, notify = load_err }
		return nil
	end

	local ok, result = pcall(chunk)
	if not ok or type(result) ~= "table" then
		local err = ok and ".csnew.lua must return a table" or result
		if not entry or entry.notify ~= err then
			vim.notify("csnew: invalid .csnew.lua\n" .. tostring(err), vim.log.levels.ERROR)
		end
		cache[root] = { sec = stat.mtime.sec, nsec = stat.mtime.nsec, notify = err }
		return nil
	end

	cache[root] = { sec = stat.mtime.sec, nsec = stat.mtime.nsec, config = result }
	return result
end

return M
