"""Run launcher Python tests from either a nested or independent source checkout."""

from __future__ import annotations

import argparse
import os
import sys
import types
import unittest
from pathlib import Path


def main() -> int:
    source = Path(__file__).resolve().parent
    parent = source.parent
    default_strata = parent if (parent / "setup.py").is_file() else parent / "Strata"
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--strata-root", type=Path, default=default_strata)
    args = parser.parse_args()
    strata = args.strata_root.resolve()
    if not (strata / "setup.py").is_file():
        parser.error(f"Strata setup.py not found under {strata}")

    package = types.ModuleType("launcher")
    package.__path__ = [str(source)]
    package.__package__ = "launcher"
    sys.modules["launcher"] = package
    sys.path.insert(0, str(strata))
    os.environ["STRATA_ROOT"] = str(strata)
    temporary = source / "tests" / ".tmp"
    temporary.mkdir(exist_ok=True)
    os.environ["TEMP"] = os.environ["TMP"] = str(temporary)

    suite = unittest.defaultTestLoader.discover(str(source / "tests"), pattern="test_*.py")
    return 0 if unittest.TextTestRunner(verbosity=1).run(suite).wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
