"""Entry point: `python -m btrvoice`."""

from __future__ import annotations

import argparse
import os
import sys


def main() -> int:
    parser = argparse.ArgumentParser(prog="btrvoice", description="BtrVoice for Linux/X11")
    parser.add_argument(
        "--model", default="large-v3",
        help="whisper size: tiny|base|small|medium|large-v3 (default: large-v3)",
    )
    parser.add_argument(
        "--language", default="en",
        help="force a language, or 'auto' to detect (default: en)",
    )
    parser.add_argument("--list-sources", action="store_true", help="list audio inputs and exit")
    parser.add_argument("--self-test", action="store_true", help="run the pure-logic suite and exit")
    args = parser.parse_args()

    if args.list_sources:
        from .audio import default_source, list_sources

        for name, _ in list_sources():
            kind = "monitor" if name.endswith(".monitor") else "input"
            mark = "*" if name == default_source() else " "
            print(f" {mark} [{kind:7}] {name}")
        return 0

    if args.self_test:
        from .selftest import run

        return run()

    # Over SSH there's no DISPLAY, but the session on the local seat is where
    # injection is meaningful — default to it rather than failing to start.
    if not os.environ.get("DISPLAY"):
        os.environ["DISPLAY"] = ":0"

    from .app import BtrVoiceApp

    app = BtrVoiceApp(
        model_size=args.model,
        language=None if args.language == "auto" else args.language,
    )
    return app.run()


if __name__ == "__main__":
    sys.exit(main())
