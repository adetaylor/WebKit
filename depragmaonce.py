#!/usr/bin/env python

# Usage: find Source/WTF -iname '*.h' | xargs grep -l "pragma once" | xargs -n 1 python depragmaonce.py

import sys
import os
import re

def remove_prefix(text, prefix):
    if text.startswith(prefix):
        return text[len(prefix):]
    return text

for fname in sys.argv[1:]:
	definename = fname
	definename = re.sub('[^A-Za-z0-9_]', '_', definename)
	definename = remove_prefix(definename, "Source_")

	lines = []
	with open(fname) as r:
		for line in r:
			if "pragma once" in line:
				lines.append("#ifndef "+definename+"\n")
				lines.append("#define "+definename+"\n")
			else:
				lines.append(line)
	lines.append("#endif // "+definename+"\n")

	with open(fname, 'w') as w:
		w.writelines(lines)
