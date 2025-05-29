#!/usr/bin/env python3

import os
import subprocess
import re
from datetime import datetime

repo = os.path.dirname(os.path.realpath(__file__))
expectations_dir = "Source/WebKit/SaferCPPExpectations"
older_expectations_dir = "Source/WebKit/SmartPointerExpectations"

gitre = re.compile(r"^(\w+)\s+(.*)$")

results = []

dir = os.path.join(repo, expectations_dir)
for f in os.listdir(dir):
	fullf = os.path.join(dir, f)
	print("Checking commits in "+f)
	for line in subprocess.check_output("git log --pretty=format:\"%h%x09%as\" --follow \""+fullf+"\"", shell=True, encoding="utf-8").split('\n'):
		m = re.match(gitre, line)
		if m:
			thedate = datetime.strptime(m.group(2), "%Y-%m-%d")
			rev = m.group(1)
			numlines = subprocess.check_output("git show "+rev+":"+os.path.join(expectations_dir, f)+" | wc -l", shell=True, encoding="utf-8").rstrip()
			if int(numlines) == 0:
				numlines = subprocess.check_output("git show "+rev+":"+os.path.join(older_expectations_dir, f)+" | wc -l", shell=True, encoding="utf-8").rstrip()
			results.append((thedate, f, int(numlines)))

allfiles = set([x[1] for x in results])
currentcountbyfile = {x: 0 for x in allfiles}
fileorder = list(currentcountbyfile)
print(",".join(["date"]+fileorder))
results.sort(key=lambda x: x[0])
prevdate = None
for line in results:
	currentcountbyfile[line[1]] = line[2]
	thisdate = line[0]
	if thisdate != prevdate:
		thisrow = [str(thisdate)]
		for f in fileorder:
			thisrow.append(str(currentcountbyfile[f]))
		print(",".join(thisrow))
		prevdate = thisdate
