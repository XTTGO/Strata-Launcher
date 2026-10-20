import importlib.util
import json
from pathlib import Path
import shutil
import unittest
import uuid


SCRIPT = Path(__file__).resolve().parents[1] / "Strata-Calibrate-Current.py"


def load_helper():
    spec = importlib.util.spec_from_file_location("strata_calibrate_current", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class CalibrationDetailStore(unittest.TestCase):
    def setUp(self):
        self.root = Path(__file__).parent / ".tmp" / uuid.uuid4().hex
        self.root.mkdir(parents=True)

    def tearDown(self):
        shutil.rmtree(self.root)

    def test_write_detail_record_preserves_other_combinations(self):
        helper = load_helper()
        path = self.root / "calibration-details.json"
        path.write_text(json.dumps({"schema_version": 1, "records": {"other": {"tok_s": 1}}}), encoding="utf-8")

        helper.write_detail_record(path, "gpu|model|262144|images", {"tok_s": 106.4, "label": "视觉开启"})

        saved = json.loads(path.read_text(encoding="utf-8"))
        self.assertEqual(saved["records"]["other"]["tok_s"], 1)
        self.assertEqual(saved["records"]["gpu|model|262144|images"]["tok_s"], 106.4)
        self.assertEqual(saved["records"]["gpu|model|262144|images"]["label"], "视觉开启")
        self.assertFalse(path.with_suffix(path.suffix + ".tmp").exists())


if __name__ == "__main__":
    unittest.main()
