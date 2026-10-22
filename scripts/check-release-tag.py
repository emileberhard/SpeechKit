import os
import re
import subprocess

version = os.environ["VERSION"]
pattern = r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
if re.fullmatch(pattern, version) is None:
    raise SystemExit("Release tags must be MAJOR.MINOR.PATCH without a prefix or suffix")
subprocess.run([
    "git", "merge-base", "--is-ancestor", os.environ["GITHUB_SHA"],
    "origin/" + os.environ["DEFAULT_BRANCH"],
], check=True)
current = tuple(map(int, version.split(".")))
for tag in subprocess.check_output(["git", "tag", "--list"], text=True).splitlines():
    if tag != version and re.fullmatch(pattern, tag) and tuple(map(int, tag.split("."))) >= current:
        raise SystemExit("A release must be higher than every existing version tag")
