// Pure display helpers for the Stasi widget/panel. No Quickshell imports —
// countdown math mirrors the Android app (SPEC §3): minutes count down by
// wall clock between OASA polls so the board never looks stuck.

// Port of ArrivalParsing.kt: digits of btime2, null when unknown.
function parseMinutes(raw) {
  if (raw === null || raw === undefined) return null
  var digits = String(raw).replace(/[^0-9]/g, "")
  if (!digits) return null
  return parseInt(digits, 10)
}

// Minutes at display time, aged from the snapshot (fetchedAtMs epoch ms).
// tick is a throwaway dependency so bindings re-evaluate every 15 s.
function effectiveMinutes(snapshotMinutes, fetchedAtMs, tick) {
  void tick
  var m = parseMinutes(snapshotMinutes)
  if (m === null || !fetchedAtMs) return null
  var aged = m - (Date.now() - fetchedAtMs) / 60000
  return Math.max(0, Math.floor(aged))
}

function formatAge(fetchedAtMs, tick) {
  void tick
  if (!fetchedAtMs) return ""
  var s = Math.max(0, Math.round((Date.now() - fetchedAtMs) / 1000))
  if (s < 60) return "updated " + s + "s ago"
  return "updated " + Math.floor(s / 60) + "m ago"
}

// Bar pill: "740 · 4'" for the first known arrival.
function barLabel(stopCode, arrivals, fetchedAtMs, tick, error) {
  if (!stopCode) return "···"
  if (error) return "?"
  if (!arrivals || arrivals.length === 0) return "—"
  var first = arrivals[0]
  var m = effectiveMinutes(first.minutes, fetchedAtMs, tick)
  var line = first.line || first.line_code || ""
  if (m === null) return line
  // Some stops omit line_code (fields vary per endpoint); never lead with "·".
  return line === "" ? m + "ʹ" : line + " · " + m + "ʹ"
}

// One panel row: "740 · ΚΗΦΙΣΙΑ - Π. ΦΑΛΗΡΟ · 4ʹ".
function rowLabel(arrival, fetchedAtMs, tick) {
  var parts = []
  var line = arrival.line || arrival.line_code || ""
  if (line) parts.push(line)
  if (arrival.destination) parts.push(arrival.destination)
  var m = effectiveMinutes(arrival.minutes, fetchedAtMs, tick)
  parts.push(m === null ? "—" : m + "ʹ")
  return parts.join(" · ")
}
