#!/usr/bin/env python3
"""Falso `git`: devolve sempre a mesma revisão para rev-parse HEAD."""
import sys

if sys.argv[-2:] == ["rev-parse", "HEAD"]:
    print("a" * 40)
else:
    sys.exit(0)
