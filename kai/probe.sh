#!/bin/sh
# One probe round, in sections: POSIX sh and the tools every macOS and Linux
# box already has. vitals/window.luau parses it; it sends raw counters, not
# rates, so the plugin can derive them between rounds.
export LC_ALL=C

say() { printf '@@%s\n' "$1"; }

say os
uname -s
say host
uname -n
say kernel
uname -r
say arch
uname -m

case "$(uname -s)" in
Darwin)
	say release
	printf 'macOS %s\n' "$(sw_vers -productVersion 2>/dev/null)"
	# iostat samples the CPU over a second; the last row is the live one.
	say cpu
	iostat -c 2 2>/dev/null | tail -1
	say sysctl
	sysctl -n hw.ncpu hw.memsize vm.loadavg kern.boottime vm.swapusage 2>/dev/null
	say vmstat
	vm_stat 2>/dev/null
	say netstat
	netstat -ibn 2>/dev/null
	say df
	df -kP 2>/dev/null
	df -kP /System/Volumes/Data 2>/dev/null | tail -n +2
	say ps
	ps -Ao %cpu= 2>/dev/null
	;;
*)
	say release
	(. /etc/os-release 2>/dev/null && printf '%s\n' "$PRETTY_NAME")
	say stat
	cat /proc/stat 2>/dev/null
	say loadavg
	cat /proc/loadavg 2>/dev/null
	say meminfo
	cat /proc/meminfo 2>/dev/null
	say uptime
	cat /proc/uptime 2>/dev/null
	say netdev
	cat /proc/net/dev 2>/dev/null
	say df
	df -kP 2>/dev/null
	;;
esac
