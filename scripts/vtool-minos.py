#!/usr/bin/env python3
"""Print the first minos value from `vtool -show-build` on stdin."""
import sys


def main():
    for line in sys.stdin:
        parts = line.split()
        if "minos" in parts:
            index = parts.index("minos")
            if index + 1 < len(parts):
                print(parts[index + 1])
                return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
