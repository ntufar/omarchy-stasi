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

// Watchlist: setting("stops") is an array once watch/unwatch persist it, but
// `omarchy bar set` writes strings, so accept "60718, 61048" / space-separated
// too. The legacy single `stop` key merges in. Deduped, order preserved.
function parseStops(raw, legacyStop) {
  var out = []
  function push(code) {
    code = String(code === null || code === undefined ? "" : code).trim()
    if (code && out.indexOf(code) === -1) out.push(code)
  }
  if (typeof raw === "string") raw = raw.split(/[,\s]+/)
  if (raw && typeof raw.length === "number") {
    for (var i = 0; i < raw.length; i++) push(raw[i])
  }
  push(legacyStop)
  return out
}

// Slippy-map (OSM) math for the pure-QML tile map. Tile size is 256px.
var TILE_PX = 256

function lonToTileX(lon, z) {
  return (lon + 180) / 360 * Math.pow(2, z)
}

function latToTileY(lat, z) {
  var rad = lat * Math.PI / 180
  return (1 - Math.log(Math.tan(rad) + 1 / Math.cos(rad)) / Math.PI) / 2 * Math.pow(2, z)
}

function tileXToLon(x, z) {
  return x / Math.pow(2, z) * 360 - 180
}

function tileYToLat(y, z) {
  var n = Math.PI - 2 * Math.PI * y / Math.pow(2, z)
  return 180 / Math.PI * Math.atan(0.5 * (Math.exp(n) - Math.exp(-n)))
}

// Pixel of a geo point inside the viewport for a center/zoom/size view.
function geoToPixel(lat, lng, centerLat, centerLng, zoom, width, height) {
  var cx = lonToTileX(centerLng, zoom) * TILE_PX
  var cy = latToTileY(centerLat, zoom) * TILE_PX
  return {
    x: lonToTileX(lng, zoom) * TILE_PX - cx + width / 2,
    y: latToTileY(lat, zoom) * TILE_PX - cy + height / 2
  }
}

// Geo point at a viewport pixel (inverse of geoToPixel).
function pixelToGeo(px, py, centerLat, centerLng, zoom, width, height) {
  var cx = lonToTileX(centerLng, zoom) * TILE_PX
  var cy = latToTileY(centerLat, zoom) * TILE_PX
  return {
    lat: tileYToLat((cy - height / 2 + py) / TILE_PX, zoom),
    lng: tileXToLon((cx - width / 2 + px) / TILE_PX, zoom)
  }
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
