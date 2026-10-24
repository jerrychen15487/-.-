"""V2.0 owns its tools; only the explicitly shared website is external."""
import os
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[1]
WEBSITE = Path(os.environ.get("SCORE_WEBSITE_PATH", PROJECT.parent / "piano-score-library")).resolve()
