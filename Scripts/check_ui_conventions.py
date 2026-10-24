"""Keep page actions on the shared toolbar component; no third-party packages."""

from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[1]
TOOLBAR_COMPONENT = Path("App/Sources/DesignSystem/TesseraeToolbarActions.swift")
TRAILING_ITEM = re.compile(
    r"\bToolbarItem(?:Group)?\s*\([^)]*\bplacement\s*:\s*"
    r"\.(?:topBarTrailing|navigationBarTrailing)\b",
    re.MULTILINE,
)


def main() -> int:
    violations = []
    for path in sorted((ROOT / "App/Sources").rglob("*.swift")):
        relative = path.relative_to(ROOT)
        if relative == TOOLBAR_COMPONENT:
            continue
        source = path.read_text(encoding="utf-8")
        for match in TRAILING_ITEM.finditer(source):
            line = source.count("\n", 0, match.start()) + 1
            violations.append(
                f"{relative}:{line}: use TesseraeToolbarActions (or "
                "TesseraeRootToolbar) instead of a separate trailing item"
            )
    if violations:
        print("\n".join(violations), file=sys.stderr)
        return 1
    print("UI conventions passed: page actions use the shared toolbar capsule.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
