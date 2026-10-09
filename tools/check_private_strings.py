"""Block commits whose staged text contains private strings (local paths, account names, ids of other tools).

The patterns are NOT tracked: they live in .git/info/private-patterns (one Python regex per line, '#' comments), so the
list itself never gets published. Without that file the check passes. Used by .githooks/pre-commit.
"""
import re
import subprocess
import sys
from pathlib import Path


def main() -> int:
    git_dir = Path(subprocess.run(["git", "rev-parse", "--git-common-dir"], capture_output=True, text=True).stdout.strip())
    pat_file = git_dir / "info" / "private-patterns"
    if not pat_file.exists():
        return 0
    pats = [re.compile(l.strip(), re.I) for l in pat_file.read_text(encoding="utf-8").splitlines()
            if l.strip() and not l.lstrip().startswith("#")]
    names = subprocess.run(["git", "diff", "--cached", "--name-only", "--diff-filter=ACMR"],
                           capture_output=True, text=True).stdout.split()
    bad = []
    for name in names:
        blob = subprocess.run(["git", "show", f":{name}"], capture_output=True).stdout
        try:
            text = blob.decode("utf-8")
        except UnicodeDecodeError:
            continue  # binaries are the game-file guard's job
        for n, line in enumerate(text.splitlines(), 1):
            for p in pats:
                if p.search(line):
                    bad.append(f"{name}:{n}: matches a private pattern")
                    break
    if bad:
        print("check_private_strings: private strings staged (patterns in .git/info/private-patterns):", file=sys.stderr)
        print("\n".join(bad[:40]), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
