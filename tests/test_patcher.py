#!/usr/bin/env python3
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from xml.etree import ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
PATCHER = ROOT / "overlay/tools/patch_vendor_xml.py"
FIXTURE = ROOT / "tests/fixtures/vendor-minimal.xml"


def children_named(cfg, name):
    return [node for node in cfg if node.get("name") == name]


class PatcherTests(unittest.TestCase):
    def run_mode(self, mode):
        with tempfile.TemporaryDirectory() as td:
            output = Path(td) / "vendor.xml"
            report = Path(td) / "report.json"
            subprocess.run(
                ["python3", str(PATCHER), "--mode", mode, str(FIXTURE),
                 str(output), "--report", str(report)],
                check=True,
                stdout=subprocess.PIPE,
                text=True,
            )
            return ET.parse(output).getroot(), json.loads(report.read_text())

    def test_explicit_nsa_appends_final_override(self):
        root, report = self.run_mode("explicit-nsa")
        blocks = [x for x in root if x.tag == "carrier_config"]
        last = blocks[-1]
        self.assertEqual(last.attrib, {"mcc": "460", "mnc": "00"})
        values = [i.get("value") for arr in children_named(
            last, "carrier_nr_availabilities_int_array") for i in arr]
        self.assertEqual(values, ["1", "2"])
        self.assertEqual(children_named(last, "carrier_disable_sa_mode_bool")[0].get("value"), "false")
        self.assertEqual(report["appended_override_blocks"], 1)

    def test_universal_updates_selectorless_default(self):
        root, _ = self.run_mode("universal")
        defaults = [x for x in root if x.tag == "carrier_config" and not x.attrib]
        self.assertEqual(len(defaults), 1)
        default = defaults[0]
        self.assertEqual(children_named(default, "carrier_sa_mode_available_bool")[0].get("value"), "true")
        self.assertEqual(children_named(default, "carrier_disable_sa_mode_bool")[0].get("value"), "false")
        values = [i.get("value") for arr in children_named(
            default, "carrier_nr_availabilities_int_array") for i in arr]
        self.assertEqual(values, ["1", "2"])


if __name__ == "__main__":
    unittest.main()
