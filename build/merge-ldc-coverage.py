"""Add optimized bytecode coverage to the existing kcov Codecov report."""

import json
from pathlib import Path
import sys


def merge(report_path: Path, listing_dir: Path) -> None:
    root = Path(__file__).resolve().parent.parent
    report = json.loads(report_path.read_text())
    coverage = report["coverage"]
    for source in sorted((root / "source/snakebite/backends/bytecode").glob("*.d")):
        listing_name = source.with_suffix(".lst").as_posix().replace("/", "-")
        listing = listing_dir / listing_name
        source_lines = source.read_text().splitlines()
        listing_lines = listing.read_text().splitlines()
        scores = coverage.setdefault(source.relative_to(root).as_posix(), {})
        for index, source_line in enumerate(source_lines, start=1):
            count, separator, reported = listing_lines[index - 1].partition("|")
            if not separator or reported.strip() != source_line.strip():
                raise ValueError(f"Coverage listing differs from {source}:{index}")
            if not count.strip():
                continue
            line = str(index)
            if line not in scores or not int(str(scores[line]).split("/", 1)[0]):
                scores[line] = int(count)

    report_path.write_text(json.dumps(report) + "\n")


if __name__ == "__main__":
    report_path, listing_dir = map(Path, sys.argv[1:])
    merge(report_path, listing_dir)
