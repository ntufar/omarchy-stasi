"""Command-line interface for the Omarchy shell (stdout JSON, exit 0)."""
import argparse
import json
import sys

from stasi_client import oasa, tiles


def cmd_arrivals(args):
    payload = oasa.get_stops_arrivals(args.stop, force_refresh=args.force_refresh)
    json.dump(payload, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")


def cmd_search(args):
    if oasa.load_stop_index() is None:
        raise RuntimeError("stop index missing; run stasi-client refresh-stops first")
    stops = oasa.search_stops(args.query, limit=args.limit)
    json.dump({"query": args.query, "stops": stops}, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")


def cmd_alerts(args):
    notified = [k.strip() for k in (args.notified or "").split(",")]
    result = oasa.alerts_due(args.stop, args.threshold,
                             [k for k in notified if k],
                             force_refresh=args.force_refresh)
    json.dump(result, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")


def cmd_search_lines(args):
    lines = oasa.search_lines(args.query, limit=args.limit)
    json.dump({"query": args.query, "lines": lines}, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")


def cmd_line_stops(args):
    payload = oasa.line_stops(args.line, force_refresh=args.force_refresh)
    json.dump(payload, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")


def cmd_stops_geo(args):
    stops = oasa.stops_geo()
    if args.limit is not None:
        stops = stops[:max(0, args.limit)]
    json.dump({"stops": stops}, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")


def cmd_map_tiles(args):
    refs = []
    for ref in args.tile:
        parts = ref.split("/")
        if len(parts) != 3:
            raise RuntimeError("bad tile ref (want z/x/y): %s" % ref)
        try:
            refs.append(tuple(int(p) for p in parts))
        except ValueError:
            raise RuntimeError("bad tile ref (want z/x/y): %s" % ref)
    results = tiles.fetch_tiles(refs, style=args.style, force_refresh=args.force_refresh)
    json.dump({"tiles": results}, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")


def cmd_refresh_stops(args):
    def progress(done, total):
        sys.stderr.write("refresh-stops: line %d/%d\n" % (done, total))
        sys.stderr.flush()
    summary = oasa.build_stop_index(force_refresh=args.full, progress=progress)
    json.dump(summary, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")


def build_parser():
    parser = argparse.ArgumentParser(prog="stasi-client",
                                     description="OASA arrivals helper for the Stasi Omarchy plugin")
    sub = parser.add_subparsers(dest="command", required=True)
    arrivals = sub.add_parser("arrivals", help="live arrivals for stop codes")
    arrivals.add_argument("--stop", required=True, action="append",
                          help="OASA stop code (repeat for a watchlist)")
    arrivals.add_argument("--force-refresh", action="store_true",
                          help="skip the ~20 s disk cache")
    arrivals.set_defaults(func=cmd_arrivals)
    search = sub.add_parser("search", help="search stops by name or code")
    search.add_argument("query", help="Greek, Greeklish (e.g. syntagma) or stop code")
    search.add_argument("--limit", type=int, default=oasa.SEARCH_LIMIT_DEFAULT,
                        help="max results (default %(default)s)")
    search.set_defaults(func=cmd_search)
    alerts = sub.add_parser("alerts", help="buses at/below a minute threshold")
    alerts.add_argument("--stop", required=True, action="append",
                        help="OASA stop code (repeat for a watchlist)")
    alerts.add_argument("--threshold", required=True, type=int,
                        help="notify at or below this many minutes (<=0 disables)")
    alerts.add_argument("--notified", default="",
                        help="comma-separated alert keys already fired for")
    alerts.add_argument("--force-refresh", action="store_true",
                        help="skip the ~20 s arrivals cache")
    alerts.set_defaults(func=cmd_alerts)
    search_lines = sub.add_parser("search-lines", help="search bus lines")
    search_lines.add_argument("query", help="line number, code or name")
    search_lines.add_argument("--limit", type=int,
                              default=oasa.SEARCH_LINES_LIMIT_DEFAULT,
                              help="max results (default %(default)s)")
    search_lines.set_defaults(func=cmd_search_lines)
    line_stops = sub.add_parser("line-stops",
                                help="routes + geo stops for one line (map overlay)")
    line_stops.add_argument("--line", required=True, help="OASA line code")
    line_stops.add_argument("--force-refresh", action="store_true",
                            help="skip the ~24 h catalog caches")
    line_stops.set_defaults(func=cmd_line_stops)
    stops_geo = sub.add_parser("stops-geo",
                               help="indexed stops with coordinates (map markers)")
    stops_geo.add_argument("--limit", type=int, default=None,
                           help="max stops (default all with coordinates)")
    stops_geo.set_defaults(func=cmd_stops_geo)
    map_tiles = sub.add_parser("map-tiles",
                               help="fetch + disk-cache OSM raster tiles (OSM tile policy: "
                                    "identifying User-Agent + local cache, never bare-fetched "
                                    "from QML)")
    map_tiles.add_argument("--tile", required=True, action="append",
                           help="z/x/y tile ref (repeat for a batch)")
    map_tiles.add_argument("--style", choices=sorted(tiles.TILE_STYLES),
                           default="light", help="basemap style (default light)")
    map_tiles.add_argument("--force-refresh", action="store_true",
                           help="ignore the on-disk tile cache")
    map_tiles.set_defaults(func=cmd_map_tiles)
    refresh = sub.add_parser("refresh-stops",
                             help="rebuild the stop-search index (slow first run)")
    refresh.add_argument("--full", action="store_true",
                         help="ignore the ~24 h catalog caches")
    refresh.set_defaults(func=cmd_refresh_stops)
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    try:
        args.func(args)
    except Exception as exc:  # keep the contract: JSON on stdout, nonzero exit
        json.dump({"error": str(exc)}, sys.stdout, ensure_ascii=False)
        sys.stdout.write("\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
