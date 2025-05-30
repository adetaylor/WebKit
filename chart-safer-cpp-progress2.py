#!/usr/bin/env python3

import os
import subprocess
import re
import sys
from datetime import datetime

# Usage:
# Put this script alongside the OpenSource directory (NB that means, if you're getting this from a git checkout
# of WebKit's OpenSource directory, you'll need to copy it to the parent directory before running it.)
# Run it
# The output is a CSV. To get it into quip, you'll need to send it through sed -e "s/,/\t/g" then paste it into quip
# as it appears to have no CSV import facility.

repo = os.path.join(os.path.dirname(os.path.realpath(__file__)), "OpenSource")
expectations_dir = "Source/WebKit/SaferCPPExpectations"
older_expectations_dir = "Source/WebKit/SmartPointerExpectations"

gitre = re.compile(r"^(\w+)\s+(.*)$")

shas_by_date = dict()

subprocess.check_call(["git", "checkout", "origin/main"])

# We get our list of commits over time by looking at the SHAs which modify files
# within "Source/WebKit/SaferCPPExpectations", since any significant change to C++
# safety will likely have modified those exclusions files. This then gives us
# a manageable list of SHAs to check in detail (145 at the time of writing).
#
# Assumption inherent here: the set of files in "Source/WebKit/SaferCPPExpectations"
# only grows over time; files are not removed. That seems to be the case so far.
dir = os.path.join(repo, expectations_dir)
for f in os.listdir(dir):
	fullf = os.path.join(dir, f)
	print("Checking commits in "+f, file=sys.stderr)
	for line in subprocess.check_output("git log --pretty=format:\"%h%x09%as\" --follow \""+fullf+"\"", shell=True, encoding="utf-8").split('\n'):
		m = re.match(gitre, line)
		if m:
			thedate = datetime.strptime(m.group(2), "%Y-%m-%d")
			rev = m.group(1)
			shas_by_date[thedate] = rev

alldates = list(shas_by_date)
alldates.sort()

print("Number of SHAs to check: %d" % (len(alldates)), file=sys.stderr)

print(",".join(["date", "sha", "total_loc", "excluded_loc", "unsafe_loc", "unhandled_files"]))

# Get the list of files in any of the "Source/WebKit/SaferCPPExpectations" exclusion files.
def get_excluded_files():
	excluded = set()
	for subdir in [expectations_dir, older_expectations_dir]:
		subdir = os.path.join(repo, subdir)
		if os.path.exists(subdir):
			for excl_file in os.listdir(subdir):
				with open(os.path.join(subdir, excl_file), encoding="utf8") as excl_file:
					excluded.update([os.path.join(repo, "Source", "WebKit", x.rstrip()) for x in excl_file.readlines()])
	return excluded

for date in alldates:
	sha = shas_by_date[date]
	subprocess.check_call(["git", "checkout", sha], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
	total_loc = 0
	excluded_loc = 0
	unsafe_loc = 0
	unhandled_files = 0

	excluded_files = get_excluded_files()

	for root, dirs, files in os.walk(repo):
		for name in files:
			# We're trying to include only C++ files, not plain C files, but this is a bit inexact given that
			# .h can be for C or C++ (or sometimes bits of both with #ifdef __cplusplus etc.) For now,
			# we go with an assumption that all .h files may be included in C++ and therefore we should
			# include them in our analysis.
			if name.endswith(".cpp") or name.endswith(".h") or name.endswith(".mm") or name.endswith(".hpp"):
				fullname = os.path.join(root, name)
				within_excluded = fullname in excluded_files
				try:
					with open(fullname, encoding="utf8") as f:
						lines = f.readlines()
						within_unsafe = False
						for line in lines:
							if "WTF_ALLOW_UNSAFE_BUFFER_USAGE_BEGIN" in line:
								within_unsafe = True
							if "WTF_ALLOW_UNSAFE_BUFFER_USAGE_END" in line:
								within_unsafe = False
							total_loc += 1
							if within_unsafe:
								unsafe_loc += 1
							if within_excluded:
								excluded_loc += 1
				except:
					unhandled_files += 1
	print(",".join([str(date), sha, str(total_loc), str(excluded_loc), str(unsafe_loc), str(unhandled_files)]))
