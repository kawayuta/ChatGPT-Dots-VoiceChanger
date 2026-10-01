"""Read-only review of files eligible for Git; never prints matching secrets."""
import pathlib
import re
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parent.parent
files = subprocess.check_output(
    ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=root
).decode().split("\0")
patterns = {
    "private key": re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    "cloud access key": re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"),
    "API credential": re.compile(r"\bsk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{24,}\b"),
    "GitHub credential": re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})\b"),
    "personal absolute path": re.compile(r"/(?:Users|home)/[^/\s<>]+/"),
}
forbidden = {".p12", ".p8", ".pem", ".key", ".mobileprovision", ".provisionprofile", ".wav", ".aiff", ".mp3", ".m4a", ".caf"}
findings = []
checked = 0
for name in files:
    if not name:
        continue
    path = root / name
    if not path.is_file():
        continue
    checked += 1
    if path.suffix.lower() in forbidden or name.endswith(".private.json"):
        findings.append((name, 0, "private credential/audio artifact"))
        continue
    data = path.read_bytes()
    if b"\0" in data:
        continue
    for number, line in enumerate(data.decode("utf-8", errors="replace").splitlines(), 1):
        for label, pattern in patterns.items():
            if pattern.search(line):
                findings.append((name, number, label))
for name, line, label in findings:
    print(f"REVIEW_REQUIRED {name}:{line} {label}")
print(f"SECURITY_REVIEW files_checked={checked} findings={len(findings)} (heuristic; manual review still required)")
sys.exit(1 if findings else 0)
