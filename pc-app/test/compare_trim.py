"""The Windows app's trimmed round must equal the server's reference trim of the same replay, field for field."""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

payloads, backend, samples = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
sys.path.insert(0, str(backend))
from app.parsed import trim_dissect  # noqa: E402

checked = 0
for p in sorted(payloads.glob("*.json")):
    sent = json.loads(p.read_text())["round"]
    rec = samples / p.name.replace(".json", "")
    with tempfile.TemporaryDirectory() as t:
        out = Path(t) / "r.json"
        subprocess.run([str(backend / "bin" / "r6-dissect"), str(rec), "-o", str(out)], check=True, capture_output=True)
        expected = trim_dissect(json.loads(out.read_text()))
    if sent != expected:
        for k in sorted(set(sent) | set(expected)):
            if sent.get(k) != expected.get(k):
                print(f"MISMATCH {p.name}: {k}\n  app:    {json.dumps(sent.get(k))[:300]}\n  server: {json.dumps(expected.get(k))[:300]}")
        sys.exit(1)
    checked += 1
    print(f"identical: {p.name.replace('.json', '')}  ({len(json.dumps(sent, separators=(',', ':')))} bytes of JSON)")
print(f"trim check: {checked} replay(s) identical to the server's reference")
sys.exit(0 if checked else 1)
