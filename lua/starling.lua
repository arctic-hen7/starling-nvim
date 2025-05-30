local cmp = require("cmp")

local augroup = vim.api.nvim_create_augroup("Starling", { clear = true })

-- Function to check if the cursor is inside square brackets
--
-- Returns 2 if the user is in new square brackets, 1 if they're just in them generally,
-- and 0 if they aren't at all.
local function is_inside_square_brackets(line, col)
	-- Can't be between brackets if we're at the first or last characters in the line
	if col == 0 or col == #line then
		return 0
	end

	local bracket_somewhere_before_cursor = line:sub(1, col):find("%[") ~= nil
	local bracket_directly_before_cursor = line:sub(col, col) == "["
	local bracket_directly_after_cursor = line:sub(col + 1, col + 1) == "]"

	if bracket_directly_before_cursor and bracket_directly_after_cursor then
		return 2
	elseif bracket_somewhere_before_cursor and bracket_directly_after_cursor then
		return 1
	else
		return 0
	end
end

local uv = vim.loop
if not vim.g.starling_cache then
	vim.g.starling_cache = {}
	vim.g.starling_cache_time = nil
end

local STARLING_HOST = "localhost"
local STARLING_PORT = 3000

-- Makes a request to the Starling server.
local function make_server_request(method, endpoint, req_data, success_cb, error_cb)
	local stdout = uv.new_pipe(false)
	local stderr = uv.new_pipe(false)

	local parsed = nil
	local err = nil

	local handle
	handle = uv.spawn(
		"curl",
		{
			args = {
				-- The server is local, we should connect instantly or it isn't running
				"--connect-timeout",
				"1",
				-- The whole request should be very quick
				"--max-time",
				"10",
				-- No extra stderr
				"-s",
				-- Request the nodes in markdown format
				"-X",
				method,
				"http://" .. STARLING_HOST .. ":" .. STARLING_PORT .. endpoint,
				"-H",
				"Content-Type: application/json",
				"-d",
				vim.fn.json_encode(req_data),
			},
			stdio = { nil, stdout, stderr },
		},
		vim.schedule_wrap(function(code) -- this function is called when the process exits
			stdout:read_stop()
			stderr:read_stop()
			stdout:close()
			stderr:close()
			-- Guaranteed to exist, this just silences a warning
			if handle and not handle:is_closing() then
				handle:close()
			end

			-- This happening isn't a massive deal
			if code == 28 then
				err = { "Failed to make Starling request, server not running", vim.log.levels.WARN }
				error_cb(err)
			elseif code ~= 0 then
				err = { "Failed to make Starling request, curl failed with code: " .. code, vim.log.levels.WARN }
				error_cb(err)
			end
		end)
	)

	local stdout_buffer = ""
	uv.read_start(
		stdout,
		vim.schedule_wrap(function(stdout_err, data)
			if stdout_err then
				err = {
					"Failed to make Starling request, error reading from stdout: " .. stdout_err,
					vim.log.levels.ERROR,
				}
				error_cb(err)
				return
			end

			if data then
				stdout_buffer = stdout_buffer .. data
			else
				-- EOF, process the collected response (if there is one)
				if handle then
					handle:close()
				end
				if #stdout_buffer == 0 then
				-- This will happen if curl fails, and we should already have a message about that
				else
					local success, result = pcall(vim.fn.json_decode, stdout_buffer)
					if not success then
						err = { "Error parsing Starling response: " .. result, vim.log.levels.ERROR }
						error_cb(err)
					else
						parsed = result
						success_cb(parsed)
					end
				end
			end
		end)
	)

	if not handle then
		err = { "Failed to make Starling request, couldn't spawn curl process", vim.log.levels.ERROR }
		error_cb(err)
	end
end

-- Function that updates the node data from the server asynchronously. This is executed
-- periodically to avoid constant locking on the server.
local function update_nodes(force)
	-- Return early if we updated fewer than five seconds ago
	if not force and vim.g.starling_cache_time and os.time() - vim.g.starling_cache_time < 5 then
		return
	end

	make_server_request("GET", "/nodes", { conn_format = "markdown" }, function(data)
		vim.g.starling_cache = data
		vim.g.starling_cache_time = os.time()
	end, function(err, level)
		vim.notify(err, level)
	end)
	-- Probably not necessary to update this continuously, but it makes for very elegant real-time
	-- migration if the user changes their Starling directory
	make_server_request("GET", "/info/root", {}, function(data)
		vim.g.starling_cache_root = data
	end, function(err, level)
		vim.notify(err, level)
	end)
end

-- Tracks whether or not completion is active
local completion_active = false

-- Function that handles when the user is typing to manually trigger completion
local function handle_typing()
	local _, col = unpack(vim.api.nvim_win_get_cursor(0))
	local line = vim.api.nvim_get_current_line()

	-- Only complete if we haven't been in square brackets for a while to avoid
	-- constantly calling complete (gets messy and slow)
	local bracket_status = is_inside_square_brackets(line, col)
	if bracket_status == 2 or (bracket_status == 1 and not completion_active) then
		completion_active = true
		cmp.complete({
			config = {
				sources = {
					{ name = "starling" },
				},
			},
		})
	elseif not is_inside_square_brackets(line, col) then
		completion_active = false
	end
end

local source = {}
source.new = function()
	return setmetatable({}, { __index = source })
end

source.complete = function(self, params, callback)
	-- If we don't have a cache, create one and fail completion for now
	if not vim.g.starling_cache then
		update_nodes(true)
		return false
	end

	local items = {}
	for _, item in ipairs(vim.g.starling_cache) do
		local uuid = item["id"]
		local title = table.concat(item["title"], "/")
		local path = item["path"]

		-- The completion should replace the brackets with the link in Markdown form
		table.insert(items, {
			label = title,
			documentation = "Path: " .. path,
			textEdit = {
				range = {
					start = { line = params.context.cursor.line, character = params.context.cursor.character - 1 },
					["end"] = { line = params.context.cursor.line, character = params.context.cursor.character + 1 },
				},
				newText = "[" .. title .. "](" .. uuid .. ")",
			},
		})
	end
	callback({ items = items })
end

-- Extracts the UUID from a Markdown link if there is one (i.e. if it's a Starling-style link).
local function extract_uuid_from_link()
	local line = vim.api.nvim_get_current_line()
	local col = vim.api.nvim_win_get_cursor(0)[2] + 1

	-- Find Markdown link pattern
	local pattern = "%[.-%]%(((.*):([a-zA-Z0-9-]+))%)"

	-- Ignore the title and link specifier
	local start, _, _, _, uuid = line:find(pattern)

	if start and start <= col and col <= #line then
		return uuid
	end
	return nil
end

-- Opens the link at the cursor if the cursor is at a link
local function open_link()
	local uuid = extract_uuid_from_link()
	if uuid then
		-- Get the path associated with the link
		make_server_request("GET", "/node/" .. uuid, { conn_format = "markdown" }, function(data)
			-- We make this absolute using the cached root path
			vim.cmd("edit " .. vim.g.starling_cache_root .. "/" .. data.path)
		end, function(err, level)
			vim.notify(err, level)
		end)
	else
		print("Not on Starling link")
	end
end

local function gf_passthrough()
	if extract_uuid_from_link() then
		return "<cmd>StarlingOpenLink<CR>"
	else
		return "gf"
	end
end

local reload_timers = {}

-- Sets up automatic reloading of the given buffer on a timer.
local function setup_autoreload(buf)
	-- Stop any existing timers before we start a new one
	if reload_timers[buf] then
		uv.timer_stop(reload_timers[buf])
		uv.close(reload_timers[buf])
	end
	local timer = uv.new_timer()
	reload_timers[buf] = timer

	local delay = 1000
	uv.timer_start(
		timer,
		delay,
		delay,
		vim.schedule_wrap(function()
			if vim.api.nvim_get_current_buf() == buf then
				vim.cmd("checktime")
			end
		end)
	)
end

-- Stops automatic reloading of the given buffer.
local function stop_autoreload(buf)
	if reload_timers[buf] then
		uv.timer_stop(reload_timers[buf])
		uv.close(reload_timers[buf])
		reload_timers[buf] = nil
	end
end

local function setup()
	-- Update the nodes cache regularly
	vim.api.nvim_create_autocmd({ "BufEnter", "InsertEnter", "InsertLeave" }, {
		pattern = { "*.md", "*.markdown" },
		group = augroup,
		callback = update_nodes,
	})

	-- Manually trigger completion
	vim.api.nvim_create_autocmd({ "CursorMovedI", "TextChangedI" }, {
		pattern = { "*.md", "*.markdown" },
		group = augroup,
		callback = handle_typing,
	})
	require("cmp").register_source("starling", source.new())

	-- Create a user command for opening links
	vim.api.nvim_create_user_command("StarlingOpenLink", open_link, {})
	vim.api.nvim_create_autocmd({ "BufEnter" }, {
		pattern = { "*.md", "*.markdown" },
		group = augroup,
		callback = function()
			vim.keymap.set("n", "gf", gf_passthrough, { noremap = false, silent = true, expr = true, buffer = true })
		end,
	})

	-- Whenever we enter Markdown buffers, set up automatic reloading
	vim.api.nvim_create_autocmd("BufEnter", {
		pattern = "*.md",
		callback = function(args)
			setup_autoreload(args.buf)
		end,
	})
	-- And stop it whenever we leave them
	vim.api.nvim_create_autocmd("BufLeave", {
		pattern = "*.md",
		callback = function(args)
			stop_autoreload(args.buf)
		end,
	})
	-- In addition to that, explicitly reload after every write (in case Starling fixes things for us)
	vim.api.nvim_create_autocmd({ "BufWritePost" }, {
		pattern = { "*.md", "*.markdown" },
		group = augroup,
		callback = function()
			-- Must defer for longer than the debounce timeout!
			vim.defer_fn(function()
				vim.cmd("checktime")
			end, 500)
		end,
	})
end

return { setup = setup }
