"""Command-line interface for the Omarchy shell (stdout JSON, exit 0)."""
import argparse
import json
import sys

from stasi_client import oasa


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
