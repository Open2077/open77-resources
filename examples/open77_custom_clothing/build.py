"""Build the game-root-relative preload package. Run with Python 3."""
from pathlib import Path
from zipfile import ZipFile, ZipInfo, ZIP_DEFLATED
root = Path(__file__).resolve().parent
(root / "dist").mkdir(exist_ok=True)
with ZipFile(root / "dist/open77-custom-clothing.zip", "w", ZIP_DEFLATED) as archive:
    for path in sorted((root / "tweaks").glob("*.yaml")):
        info = ZipInfo("r6/tweaks/" + path.name, (2026, 10, 18, 0, 0, 0))
        info.compress_type = ZIP_DEFLATED
        archive.writestr(info, path.read_bytes())
print("Built dist/open77-custom-clothing.zip")
