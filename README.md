# Audio Mixer for Omarchy

An [Omarchy](https://omarchy.org/) bar widget that shows **every** audio output
and input device with its own volume slider, mute button and "set as default"
switch — plus a per-app mixer. Think of the Windows sound panel, in your bar.

![kind: bar-widget](https://img.shields.io/badge/kind-bar--widget-informational)
![license: MIT](https://img.shields.io/badge/license-MIT-green)

![The Audio Mixer popup: a header with a master mute switch, an Output section
listing seven devices, an Input section listing five devices with a level meter
under the default one, and an Apps section with per-application sliders](preview.png)

## Why

The stock `omarchy.audio` widget builds its device lists from Quickshell's
PipeWire nodes. Devices that nothing has bound yet are missing from the input
list, and devices that share a nickname (every channel of a GoXLR, for example)
all look the same. This plugin reads the sound server through `pactl` instead,
so it sees all devices and uses their real descriptions.

## Features

- **Output and Input** in one panel. Every device has its own slider, a mute
  button (click the icon) and a ✓ on the current default. Click a row to make
  it the default; running apps follow a new default output.
- **Unplugged devices** stay visible, dimmed and marked "Not plugged in".
- **Input level meter** under the default input.
- **Apps**: volume and mute per playback stream. Click the `→ device` line to
  move the app to the next output.
- **Ports**: when a device has several available ports, click its subtitle
  (marked with `󰓡`) to cycle through them.
- **Monitor sources** are hidden by default; toggle them with *SHOW MONITORS*.
- **Master switch** in the header mutes or unmutes the default output and input
  together.
- Collapsible sections (click a section header).
- Live updates: the panel follows changes made elsewhere (volume keys,
  `pavucontrol`, plugging a device in) through `pactl subscribe`.

### Bar button

| Action       | Result                                   |
| ------------ | ---------------------------------------- |
| Left click   | Open / close the panel                   |
| Right click  | Mute / unmute default output and input   |
| Scroll       | Change output volume (with the OSD)      |

### Keyboard

| Key                   | Result                                          |
| --------------------- | ----------------------------------------------- |
| `↑` / `↓`             | Move between rows                               |
| `←` / `→`             | Lower / raise the volume of the selected row    |
| `Enter`               | Set as default (mute for an app)                |
| `m`                   | Mute / unmute the selected row                  |
| `p`                   | Cycle the port of the selected device           |
| `d`                   | Move the selected app to the next output        |
| `Tab`                 | Switch to the neighbouring bar panel            |
| `Esc`                 | Close                                           |

Mouse: drag a slider, scroll over it for 5% steps, right-click it to mute.

## Requirements

- Omarchy with the shell plugin system (`omarchy plugin ...`)
- PipeWire with `pipewire-pulse` (Omarchy default) — the plugin uses `pactl`
- A Nerd Font (Omarchy default) for the icons

## Install

```bash
omarchy plugin add https://github.com/jakubkozera/omarchy-audio-mixer.git --enable
```

Plugins run unsandboxed inside `omarchy-shell`; read the code before enabling
it. The widget has no built-in conflict with the stock one, so replace it in
the bar instead of showing both: in `~/.config/omarchy/shell.json`, change
`omarchy.audio` to `jakubkozera.audio-mixer` in `bar.layout`.

```json
{ "id": "jakubkozera.audio-mixer" }
```

`shell.json` hot-reloads, so the change shows up immediately.

### Manual install

```bash
git clone https://github.com/jakubkozera/omarchy-audio-mixer.git \
  ~/.config/omarchy/plugins/jakubkozera.audio-mixer
omarchy plugin enable jakubkozera.audio-mixer
```

The folder name must equal the plugin id. Don't symlink it: Quickshell refuses
modules that resolve outside the config folder.

## Update and uninstall

```bash
omarchy plugin update jakubkozera.audio-mixer
omarchy plugin remove jakubkozera.audio-mixer
```

After removing it, put `omarchy.audio` back into your bar layout (or run
`omarchy refresh shell`, which resets the shell config and keeps a backup).

## How it works

| File            | Purpose                                                              |
| --------------- | -------------------------------------------------------------------- |
| `manifest.json` | Plugin manifest (`bar-widget`, declared as a replacement for `omarchy.audio`) |
| `Panel.qml`     | Bar button, popup, keyboard navigation and actions                   |
| `Model.js`      | Pure functions turning `pactl --format=json` output into display models |

State comes from `pactl --format=json` (`info`, `list sinks|sources|sink-inputs`),
refreshed whenever `pactl subscribe` reports a change. Changes are applied with
`pactl` (volume, mute, ports, moving streams) and Omarchy's own
`omarchy-audio-output-set-default` / `omarchy-audio-input-set-default` helpers,
so the default device behaves exactly like it does with the stock widget.

## Development

```bash
git clone https://github.com/jakubkozera/omarchy-audio-mixer.git
cd omarchy-audio-mixer
omarchy plugin validate .
```

Copy the files into `~/.config/omarchy/plugins/jakubkozera.audio-mixer/` and run
`omarchy restart shell` after changing QML. `Model.js` has no Quickshell
dependency and can be tried with Node:

```bash
{ pactl --format=json info | tr -d '\n'; echo
  for k in sinks sources sink-inputs; do pactl --format=json list $k | tr -d '\n'; echo; done; } > /tmp/snap.txt
node -e "const M=require('./Model.js');console.log(M.buildState(require('fs').readFileSync('/tmp/snap.txt','utf8'),{}))"
```

## License

[MIT](LICENSE)
