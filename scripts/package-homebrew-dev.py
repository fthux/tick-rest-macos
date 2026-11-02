#!/usr/bin/env python3
"""Compatibility entry point for packaging dev builds with GitHub Release URLs."""

from pathlib import Path
import runpy
import sys


if __name__ == "__main__":
    sys.argv.insert(1, "dev")
    runpy.run_path(str(Path(__file__).with_name("package-homebrew.py")), run_name="__main__")
