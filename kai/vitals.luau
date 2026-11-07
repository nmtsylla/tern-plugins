--!nonstrict
-- Vitals for Kai: one probe round for the machine the shown session runs on,
-- parsed into the numbers the sidebar's Vitals section draws. The probe is
-- POSIX shell, local or over ssh; no program is installed on a host.

local MAX_POINTS = 180
local MAX_BANDS = 24
local SEGMENTS = 16
local PEAK_HOLD = 2
local EVERY_MS = 2000

local Vitals = {}
local PROBE = tern.fs.read("probe.sh")
local WINDOWS = tern.runtime.os == "windows"

local state = {
	history = {}, peaks = {}, prev = {}, reading = {}, error = {},
	last = {}, inflight = {}, saves = {}, key = nil,
}

local function trim(text)
	return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function first(lines)
	return lines and lines[1] or ""
end

local function fields(line)
	local out = {}
	for word in tostring(line or ""):gmatch("%S+") do out[#out + 1] = word end
	return out
end

local function number(value, default)
	local n = tonumber(value)
	if n == nil then return default or 0 end
	return n
end

local function clamp(value, low, high)
	return math.max(low, math.min(high, value))
end

local function rate(before, now, seconds)
	if not before or now < before or seconds <= 0 then return 0 end
	return (now - before) / seconds
end

local function uptime_text(seconds)
	seconds = math.max(0, math.floor(seconds or 0))
	local days = math.floor(seconds / 86400)
	local hours = math.floor((seconds % 86400) / 3600)
	local minutes = math.floor((seconds % 3600) / 60)
	if days >= 2 then return string.format("%dd", days) end
	if hours > 0 then return string.format("%dh", hours) end
	return string.format("%dm", minutes)
end

local function disk_name(mount)
	if mount == "/" then return "/" end
	return mount:match("([^/]+)/*$") or mount
end

local function pct_level(value)
	if value >= 90 then return "hot" end
	if value >= 80 then return "warn" end
	return "ok"
end

local function load_level(value)
	if value >= 1.5 then return "hot" end
	if value >= 1.0 then return "warn" end
	return "ok"
end

local function rank(level)
	if level == "hot" then return 2 end
	if level == "warn" then return 1 end
	return 0
end

local function assess(r)
	local level, why = "ok", ""
	local function worse(l, w)
		if rank(l) > rank(level) then level, why = l, w end
	end
	worse(pct_level(r.cpu), "cpu")
	worse(pct_level(r.mem), "memory")
	if r.swapTotal > 0 and r.swap >= 50 then worse("warn", "swap") end
	worse(load_level(r.loadPerCore), "load")
	for _, disk in ipairs(r.disks or {}) do
		worse(pct_level(disk.pct), disk_name(disk.mount))
	end
	return level, why
end

-- ── probe parsing ─────────────────────────────────────────────────────────

local function sections(text)
	local out, current = {}, nil
	for line in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
		local name = line:match("^@@([%w_]+)$")
		if name then
			current = {}
			out[name] = current
		elseif current then
			current[#current + 1] = (line:gsub("\r$", ""))
		end
	end
	return out
end

local function parse_df(lines)
	local out, seen = {}, {}
	for _, line in ipairs(lines or {}) do
		local f = fields(line)
		if #f >= 6 and f[1] ~= "Filesystem" then
			local dev, mount = f[1], table.concat(f, " ", 6, #f)
			local size, used = number(f[2]) * 1024, number(f[3]) * 1024
			local ok = size >= 1073741824 and not seen[dev] and mount ~= ""
			if ok then
				local skip = dev == "tmpfs" or dev == "devtmpfs" or dev == "overlay" or dev == "udev"
					or dev == "none" or dev == "shm" or dev == "efivarfs" or dev == "devfs"
					or dev == "map" or dev == "squashfs" or dev:match("^/dev/loop")
				for _, p in ipairs({
					"/snap", "/run", "/sys", "/proc", "/dev", "/boot", "/var/lib/docker", "/private/var/vm",
					"/Volumes/Recovery", "/Library/Developer/CoreSimulator", "/private/var/run/com.apple.security.cryptexd",
				}) do
					if mount == p or mount:sub(1, #p + 1) == p .. "/" then skip = true end
				end
				if mount:sub(1, 16) == "/System/Volumes/" and mount ~= "/System/Volumes/Data" then skip = true end
				if not skip then
					seen[dev] = true
					out[#out + 1] = {
						mount = mount,
						size = size,
						used = used,
						avail = number(f[4]) * 1024,
						pct = if size > 0 then 100 * used / size else 0,
					}
				end
			end
		end
	end
	return out
end

local function real_interface(name)
	for _, p in ipairs({
		"lo", "veth", "docker", "br-", "virbr", "cni", "flannel", "cali", "vnet",
		"tailscale", "wg", "tun", "utun", "awdl", "llw", "bridge", "gif", "stf", "anpi", "ap", "zt",
	}) do
		if name:sub(1, #p) == p then return false end
	end
	return true
end

local function parse_net_darwin(lines)
	local rx, tx = 0, 0
	for _, line in ipairs(lines or {}) do
		local f = fields(line)
		if #f >= 10 and f[3]:sub(1, 5) == "<Link" and real_interface(f[1]) then
			rx += number(f[#f - 4])
			tx += number(f[#f - 1])
		end
	end
	return rx, tx
end

local function parse_net_linux(lines)
	local rx, tx = 0, 0
	for _, line in ipairs(lines or {}) do
		local name, rest = line:match("^%s*([^:]+):(.*)$")
		if name and real_interface(trim(name)) then
			local f = fields(rest)
			rx += number(f[1])
			tx += number(f[9])
		end
	end
	return rx, tx
end

local function cpu_values(line)
	local f = fields(line)
	local t = {}
	for i = 1, 8 do t[i] = number(f[i + 1]) end
	return t
end

local function cpu_total(t)
	local total = 0
	for i = 1, 8 do total += t[i] or 0 end
	return total
end

local function cpu_busy(before, after)
	if not before then return nil end
	local total = cpu_total(after) - cpu_total(before)
	if total <= 0 then return nil end
	local idle = ((after[4] or 0) + (after[5] or 0)) - ((before[4] or 0) + (before[5] or 0))
	return clamp(100 * (total - idle) / total, 0, 100)
end

local function cpu_part(before, after, index)
	if not before then return 0 end
	local total = cpu_total(after) - cpu_total(before)
	if total <= 0 then return 0 end
	local delta = (after[index] or 0) - (before[index] or 0)
	return clamp(100 * delta / total, 0, 100)
end

local function parse_linux(r, sec, key)
	local prev = state.prev[key]
	local now = tern.now()
	local cpu_line, per_lines = nil, {}
	for _, line in ipairs(sec.stat or {}) do
		local name = line:match("^(%a+%d*)%s")
		if name == "cpu" then cpu_line = line
		elseif name and name:match("^cpu%d+$") then per_lines[#per_lines + 1] = line end
	end
	local values = cpu_line and cpu_values(cpu_line)
	local before = prev and prev.cpu
	if values and before then
		r.cpu = cpu_busy(before, values) or 0
		r.user = cpu_part(before, values, 1) + cpu_part(before, values, 2)
		r.system = cpu_part(before, values, 3)
		r.iowait = cpu_part(before, values, 5)
		r.warming = false
		for i, line in ipairs(per_lines) do
			local was = prev.cores and prev.cores[i]
			local busy = was and cpu_busy(was, cpu_values(line))
			if busy then r.perCore[#r.perCore + 1] = busy end
		end
	else
		r.warming = true
	end
	r.cores = #per_lines

	local mem = {}
	for _, line in ipairs(sec.meminfo or {}) do
		local k, v = line:match("^(%w+):%s+(%d+)")
		if k then mem[k] = number(v) * 1024 end
	end
	r.memTotal = mem.MemTotal or 0
	local available = mem.MemAvailable or mem.MemFree or 0
	r.memUsed = math.max(0, r.memTotal - available)
	r.mem = if r.memTotal > 0 then 100 * r.memUsed / r.memTotal else 0
	r.swapTotal = mem.SwapTotal or 0
	local swap_used = math.max(0, (mem.SwapTotal or 0) - (mem.SwapFree or 0))
	r.swap = if r.swapTotal > 0 then 100 * swap_used / r.swapTotal else 0

	local load_line = first(sec.loadavg)
	local lf = fields(load_line)
	r.load = { number(lf[1]), number(lf[2]), number(lf[3]) }
	r.loadPerCore = if r.cores > 0 then r.load[1] / r.cores else 0

	r.uptime = uptime_text(number((first(sec.uptime):match("^([%d.]+)"))))

	local rx, tx = parse_net_linux(sec.netdev)
	local seconds = if prev then math.max(0.2, (now - prev.t) / 1000) else 0
	r.netRx = rate(prev and prev.rx, rx, seconds)
	r.netTx = rate(prev and prev.tx, tx, seconds)
	r.disks = parse_df(sec.df)

	local cores = {}
	for i, line in ipairs(per_lines) do cores[i] = cpu_values(line) end
	state.prev[key] = {
		t = now, rx = rx, tx = tx, cpu = values, cores = cores,
	}
end

local function parse_darwin(r, sec, key)
	local prev = state.prev[key]
	local now = tern.now()
	local cores, mem_total = 0, 0
	local load = { 0, 0, 0 }
	local boot, swap_total, swap_used = 0, 0, 0
	local ints = 0
	for _, line in ipairs(sec.sysctl or {}) do
		line = trim(line)
		local lf = fields(line)
		if line:sub(1, 1) == "{" and #lf >= 3 and lf[2]:match("^[%d.]+$") then
			load = { number(lf[2]), number(lf[3]), number(lf[4]) }
		elseif line:match("sec =") then
			boot = number(line:match("sec = (%d+)"))
		elseif line:match("total =") then
			local total, total_unit, used, used_unit = line:match("total = ([%d.]+)([KMGT])%s+used = ([%d.]+)([KMGT])")
			local mult = { K = 1024, M = 1024 ^ 2, G = 1024 ^ 3, T = 1024 ^ 4 }
			if total then
				swap_total = number(total) * (mult[total_unit] or 1)
				swap_used = number(used) * (mult[used_unit] or 1)
			end
		elseif line:match("^%d+$") then
			ints += 1
			if ints == 1 then cores = number(line)
			elseif ints == 2 then mem_total = number(line) end
		end
	end
	r.cores, r.memTotal = cores, mem_total
	r.load, r.loadPerCore = load, if cores > 0 then load[1] / cores else 0
	r.swapTotal = swap_total
	r.swap = if swap_total > 0 then 100 * swap_used / swap_total else 0
	r.uptime = uptime_text(os.time() - boot)

	local page = 4096
	local pages = {}
	for _, line in ipairs(sec.vmstat or {}) do
		local size = line:match("page size of (%d+) bytes")
		if size then page = number(size) end
		local k, v = line:match("^(.-):%s*(%d+)%.?%s*$")
		if k then pages[trim(k)] = number(v) end
	end
	local used = ((pages["Pages active"] or 0) + (pages["Pages wired down"] or 0) + (pages["Pages occupied by compressor"] or 0)) * page
	r.memUsed = math.max(0, math.min(used, mem_total))
	r.mem = if mem_total > 0 then 100 * r.memUsed / mem_total else 0

	-- iostat samples a second; its last row is the live one. If it is not
	-- there, ps's total is the fallback herdr-vitals uses on a Mac.
	local cpu_line = ""
	for _, line in ipairs(sec.cpu or {}) do
		if line:match("^%s*[%d.]+%s+[%d.]+%s+[%d.]+") then cpu_line = line end
	end
	local parsed_cpu = false
	if cpu_line ~= "" then
		local f = fields(cpu_line)
		-- iostat's row ends with us, sy, id and the three load averages.
		local n = #f
		if n >= 6 then
			r.user, r.system = number(f[n - 5]), number(f[n - 4])
			r.cpu = clamp(r.user + r.system, 0, 100)
			parsed_cpu = true
		end
	end
	if not parsed_cpu then
		local total = 0
		for _, line in ipairs(sec.ps or {}) do total += number(trim(line)) end
		r.cpu = if cores > 0 then clamp(total / cores, 0, 100) else 0
	end
	r.warming = false

	local rx, tx = parse_net_darwin(sec.netstat)
	local seconds = if prev then math.max(0.2, (now - prev.t) / 1000) else 0
	r.netRx = rate(prev and prev.rx, rx, seconds)
	r.netTx = rate(prev and prev.tx, tx, seconds)
	r.disks = parse_df(sec.df)
	-- The data volume is where a Mac's files live; the sealed system volume
	-- is the same size and would only repeat it.
	local has_data = false
	for _, disk in ipairs(r.disks) do
		if disk.mount == "/System/Volumes/Data" then has_data = true end
	end
	if has_data then
		for i = #r.disks, 1, -1 do
			if r.disks[i].mount == "/" then table.remove(r.disks, i) end
		end
	end
	state.prev[key] = { t = now, rx = rx, tx = tx }
end

local function parse(text, key)
	local sec = sections(text)
	local os_name = trim(first(sec.os))
	local r = {
		os = if os_name == "Darwin" then "darwin" else "linux",
		host = trim(first(sec.host)),
		release = trim(first(sec.release)),
		kernel = trim(first(sec.kernel)),
		arch = trim(first(sec.arch)),
		cores = 0, uptime = "", warming = false,
		cpu = 0, user = 0, system = 0, iowait = 0, perCore = {},
		load = { 0, 0, 0 }, loadPerCore = 0,
		mem = 0, memTotal = 0, memUsed = 0, swap = 0, swapTotal = 0,
		netRx = 0, netTx = 0, disks = {},
	}
	if r.os == "darwin" then
		parse_darwin(r, sec, key)
	else
		parse_linux(r, sec, key)
	end
	r.level, r.why = assess(r)
	return r
end

-- ── history and bands ─────────────────────────────────────────────────────

local function history_of(key)
	local points = state.history[key]
	if not points then
		local stored = tern.kv.get("vitals-history:" .. key)
		points = if type(stored) == "table" then stored else {}
		for i = #points, 1, -1 do
			local p = points[i]
			if type(p) ~= "table" or type(p.c) ~= "number" then table.remove(points, i) end
		end
		state.history[key] = points
	end
	return points
end

local function save_history(key)
	tern.kv.set("vitals-history:" .. key, state.history[key] or {})
end

local function bands_for(r, points)
	if #r.perCore > 0 then
		local per = math.ceil(#r.perCore / MAX_BANDS)
		local out = {}
		for i = 1, #r.perCore, per do
			local sum, count = 0, 0
			for j = i, math.min(i + per - 1, #r.perCore) do
				sum += r.perCore[j]
				count += 1
			end
			out[#out + 1] = sum / count
		end
		return out
	end
	local out = {}
	local take = math.min(MAX_BANDS, #points)
	local offset = MAX_BANDS - take
	for i = 1, MAX_BANDS do out[i] = 0 end
	for i = 1, take do out[offset + i] = points[#points - take + i].c or 0 end
	return out
end

local function update_peaks(key, bands)
	local peaks = state.peaks[key] or {}
	for i = 1, #bands do
		local lit = math.floor(clamp(bands[i], 0, 100) / 100 * SEGMENTS + 0.5)
		local peak = peaks[i] or { at = 0, hold = 0 }
		if lit >= peak.at then
			peak = { at = lit, hold = PEAK_HOLD }
		elseif peak.hold > 0 then
			peak.hold -= 1
		else
			peak.at = math.max(lit, peak.at - 1)
			peak.hold = 0
		end
		peaks[i] = peak
	end
	state.peaks[key] = peaks
	return peaks
end

local function record(r, key)
	local points = history_of(key)
	if not r.warming then
		points[#points + 1] = {
			t = os.time(), c = r.cpu, l = r.loadPerCore, m = r.mem,
			n = r.netRx + r.netTx, d = 0,
		}
		while #points > MAX_POINTS do table.remove(points, 1) end
		state.saves[key] = (state.saves[key] or 0) + 1
		if state.saves[key] >= 5 then
			save_history(key)
			state.saves[key] = 0
		end
	end
	local bands = bands_for(r, points)
	r.bands = bands
	r.peaks = update_peaks(key, bands)
end


-- ── host and sampling ─────────────────────────────────────────────────────

local function key_of(host)
	if not host or host.kind == "local" then return "local" end
	return "h" .. tostring(host.id)
end

local function host_label(host)
	if not host or host.kind == "local" then return "this computer" end
	return host.name or host.address or "remote"
end

local function host_address(host)
	if type(host.address) ~= "string" or host.address == "" then return nil end
	return host.address
end

local function run(cx, host, key, done)
	if WINDOWS then
		state.error[key] = "Vitals reads macOS and Linux hosts."
		done()
		return
	end
	local argv, opts
	if host.kind == "local" then
		argv = { "/bin/sh", "-c", PROBE }
		opts = { timeout_ms = 8000 }
	else
		local address = host_address(host)
		if not address then
			state.error[key] = "This host has no ssh address yet."
			done()
			return
		end
		local endpoint, port = address:match("^(.-):(%d+)$")
		argv = { "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=4", "-o", "ServerAliveInterval=5" }
		if port then
			argv[#argv + 1] = "-p"
			argv[#argv + 1] = port
			argv[#argv + 1] = endpoint
		else
			argv[#argv + 1] = address
		end
		argv[#argv + 1] = "sh"
		argv[#argv + 1] = "-s"
		opts = { stdin = PROBE, timeout_ms = 12000 }
	end
	state.inflight[key] = true
	local ok, err = pcall(tern.process.run, argv, opts, function(result, c)
		state.inflight[key] = false
		if not c then return end
		if result.timed_out or result.status ~= 0 then
			local message = trim(result.stderr)
			if result.timed_out then message = "Timed out reading the machine." end
			if message == "" then message = "Could not read the machine (exit " .. tostring(result.status) .. ")." end
			state.error[key] = message
			done()
			return
		end
		local parsed_ok, reading = pcall(parse, result.stdout, key)
		if not parsed_ok then
			state.error[key] = tostring(reading)
			done()
			return
		end
		state.error[key] = nil
		state.reading[key] = reading
		record(reading, key)
		done()
	end)
	if not ok then
		state.inflight[key] = false
		state.error[key] = tostring(err)
		done()
	end
end

-- Called from Kai's own 750 ms tick: reads the current host when its reading is due.
function Vitals.tick(cx, done)
	local ok, host = pcall(function() return cx.hosts:current() end)
	if not ok or not host then return end
	local key = key_of(host)
	if state.key ~= key then
		state.key = key
		state.last[key] = nil
	end
	local last = state.last[key]
	if state.inflight[key] or (last and tern.now() - last < EVERY_MS) then return end
	state.last[key] = tern.now()
	run(cx, host, key, done)
end

-- The section's model; cheap enough for Kai's 750 ms draw.
function Vitals.model(cx)
	local ok, host = pcall(function() return cx.hosts:current() end)
	if not ok or not host then return nil end
	local key = key_of(host)
	local points = history_of(key)
	local reading = state.reading[key]
	return {
		host = host_label(host),
		remote = host.kind ~= "local",
		reading = reading,
		history = points,
		error = state.error[key],
		level = reading and reading.level or nil,
		why = reading and reading.why or "",
	}
end

return Vitals
