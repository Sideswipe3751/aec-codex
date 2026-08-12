import json
import sys
from pathlib import Path


def main() -> None:
    snapshot = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    for provider in snapshot["providers"]:
        print(
            f"Verified {provider['id']} {provider['version']}: "
            f"{len(provider['tools'])} allowed structured tools"
        )


if __name__ == "__main__":
    main()
