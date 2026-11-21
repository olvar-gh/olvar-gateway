import re
import tomllib
from pathlib import Path

import olvar_gateway

ROOT = Path(__file__).resolve().parents[1]


def test_package_version_matches_pyproject():
    project = tomllib.loads((ROOT / "pyproject.toml").read_text())["project"]
    assert olvar_gateway.__version__ == project["version"]


def test_changelog_has_an_entry_for_the_version():
    changelog = (ROOT / "CHANGELOG.md").read_text()
    assert re.search(rf"^## \[{re.escape(olvar_gateway.__version__)}\]", changelog, re.M)
