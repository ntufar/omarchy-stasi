"""Stasi Omarchy helper: OASA Telematics over HTTPS (stdlib only).

Ports OasaApi.kt (endpoint + contract), ArrivalParsing.kt (btime2 minutes)
and EndpointRateLimiter.kt (max ~1 request / 1.2 s per endpoint).
"""
import json
import os
import time
import urllib.parse
import urllib.request

from stasi_client import greek

BASE_URL = "https://telematics.oasa.gr/"
USER_AGENT = "Stasi-Omarch/1.0 (+https://github.com/ntufar/omarchy-stasi)"
RATE_LIMIT_SECONDS = 1.2
ARRIVALS_CACHE_TTL_SECONDS = 20
# Mirror the Android 24 h lines/stops cache: the stop-search corpus is a
# crawled snapshot (webGetLines -> webGetRoutes -> webGetStops), refreshed
# explicitly via `stasi-client refresh-stops`, not on every query.
CATALOG_CACHE_TTL_SECONDS = 24 * 3600
STOP_INDEX_FILENAME = "stops_index.json"
# Mirror SearchViewModel/SearchDao: min 2 chars, substring match, cap results.
SEARCH_MIN_CHARS = 2
SEARCH_LIMIT_DEFAULT = 120
REQUEST_TIMEOUT_SECONDS = 20


def _base_dir(env_var, fallback):
    value = os.environ.get(env_var)
    if value:
        return value
    return os.path.join(os.path.expanduser("~"), fallback)


def cache_dir():
    path = os.path.join(_base_dir("XDG_CACHE_HOME", ".cache"), "io.github.ntufar.stasi")
    os.makedirs(path, exist_ok=True)
    return path


def state_dir():
    path = os.path.join(_base_dir("XDG_STATE_HOME", ".local/state"), "io.github.ntufar.stasi")
    os.makedirs(path, exist_ok=True)
    return path


def _throttle(act):
    """Block until RATE_LIMIT_SECONDS elapsed since the last call of act."""
    marker = os.path.join(cache_dir(), "last_%s.txt" % "".join(
        c if c.isalnum() else "_" for c in act))
    now = time.time()
    try:
        with open(marker) as handle:
            last = float(handle.read().strip())
    except (OSError, ValueError):
        last = 0.0
    wait = RATE_LIMIT_SECONDS - (now - last)
    if wait > 0:
        time.sleep(wait)
        now = time.time()
    try:
        with open(marker, "w") as handle:
            handle.write(str(now))
    except OSError:
        pass


def _post(act, params):
    _throttle(act)
    query = urllib.parse.urlencode(dict({"act": act}, **params))
    request = urllib.request.Request(
        BASE_URL + "api/?" + query,
        data=b"",
        method="POST",
        headers={"User-Agent": USER_AGENT},
    )
    with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT_SECONDS) as response:
        return json.load(response)


def parse_btime2(raw):
    """Port of parseArrivalMinutes: digit characters of btime2, else None."""
    if raw is None:
        return None
    digits = "".join(c for c in str(raw).strip() if c.isdigit())
    if not digits:
        return None
    try:
        return int(digits)
    except ValueError:
        return None


def shape_arrivals(raw_items):
    """Normalize one getStopArrivals payload to the helper's arrival dicts."""
    arrivals = []
    for item in raw_items or []:
        if not isinstance(item, dict):
            continue
        arrivals.append({
            "route_code": item.get("route_code"),
            "veh_code": item.get("veh_code"),
            "minutes": parse_btime2(item.get("btime2")),
            "line_code": item.get("line_code"),
            "route_descr": item.get("route_descr"),
        })
    return arrivals


def get_stop_arrivals(stop_code, force_refresh=False):
    """Return {'stop', 'fetched_at', 'arrivals', 'cached'} for a stop code."""
    stop_code = (stop_code or "").strip()
    if not stop_code:
        raise ValueError("stop code is required")
    cache_file = os.path.join(cache_dir(), "arrivals_%s.json" % stop_code)
    if not force_refresh:
        try:
            with open(cache_file) as handle:
                cached = json.load(handle)
            if time.time() - cached.get("fetched_at", 0) < ARRIVALS_CACHE_TTL_SECONDS:
                cached["cached"] = True
                return cached
        except (OSError, ValueError):
            pass
    raw = _post("getStopArrivals", {"p1": stop_code})
    payload = {
        "stop": stop_code,
        "fetched_at": time.time(),
        "arrivals": shape_arrivals(raw),
        "cached": False,
    }
    try:
        with open(cache_file, "w") as handle:
            json.dump(payload, handle)
    except OSError:
        pass
    return payload


def _enrich_arrival(arrival, stop_code):
    # QML reads line/destination keys; keep both raw and friendly names.
    arrival["line"] = arrival.get("line_code") or ""
    arrival["destination"] = arrival.get("route_descr") or ""
    arrival["stop"] = stop_code
    return arrival


def get_stops_arrivals(stop_codes, force_refresh=False):
    """Return combined arrivals for several stop codes.

    Response: {"stops": [per-stop get_stop_arrivals payloads...],
    "fetched_at" (oldest snapshot), "arrivals" (merged, known minutes first),
    "cached"}. One failing stop yields an {"error"} section instead of
    failing the whole call. Codes are deduped, order preserved.
    """
    codes = []
    for code in stop_codes or []:
        code = _clean_str(code)
        if code and code not in codes:
            codes.append(code)
    if not codes:
        raise ValueError("at least one stop code is required")
    sections = []
    for code in codes:
        try:
            section = get_stop_arrivals(code, force_refresh=force_refresh)
            section["arrivals"] = [_enrich_arrival(a, code)
                                   for a in section["arrivals"]]
        except Exception as exc:
            section = {"stop": code, "fetched_at": 0, "arrivals": [],
                       "cached": False, "error": str(exc)}
        sections.append(section)
    merged = [arrival for section in sections for arrival in section["arrivals"]]
    merged.sort(key=lambda a: (a.get("minutes") is None, a.get("minutes") or 0))
    stamps = [s["fetched_at"] for s in sections if s.get("fetched_at")]
    return {"stops": sections,
            "fetched_at": min(stamps) if stamps else 0,
            "arrivals": merged,
            "cached": bool(sections) and all(s.get("cached") for s in sections)}


def alert_key(stop_code, arrival):
    """Stable identity for one board row: vehicle when known, else line+dest."""
    veh = _clean_str(arrival.get("veh_code"))
    if veh:
        return "%s#%s" % (stop_code, veh)
    line = _clean_str(arrival.get("line") or arrival.get("line_code"))
    dest = _clean_str(arrival.get("destination") or arrival.get("route_descr"))
    return "%s#%s#%s" % (stop_code, line, dest)


def alerts_due(stop_codes, threshold_minutes, notified_keys=(), force_refresh=False):
    """Buses at/below threshold that were not already notified.

    Single source of truth for the QML alert cycle: QML passes the keys it
    already fired for, gets back {"threshold", "notify", "notified"}. Keys
    that left the board are forgotten so a later bus can notify again.
    threshold <= 0 disables (no fetch). Minutes are snapshot values; the
    alerts call runs right after the arrivals fetch in the same cycle.
    """
    try:
        threshold = int(threshold_minutes)
    except (TypeError, ValueError):
        threshold = 0
    notified = set(notified_keys or [])
    if threshold <= 0:
        return {"threshold": 0, "notify": [], "notified": sorted(notified)}
    payload = get_stops_arrivals(stop_codes, force_refresh=force_refresh)
    board_keys = set()
    due = []
    for arrival in payload["arrivals"]:
        key = alert_key(arrival.get("stop") or "", arrival)
        board_keys.add(key)
        minutes = arrival.get("minutes")
        if minutes is None:
            continue
        if minutes <= threshold and key not in notified:
            due.append(arrival)
    kept = sorted((notified | {alert_key(a.get("stop") or "", a) for a in due})
                  & board_keys)
    return {"threshold": threshold, "notify": due, "notified": kept}


def _read_json_cache(name, ttl_seconds):
    """Return cached JSON payload, or None when missing/stale/unreadable."""
    try:
        with open(os.path.join(cache_dir(), name)) as handle:
            payload = json.load(handle)
    except (OSError, ValueError):
        return None
    if time.time() - payload.get("cached_at", 0) >= ttl_seconds:
        return None
    return payload.get("data")


def _write_json_cache(name, data):
    try:
        with open(os.path.join(cache_dir(), name), "w") as handle:
            json.dump({"cached_at": time.time(), "data": data}, handle)
    except OSError:
        pass


def _clean_str(value):
    return (value or "").strip()


def shape_lines(raw_items):
    """Normalize one webGetLines payload (OasaLineJson fields)."""
    lines = []
    for item in raw_items or []:
        if not isinstance(item, dict):
            continue
        lines.append({
            "line_code": _clean_str(item.get("LineCode")),
            "line_id": _clean_str(item.get("LineID")),
            "line_descr": _clean_str(item.get("LineDescr")),
        })
    return [line for line in lines if line["line_code"]]


def shape_routes(raw_items):
    """Normalize one webGetRoutes payload (OasaRouteJson fields)."""
    routes = []
    for item in raw_items or []:
        if not isinstance(item, dict):
            continue
        routes.append({
            "route_code": _clean_str(item.get("RouteCode")),
            "line_code": _clean_str(item.get("LineCode")),
            "route_descr": _clean_str(item.get("RouteDescr")),
        })
    return [route for route in routes if route["route_code"]]


def shape_catalog_stops(raw_items):
    """Normalize one webGetStops payload (OasaWebStopJson fields)."""
    stops = []
    for item in raw_items or []:
        if not isinstance(item, dict):
            continue
        stop_code = _clean_str(item.get("StopCode"))
        if not stop_code:
            continue
        stops.append({
            "stop_code": stop_code,
            "descr": _clean_str(item.get("StopDescr")),
            "descr_eng": _clean_str(item.get("StopDescrEng")),
        })
    return stops


def get_lines(force_refresh=False):
    """Return [{line_code, line_id, line_descr}]; cached 24 h like Android."""
    if not force_refresh:
        cached = _read_json_cache("lines.json", CATALOG_CACHE_TTL_SECONDS)
        if cached is not None:
            return cached
    lines = shape_lines(_post("webGetLines", {}))
    _write_json_cache("lines.json", lines)
    return lines


def get_routes(line_code, force_refresh=False):
    """Return [{route_code, line_code, route_descr}] for a line; cached 24 h."""
    line_code = _clean_str(line_code)
    if not line_code:
        raise ValueError("line code is required")
    name = "routes_%s.json" % line_code
    if not force_refresh:
        cached = _read_json_cache(name, CATALOG_CACHE_TTL_SECONDS)
        if cached is not None:
            return cached
    routes = shape_routes(_post("webGetRoutes", {"p1": line_code}))
    _write_json_cache(name, routes)
    return routes


def get_route_stops(route_code, force_refresh=False):
    """Return [{stop_code, descr, descr_eng}] for a route; cached 24 h."""
    route_code = _clean_str(route_code)
    if not route_code:
        raise ValueError("route code is required")
    name = "routestops_%s.json" % route_code
    if not force_refresh:
        cached = _read_json_cache(name, CATALOG_CACHE_TTL_SECONDS)
        if cached is not None:
            return cached
    stops = shape_catalog_stops(_post("webGetStops", {"p1": route_code}))
    _write_json_cache(name, stops)
    return stops


def build_stop_index(force_refresh=False, progress=None):
    """Crawl lines -> routes -> stops into stops_index.json.

    Respects the 1.2 s endpoint throttle via _post; per-level 24 h caches
    make repeat runs incremental unless force_refresh is set. progress, when
    given, is called as progress(lines_done, lines_total) after each line.
    Returns {"built_at", "stops", "lines", "routes"} summary counts.
    """
    lines = get_lines(force_refresh=force_refresh)
    seen = set()
    index_stops = []
    route_count = 0
    for pos, line in enumerate(lines):
        routes = get_routes(line["line_code"], force_refresh=force_refresh)
        route_count += len(routes)
        for route in routes:
            for stop in get_route_stops(route["route_code"],
                                        force_refresh=force_refresh):
                if stop["stop_code"] in seen:
                    continue
                seen.add(stop["stop_code"])
                index_stops.append({
                    "stop_code": stop["stop_code"],
                    "descr": stop["descr"],
                    "norm": greek.stop_search_norm(stop["stop_code"],
                                                   stop["descr"]),
                })
        if progress is not None:
            progress(pos + 1, len(lines))
    payload = {
        "built_at": time.time(),
        "stops": index_stops,
    }
    _write_json_cache(STOP_INDEX_FILENAME, payload["stops"])
    try:
        with open(os.path.join(cache_dir(), "stops_index_meta.json"), "w") as handle:
            json.dump({"built_at": payload["built_at"],
                       "stops": len(index_stops),
                       "lines": len(lines),
                       "routes": route_count}, handle)
    except OSError:
        pass
    return {"built_at": payload["built_at"], "stops": len(index_stops),
            "lines": len(lines), "routes": route_count}


def load_stop_index():
    """Return the stop index list, or None when never built."""
    stops = _read_json_cache(STOP_INDEX_FILENAME, float("inf"))
    return stops


def search_stops(query, limit=SEARCH_LIMIT_DEFAULT, index=None):
    """Port of OasaRepository.searchStops: Greeklish-aware substring match.

    Normalizes the query exactly like Android (Latin expansion, accent strip,
    min 2 chars, %/_ scrubbed). Ranking is a deliberate small deviation from
    the unordered DAO query: stop-code prefix, then name prefix, then
    substring, stable within each group, capped at limit.
    """
    needle = greek.normalize_greek(
        greek.expand_latin_query(query)).strip().replace("%", "").replace("_", "")
    if len(needle) < SEARCH_MIN_CHARS:
        return []
    stops = index if index is not None else (load_stop_index() or [])
    code_hits, prefix_hits, sub_hits = [], [], []
    for stop in stops:
        code = _clean_str(stop.get("stop_code"))
        norm = stop.get("norm") or greek.stop_search_norm(code, stop.get("descr"))
        if code.startswith(needle):
            code_hits.append(stop)
        elif norm.startswith(needle):
            prefix_hits.append(stop)
        elif needle in norm:
            sub_hits.append(stop)
    ranked = code_hits + prefix_hits + sub_hits
    return [{"stop_code": _clean_str(stop.get("stop_code")),
             "descr": _clean_str(stop.get("descr"))}
            for stop in ranked[:max(0, limit)]]
