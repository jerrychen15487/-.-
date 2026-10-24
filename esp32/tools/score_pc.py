"""Convenience entrypoint; python tools/score_pc.py --help never opens hardware."""
from score_pc.__main__ import main

if __name__ == "__main__":
    raise SystemExit(main())
