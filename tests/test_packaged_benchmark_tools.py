from __future__ import annotations

import tempfile
import runpy
import unittest
from pathlib import Path

from launcher.benchmark.models import RuntimePaths, runtime_paths
from launcher.benchmark.official_tools import benchmark_tool_path


class PackagedBenchmarkToolsTest(unittest.TestCase):
    def test_bundled_needle_reads_the_installed_strata_corpus(self):
        paths = runtime_paths()
        tool = benchmark_tool_path(paths, "needle_bench.py")
        self.assertEqual(tool, paths.launcher / "benchmark" / "tools" / "needle_bench.py")
        namespace = runpy.run_path(str(tool))
        self.assertEqual(namespace["ROOT"], paths.root)
        self.assertTrue(namespace["haystack"](100))

    def test_packaged_tools_win_over_upstream_tools(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            launcher = root / "launcher"
            bundled = launcher / "benchmark" / "tools"
            upstream = root / "tools"
            bundled.mkdir(parents=True)
            upstream.mkdir()
            paths = RuntimePaths(root, launcher, root / "python.exe", root / "server.py", launcher / "reports")
            old_tool = upstream / "needle_bench.py"
            new_tool = bundled / "needle_bench.py"
            old_tool.write_text("old", encoding="utf-8")
            self.assertEqual(benchmark_tool_path(paths, "needle_bench.py"), old_tool)
            new_tool.write_text("new", encoding="utf-8")
            self.assertEqual(benchmark_tool_path(paths, "needle_bench.py"), new_tool)


if __name__ == "__main__":
    unittest.main()
