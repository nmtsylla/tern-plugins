--!nonstrict
-- Vitals: the model comes from window.luau, this file only draws it with
-- Tern-native nodes. Every node that can change carries a stable key, so
-- Tern's view diff updates it in place. styles.css sets dimensions and theme
-- colours; it never sets a color of its own.
local ui = tern.ui
local View = {}

local function el(tag, props, children)
	props = props or {}
	return ui.el(tag, props, children)
end

local function text(value, style)
	return ui.text({ ui.span(tostring(value), style) })
end

local function icon(name, tone, key)
	return ui.node("icon", { key = key or name, name = name, tone = tone or "muted" })
end

local function pct(value)
	return string.format("%d%%", math.floor((tonumber(value) or 0) + 0.5))
end

local function big(value)
	return string.format("%d", math.floor((tonumber(value) or 0) + 0.5))
end

local function bytes(n, per_second)
	n = tonumber(n) or 0
	local units = { "B", "KB", "MB", "GB", "TB" }
	local i = 1
	while n >= 1000 and i < #units do
		n = n / 1000
		i += 1
	end
	local s
	if n >= 10 or i == 1 then
		s = string.format("%.0f", n)
	else
		s = string.format("%.1f", n)
	end
	return s .. " " .. units[i] .. if per_second then "/s" else ""
end

local function bytes_of(a, b)
	a, b = tonumber(a) or 0, tonumber(b) or 0
	if b <= 0 then return "" end
	local units = { "B", "KB", "MB", "GB", "TB" }
	local ia, ib = 1, 1
	local aa, bb = a, b
	while bb >= 1000 and ib < #units do
		aa, bb = aa / 1000, bb / 1000
		ia, ib = ia + 1, ib + 1
	end
	while aa >= 1000 and ia < #units do
		aa, ia = aa / 1000, ia + 1
	end
	local function one(v)
		if v >= 10 then return string.format("%.0f", v) end
		return string.format("%.1f", v)
	end
	if ia == ib then
		return one(aa) .. " of " .. one(bb) .. " " .. units[ib]
	end
	return one(aa) .. " " .. units[ia] .. " of " .. one(bb) .. " " .. units[ib]
end

local function disk_name(mount)
	if mount == "/" then return "/" end
	return mount:match("([^/]+)/*$") or mount
end

local function level_of(value)
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

local function assessment(reading)
	local level, why = "ok", ""
	local function worse(l, w)
		if rank(l) > rank(level) then level, why = l, w end
	end
	if not reading then return level, why end
	worse(level_of(reading.cpu), "cpu")
	worse(level_of(reading.mem), "memory")
	if reading.swapTotal > 0 and reading.swap >= 50 then worse("warn", "swap") end
	worse(load_level(reading.loadPerCore), "load")
	for _, disk in ipairs(reading.disks or {}) do
		worse(level_of(disk.pct), disk_name(disk.mount))
	end
	return level, why
end

local function level_text(level, why)
	if level == "ok" then return "OK" end
	return level:upper() .. (if why ~= "" then " " .. why else "")
end

-- The equalizer: a band per core (Linux) or the last readings (macOS), lit
-- from the bottom; green, then yellow, then red, with a faded peak.
local function equalizer(bands, peaks)
	local rows = {}
	local n = #bands
	if n == 0 then n = 24 end
	for b = 1, n do
		local value = bands[b]
		local lit = if value == nil then 0 else math.floor(math.max(0, math.min(100, value)) / 100 * 16 + 0.5)
		local peak = (peaks and peaks[b] and peaks[b].at) or 0
		local segs = {}
		for s = 0, 15 do
			local on = s < lit
			local cap = not on and peak > 0 and s == peak - 1
			local tone = if on or cap then (s >= 14 and "vbad" or s >= 10 and "vwarn" or "vok") else ""
			segs[#segs + 1] = el("div", {
				key = "s" .. tostring(s),
				class = "vitals-seg" .. if on then " on " .. tone else if cap then " peak " .. tone else "",
				role = "vitals.seg",
			})
		end
		rows[#rows + 1] = el("div", { key = "b" .. tostring(b), class = "vitals-band", role = "vitals.band" }, segs)
	end
	return el("div", { key = "eq", class = "vitals-eq", role = "vitals.eq" }, rows)
end

local function meter(value, opts)
	opts = opts or {}
	local count = 22
	local lit = math.floor(math.max(0, math.min(100, tonumber(value) or 0)) / 100 * count + 0.5)
	local segs = {}
	for i = 1, count do
		local tone = opts.tone
		if not tone then
			if i >= count * 0.9 then tone = "vbad"
			elseif i >= count * 0.8 then tone = "vwarn"
			else tone = "vok" end
		end
		segs[#segs + 1] = el("div", {
			key = "m" .. tostring(i),
			class = "vitals-mseg" .. if i <= lit then " on " .. tone else "",
			role = "vitals.mseg",
		})
	end
	return el("div", { key = "meter", class = "vitals-meter", role = "vitals.meter" }, segs)
end

local function height_class(value)
	local bucket = math.floor(math.max(0, math.min(100, tonumber(value) or 0)) / 5 + 0.5)
	return "vitals-h" .. tostring(bucket)
end

local function strip(history)
	local cols = {}
	local start = math.max(1, #history - 79)
	for i = start, #history do
		local p = history[i]
		local value = math.max(0, math.min(100, tonumber(p.c) or 0))
		local tone = if value >= 90 then "vbad" elseif value >= 80 then "vwarn" else "vok"
		cols[#cols + 1] = el("div", {
			key = "p" .. tostring(p.t or i),
			class = "vitals-strip-col " .. tone .. " " .. height_class(value),
			role = "vitals.stripcol",
			title = string.format("%s · %s", pct(value), os.date("%H:%M", p.t or 0)),
		})
	end
	return el("div", { key = "strip", class = "vitals-strip", role = "vitals.strip" }, cols)
end

local function row(label, meter_node, value, sub, key)
	local children = {
		el("div", { key = "label", class = "vitals-label", role = "vitals.label", text = label }),
		meter_node,
		el("div", { key = "value", class = "vitals-value", role = "vitals.value", text = value }),
	}
	if sub and sub ~= "" then
		children[#children + 1] = el("div", { key = "sub", class = "vitals-sub", role = "vitals.sub", text = sub })
	end
	return el("div", { key = key or label, class = "vitals-row", role = "vitals.row" }, children)
end

local function section(title, name, key)
	return el("div", { key = key or title, class = "vitals-section", role = "vitals.section" }, {
		icon(name or "activity", "muted", "icon"),
		el("div", { key = "title", class = "vitals-section-title", role = "vitals.sectiontitle", text = title }),
		el("div", { key = "rule", class = "vitals-rule", role = "vitals.rule" }),
	})
end

local function machine_trigger(host, open)
	return el("button", {
		key = "machine",
		class = "vitals-machine" .. if open then " open" else "",
		role = "vitals.machine",
		title = "Choose machine",
		actions = { click = "machines" },
	}, {
		icon(if host.kind == "local" then "monitor" else "server", "muted", "icon"),
		el("span", { key = "name", class = "vitals-machine-name", text = host.label }),
		icon("chev-r", "muted", "chev"),
	})
end

local function machine_menu(hosts, current)
	local rows = {}
	for _, host in ipairs(hosts) do
		local on = host.key == current
		local row = {
			icon(if host.kind == "local" then "monitor" else "server", if on then "accent" else "muted", "icon"),
			el("span", { key = "name", class = "vitals-mrow-name", text = host.label }),
		}
		if host.kind == "remote" and host.state ~= "connected" then
			row[#row + 1] = el("span", { key = "meta", class = "vitals-mrow-meta", text = host.state or "offline" })
		end
		if on then row[#row + 1] = icon("check", "accent", "check") end
		rows[#rows + 1] = el("button", {
			key = "m" .. host.key,
			class = "vitals-mrow" .. if on then " on" else "",
			role = "vitals.mrow",
			actions = { click = "machine=" .. host.key },
			title = host.address or host.label,
		}, row)
	end
	return el("div", { key = "menu", class = "vitals-menu", role = "vitals.menu" }, rows)
end

local function settings_panel(state)
	return el("div", { key = "settings", class = "vitals-settings", role = "vitals.settings" }, {
		el("button", {
			key = "compact", class = "vitals-srow", role = "vitals.srow", actions = { click = "compact" },
		}, {
			icon("monitor", "muted", "icon"),
			el("span", { key = "name", class = "vitals-srow-name", text = "Compact" }),
			el("span", { key = "value", class = "vitals-srow-value", text = if state.compact then "On" else "Off" }),
		}),
		el("button", {
			key = "interval", class = "vitals-srow", role = "vitals.srow", actions = { click = "interval" },
		}, {
			icon("activity", "muted", "icon"),
			el("span", { key = "name", class = "vitals-srow-name", text = "Refresh" }),
			el("span", { key = "value", class = "vitals-srow-value", text = tostring(math.floor(state.interval / 1000)) .. "s" }),
		}),
		el("button", {
			key = "reset", class = "vitals-srow", role = "vitals.srow", actions = { click = "reset-history" },
		}, {
			icon("x", "muted", "icon"),
			el("span", { key = "name", class = "vitals-srow-name", text = "Reset history" }),
		}),
	})
end

local function badge(level, why)
	return el("div", { key = "badge", class = "vitals-badge " .. level, role = "vitals.badge" }, {
		el("div", { key = "dot", class = "vitals-dot", role = "vitals.dot" }),
		el("div", { key = "text", class = "vitals-badge-text", text = level_text(level, why) }),
	})
end

local function foot_row(key, label, name, act)
	return el("button", {
		key = key, class = "vitals-footrow", role = "vitals.footrow",
		actions = { click = act },
	}, {
		icon(name, "muted", "icon"),
		el("span", { key = "label", class = "vitals-footrow-label", text = label }),
	})
end

local function footer()
	return el("div", { key = "foot", class = "vitals-foot", role = "vitals.foot" }, {
		el("div", { key = "rule", class = "vitals-rule", role = "vitals.rule" }),
		foot_row("settings", "Settings", "gear", "settings"),
		foot_row("add", "Add machine", "plus", "add-machine"),
	})
end

function View.render(state)
	local host = state.host or { key = "local", label = "This computer", kind = "local" }
	local reading = state.reading
	local level, why = assessment(reading)
	local cpu_bands = (reading and reading.bands) or {}
	local peaks = (reading and reading.peaks) or nil
	local compact = state.compact

	local body = {
		el("div", { key = "head", class = "vitals-head", role = "vitals.head" }, {
			icon("activity", "accent", "logo"),
			el("div", { key = "title", class = "vitals-title", role = "vitals.title", text = "Vitals" }),
			el("div", { key = "spacer", class = "vitals-spacer", role = "vitals.spacer" }),
			machine_trigger(host, state.machines),
			el("button", {
				key = "size", class = "vitals-iconbtn", role = "vitals.iconbtn",
				title = if compact then "More" else "Less",
				actions = { click = "compact" },
			}, { icon(if compact then "chev-r" else "chev", "muted", "icon") }),
			el("button", {
				key = "close", class = "vitals-iconbtn", role = "vitals.iconbtn", title = "Close",
				actions = { click = "close" },
			}, { icon("x", "muted", "icon") }),
		}),
	}
	if state.machines then body[#body + 1] = machine_menu(state.hosts or {}, host.key) end

	if not compact then
		local line = {
			el("div", { key = "hostname", class = "vitals-hostname", role = "vitals.hostname",
				text = if reading then reading.host else (state.error and "Not answering" or "Reading…") }),
		}
		if reading then
			line[#line + 1] = el("div", { key = "hostmeta", class = "vitals-hostmeta", role = "vitals.hostmeta",
				text = string.format("%s · %d cores · up %s", reading.release ~= "" and reading.release or reading.os, reading.cores, reading.uptime) })
		end
		line[#line + 1] = el("div", { key = "spacer", class = "vitals-spacer", role = "vitals.spacer" })
		if reading then line[#line + 1] = badge(level, why) end
		body[#body + 1] = el("div", { key = "hostline", class = "vitals-hostline", role = "vitals.hostline" }, line)
	end

	if state.error then
		body[#body + 1] = el("div", { key = "error", class = "vitals-error", role = "vitals.error", text = state.error })
	end

	local cpu_tone = if reading and reading.cpu >= 90 then "hot" elseif reading and reading.cpu >= 80 then "warn" else "ok"

	if not compact then
		body[#body + 1] = section(
			"CPU · " .. tostring(if reading and #reading.perCore > 0 then #reading.perCore .. " cores" else "the last 48 seconds"),
			"activity", "cpu-section")
	end
	local side = {}
	if compact then side[#side + 1] = badge(level, why) end
	side[#side + 1] = el("div", { key = "num", class = "vitals-cpunum " .. cpu_tone, role = "vitals.cpunum",
		text = if reading and not reading.warming then big(reading.cpu) else "–" })
	side[#side + 1] = el("div", { key = "cap", class = "vitals-cpucap", role = "vitals.cpucap", text = "% busy" })
	if reading and reading.os == "linux" and not reading.warming and not compact then
		side[#side + 1] = el("div", { key = "sub", class = "vitals-cpusub", role = "vitals.cpusub",
			text = string.format("user %d · sys %d%s", math.floor(reading.user + 0.5), math.floor(reading.system + 0.5),
				reading.iowait >= 1 and string.format(" · io %d", math.floor(reading.iowait + 0.5)) or "") })
	end
	body[#body + 1] = el("div", { key = "cpuflex", class = "vitals-cpuflex", role = "vitals.cpuflex" }, {
		equalizer(cpu_bands, peaks),
		el("div", { key = "side", class = "vitals-cpuside" .. if compact then " compact" else "", role = "vitals.cpuside" }, side),
	})

	if #((state.history or {})) > 0 and not compact then
		body[#body + 1] = strip(state.history)
	end

	local mem_sub = if reading then bytes_of(reading.memUsed, reading.memTotal) else ""
	if compact then
		body[#body + 1] = row("Memory", meter(reading and reading.mem or 0), if reading then pct(reading.mem) else "", mem_sub, "memory")
		local used, size = 0, 0
		for _, disk in ipairs(reading and reading.disks or {}) do
			used += disk.used
			size += disk.size
		end
		if size > 0 then
			body[#body + 1] = row("Disk", meter(100 * used / size), pct(100 * used / size), bytes_of(used, size), "disk")
		end
	else
		local net_max = 125000000
		local function net_pct(value)
			if not value or value <= 0 then return 0 end
			return math.min(100, math.log(value + 1) / math.log(net_max) * 100)
		end
		body[#body + 1] = section("Memory and load", "gauge", "mem-section")
		body[#body + 1] = row("Memory", meter(reading and reading.mem or 0), if reading then pct(reading.mem) else "", mem_sub, "memory")
		if reading and reading.swapTotal > 0 then
			body[#body + 1] = row("Swap", meter(reading.swap), pct(reading.swap), bytes(reading.swapTotal), "swap")
		end
		body[#body + 1] = row("Load",
			meter(math.min(100, (reading and reading.loadPerCore or 0) * 100)),
			if reading then string.format("%.2f", reading.load[1]) else "",
			if reading then string.format("%.2f a core", reading.loadPerCore) else "", "load")
		body[#body + 1] = section("Network", "globe", "net-section")
		body[#body + 1] = row("In", meter(net_pct(reading and reading.netRx), { tone = "accent" }),
			if reading then bytes(reading.netRx, true) else "", "", "in")
		body[#body + 1] = row("Out", meter(net_pct(reading and reading.netTx), { tone = "live" }),
			if reading then bytes(reading.netTx, true) else "", "", "out")
		if reading and #reading.disks > 0 then
			body[#body + 1] = section("Disks", "database", "disk-section")
			for i = 1, math.min(6, #reading.disks) do
				local disk = reading.disks[i]
				body[#body + 1] = row(disk_name(disk.mount), meter(disk.pct), pct(disk.pct), "of " .. bytes(disk.size), "disk" .. tostring(i))
			end
		end
	end

	if state.settings then body[#body + 1] = settings_panel(state) end
	body[#body + 1] = footer()
	return el("div", { key = "root", class = "vitals-root", role = "vitals.root" }, body)
end

return View
