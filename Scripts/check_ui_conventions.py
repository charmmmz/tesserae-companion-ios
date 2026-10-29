"""Keep page actions on one shared toolbar item with stable identity."""

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
SHARED_PAGE_ACTION_ITEM = re.compile(
    r'\bToolbarItem\s*\(\s*id\s*:\s*"tesserae-page-actions"\s*,\s*'
    r"placement\s*:\s*\.topBarTrailing\b",
    re.MULTILINE,
)


def main() -> int:
    violations = []
    for path in sorted((ROOT / "App/Sources").rglob("*.swift")):
        relative = path.relative_to(ROOT)
        source = path.read_text(encoding="utf-8")
        if relative == TOOLBAR_COMPONENT:
            items = list(TRAILING_ITEM.finditer(source))
            if len(items) != 1 or not SHARED_PAGE_ACTION_ITEM.match(items[0].group()):
                violations.append(
                    f'{relative}: keep one ToolbarItem(id: "tesserae-page-actions", '
                    "placement: .topBarTrailing) for the shared capsule across pages; "
                    "view IDs and accessibility identifiers do not preserve toolbar identity"
                )
            continue
        for match in TRAILING_ITEM.finditer(source):
            line = source.count("\n", 0, match.start()) + 1
            violations.append(
                f"{relative}:{line}: use TesseraeToolbarActions (or "
                "TesseraeRootToolbar) instead of a separate trailing item"
            )
    if violations:
        print("\n".join(violations), file=sys.stderr)
        return 1
    print("UI conventions passed: page actions use one shared toolbar item with a fixed ID.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
