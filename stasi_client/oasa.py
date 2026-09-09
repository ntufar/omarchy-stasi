"""Stasi Omarchy helper: OASA Telematics over HTTPS (stdlib only).

Ports OasaApi.kt (endpoint + contract), ArrivalParsing.kt (btime2 minutes)
and EndpointRateLimiter.kt (max ~1 request / 1.2 s per endpoint).
"""
import json
import os
import time
import urllib.parse
import urllib.request

BASE_URL = "https://telematics.oasa.gr/"
USER_AGENT = "Stasi-Omarch/1.0 (+https://github.com/ntufar/omarchy-stasi)"
RATE_LIMIT_SECONDS = 1.2
ARRIVALS_CACHE_TTL_SECONDS = 20
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
