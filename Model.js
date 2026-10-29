// Pure helpers: turn `pactl --format=json` output into display models.

function cp(code) { return String.fromCodePoint(code) }

var GLYPH = {
  speaker: cp(0xf04c3),
  headphones: cp(0xf02cb),
  display: cp(0xf0379),
  bluetooth: cp(0xf00af),
  mic: cp(0xf036c),
  micMuted: cp(0xf036d),
  camera: cp(0xf0100),
  monitor: cp(0xf057e),
  streamOn: cp(0xf057e),
  streamOff: cp(0xf075f),
  volumeMuted: cp(0xeee8),
  volumeLow: cp(0xf026),
  volumeMid: cp(0xf027),
  volumeHigh: cp(0xf028),
  swap: cp(0xf04e1),
  check: cp(0xf012c),
  chevronDown: cp(0xf0140),
  chevronRight: cp(0xf0142)
}

var LONG_DESCRIPTION = 30

function parseLines(raw) {
  var lines = String(raw || "").split("\n")
  var out = []
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line) { out.push(null); continue }
    try { out.push(JSON.parse(line)) } catch (e) { out.push(null) }
  }
  return out
}

function propsOf(obj) {
  return obj && obj.properties ? obj.properties : {}
}

function averageVolume(volume) {
  var sum = 0
  var count = 0
  for (var channel in volume || {}) {
    sum += Number(volume[channel].value || 0)
    count++
  }
  return count === 0 ? 0 : sum / count / 65536
}

function cleanDescription(text) {
  var label = String(text || "").trim()
  label = label.replace(/^sof-soundwire\s+/i, "")
  label = label.replace(/^built-?in audio\s+/i, "")
  label = label.replace(/\s+(Analog|Digital)\s+Stereo(\s+\(.*\))?(\s+\[.*\])?$/i, "")
  return label
}

function deviceLabel(dev) {
  var p = propsOf(dev)
  var description = String(dev.description || "").trim()
  var nick = String(p["node.nick"] || "").trim()
  var isMonitor = /^Monitor of /i.test(description)
  if (isMonitor) return description
  var cleaned = cleanDescription(description)
  if (cleaned.length > LONG_DESCRIPTION && nick) return nick
  return cleaned || nick || String(dev.name || "Unknown")
}

function activePort(dev) {
  var ports = dev.ports || []
  for (var i = 0; i < ports.length; i++)
    if (ports[i].name === dev.active_port) return ports[i]
  return null
}

function isAvailable(dev) {
  var port = activePort(dev)
  return !port || port.availability !== "not available"
}

function stripPortPrefix(text) {
  return String(text || "").replace(/^\[(Out|In)\]\s*/i, "").trim()
}

function portChoices(dev) {
  var ports = dev.ports || []
  var list = []
  for (var i = 0; i < ports.length; i++)
    if (ports[i].availability !== "not available") list.push(ports[i])
  return list
}

function deviceBlob(dev) {
  var p = propsOf(dev)
  return String([
    dev.name, dev.description,
    p["device.icon_name"] || "", p["device.form_factor"] || "",
    p["node.nick"] || "", p["device.product.name"] || ""
  ].join(" ")).toLowerCase()
}

function sinkGlyph(dev) {
  var blob = deviceBlob(dev)
  if (/headphone|headset|earbud|earphone|airpod/.test(blob)) return GLYPH.headphones
  if (/bluez|bluetooth/.test(blob)) return GLYPH.bluetooth
  if (/hdmi|displayport|display/.test(blob)) return GLYPH.display
  return GLYPH.speaker
}

function sourceGlyph(dev) {
  var blob = deviceBlob(dev)
  if (/^monitor of/i.test(String(dev.description || ""))) return GLYPH.monitor
  if (/webcam|camera|brio/.test(blob)) return GLYPH.camera
  if (/headset|headphone/.test(blob)) return GLYPH.headphones
  if (/bluez|bluetooth/.test(blob)) return GLYPH.bluetooth
  return GLYPH.mic
}

function portSubtitle(dev, label) {
  if (!isAvailable(dev)) return "Not plugged in"
  var port = activePort(dev)
  var text = port ? stripPortPrefix(port.description || port.name) : ""
  if (text && label.toLowerCase().indexOf(text.toLowerCase()) === -1) return text
  return ""
}

function buildDevice(kind, dev, defaultName) {
  var label = deviceLabel(dev)
  var p = propsOf(dev)
  var choices = portChoices(dev)
  return {
    key: kind + ":" + dev.name,
    kind: kind,
    name: dev.name,
    index: dev.index,
    nodeId: String(p["object.id"] || ""),
    label: label,
    subtitle: portSubtitle(dev, label),
    glyph: kind === "sink" ? sinkGlyph(dev) : sourceGlyph(dev),
    volume: averageVolume(dev.volume),
    muted: !!dev.mute,
    isDefault: dev.name === defaultName,
    available: isAvailable(dev),
    isMonitor: p["device.class"] === "monitor" || /\.monitor$/.test(String(dev.name || "")),
    state: dev.state || "",
    ports: choices.map(function(port) { return port.name }),
    activePort: dev.active_port || ""
  }
}

function ignoredStream(input) {
  var p = propsOf(input)
  var app = String(p["application.name"] || "")
  if (!app) return true
  if (app === "EasyEffects") return true
  if (String(p["node.name"] || "").indexOf("omarchy_speaker_tuning") === 0) return true
  return false
}

function buildStream(input, sinksByIndex) {
  var p = propsOf(input)
  var sink = sinksByIndex[input.sink]
  var media = String(p["media.name"] || "")
  var app = String(p["application.name"] || "Stream")
  return {
    key: "stream:" + input.index,
    kind: "stream",
    index: input.index,
    label: app,
    subtitle: sink ? sink.label : "",
    media: media,
    glyph: input.mute ? GLYPH.streamOff : GLYPH.streamOn,
    volume: averageVolume(input.volume),
    muted: !!input.mute,
    sinkName: sink ? sink.name : "",
    isDefault: false,
    available: true
  }
}

function buildState(raw, options) {
  var parsed = parseLines(raw)
  var info = parsed[0] || {}
  var rawSinks = Array.isArray(parsed[1]) ? parsed[1] : []
  var rawSources = Array.isArray(parsed[2]) ? parsed[2] : []
  var rawInputs = Array.isArray(parsed[3]) ? parsed[3] : []
  var showMonitors = !!(options && options.showMonitors)
  var defaultSink = String(info.default_sink_name || "")
  var defaultSource = String(info.default_source_name || "")

  var sinks = rawSinks.map(function(dev) { return buildDevice("sink", dev, defaultSink) })
  var sinksByIndex = {}
  for (var i = 0; i < sinks.length; i++) sinksByIndex[sinks[i].index] = sinks[i]

  var sources = rawSources
    .map(function(dev) { return buildDevice("source", dev, defaultSource) })
    .filter(function(dev) { return showMonitors || !dev.isMonitor || dev.isDefault })

  var streams = rawInputs
    .filter(function(input) { return !ignoredStream(input) })
    .map(function(input) { return buildStream(input, sinksByIndex) })

  return {
    sinks: sinks,
    sources: sources,
    streams: streams,
    defaultSink: defaultSink,
    defaultSource: defaultSource,
    loaded: parsed[0] !== null
  }
}

function indexItems(state) {
  var map = {}
  var groups = [state.sinks, state.sources, state.streams]
  for (var g = 0; g < groups.length; g++)
    for (var i = 0; i < groups[g].length; i++) map[groups[g][i].key] = groups[g][i]
  return map
}

function keysOf(list) {
  return list.map(function(item) { return item.key })
}

function sameKeys(a, b) {
  if (a.length !== b.length) return false
  for (var i = 0; i < a.length; i++) if (a[i] !== b[i]) return false
  return true
}

function clamp(v, lo, hi) {
  return Math.max(lo, Math.min(hi, v))
}

function outputIcon(item) {
  if (!item) return GLYPH.volumeMuted
  if (item.glyph === GLYPH.headphones && !item.muted) return GLYPH.headphones
  if (item.muted) return GLYPH.volumeMuted
  if (item.volume >= 0.67) return GLYPH.volumeHigh
  if (item.volume >= 0.34) return GLYPH.volumeMid
  if (item.volume > 0) return GLYPH.volumeLow
  return GLYPH.volumeMuted
}

function nextChoice(list, current) {
  if (!list || list.length === 0) return ""
  var at = list.indexOf(current)
  return list[(at + 1) % list.length]
}

if (typeof module !== "undefined") {
  module.exports = {
    GLYPH: GLYPH,
    parseLines: parseLines,
    averageVolume: averageVolume,
    deviceLabel: deviceLabel,
    isAvailable: isAvailable,
    portChoices: portChoices,
    buildState: buildState,
    indexItems: indexItems,
    keysOf: keysOf,
    sameKeys: sameKeys,
    clamp: clamp,
    outputIcon: outputIcon,
    nextChoice: nextChoice
  }
}
