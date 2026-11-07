# Vitals

How the machine your agents run on is doing, live, beside your work: CPU as
an equalizer, memory, swap, load, network and disk meters, and a word on how
it is doing (`OK`, `WARN swap`, `HOT cpu`).

The panel shows this computer, or any remote host Tern is connected to. It
works the same on macOS and Linux, and reads remote Linux and macOS machines
over the ssh access Tern already has.

## Install

```sh
tern plugin install github.com/Yupmoh/tern-plugins/vitals
```

Update with the same command plus `--force`. Press `⌘⌥V` to show or hide the
panel (the palette action is `plugin.tern-vitals.toggle` if you want another
key).

To develop it from a clone:

```sh
git clone https://github.com/Yupmoh/tern-plugins
tern plugin link tern-plugins/vitals
```

## What you see

- **The CPU as an equalizer.** A band per core on Linux; on macOS, where the
  system does not give a core's share without root, the last readings of the
  whole CPU. Each band lights from the bottom, green then yellow then red,
  and its peak holds for a moment and falls.
- **A word on its health.** `OK`, or `WARN` and `HOT` with what it is:
  `cpu`, `memory`, `swap`, `load`, or a full disk. CPU, memory and disks warn
  at 80% and are hot at 90%; swap warns at 50%; load is compared per core.
- **Memory, swap, load and network** as meters, all the same width.
- **Every disk**, with how full it is. macOS shows the Data volume, where
  your files are, not the sealed system volume.
- **This computer or another host.** Pick from the dropdown beside the title.
  Remote hosts are read over the same ssh address Tern uses.
- **Less or More.** A click in the header switches to the compact panel (CPU,
  memory and every disk together). The choice is kept.
- **Settings and Add machine** at the bottom. Settings has compact, refresh
  interval and reset history; Add machine opens Tern's remote host dialog.

The panel samples only while it is open: once every two seconds by default,
about 5 ms of CPU on Linux and one second of `iostat` on macOS per reading.
History is kept in the plugin's storage per host, so the graphs are still
there after reopening the panel or restarting Tern.

## Remote hosts

Remote readings use `ssh` from the machine Tern runs on. The host's address
comes from Tern's host list (`user@host` or `user@host:port`), so a machine
that already works in Tern works here too. The probe is one POSIX shell
script sent over stdin; nothing is installed on the remote machine.

If ssh needs a password or a key that is not loaded, the panel shows the
error instead of a reading. Add the host to `~/.config/tern/hosts` or through
Tern's Add machine dialog first.

## How it works

- `window.luau` owns the panel, the sampling timer, the parser and the machine
  choice. `probe.sh` is the whole remote/local read: `uname`, `sysctl`,
  `vm_stat`, `netstat` and `df` on macOS; `/proc` on Linux. Counters are
  compared between readings to get CPU and network rates.
- `view.luau` turns the model into Tern-native nodes; `styles.css` only sets
  spacing and shading, scoped to `vitals.*` roles.
- The canvas is a normal Tern panel, opened beside the focused pane. It stays
  where you leave it, and `⌘⌥V` (or the palette) closes it again.

**Limits:** macOS does not expose per-core CPU without root, so its bands
are a short history of the whole CPU. Windows is not read yet; the panel says
so instead of showing a stale number.

## License

[MIT](../LICENSE)
