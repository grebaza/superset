#!/usr/bin/env python3
import io
import json
import os

BASE_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), os.pardir))
PACKAGE_JSON = os.path.join(BASE_DIR, "superset-frontend", "package.json")
with open(PACKAGE_JSON, "r") as package_file:
    version_string = json.load(package_file)["version"]

print(version_string)
