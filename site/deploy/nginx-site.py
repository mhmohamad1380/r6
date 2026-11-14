#!/usr/bin/env python3
"""Points the root of r6.cyruson.ir at the site service and keeps every replay route on the replay backend.
Edits the shared nginx.conf IN PLACE (it is a bind mount), tests it first, and restores the backup if nginx rejects it."""
import shutil
import subprocess
import sys
import time

CONF = "/home/ubuntu/cinema-party/docker/nginx.conf"
CONTAINER = "cinema-party-nginx-1"

OLD = """    location / {
      set $r6_upstream 172.18.0.1:8090;
      proxy_pass http://$r6_upstream;
      proxy_http_version 1.1;
      proxy_request_buffering off;
      proxy_read_timeout 600s;
      proxy_send_timeout 600s;
      proxy_set_header Host $http_host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
    }
"""

UPLOAD_LIMIT = "      limit_req zone=r6up burst=500 nodelay;\n      limit_req_status 429;\n"


def backend(extra=""):
    return f"""{extra}      set $r6_upstream 172.18.0.1:8090;
      proxy_pass http://$r6_upstream;
      proxy_http_version 1.1;
      proxy_request_buffering off;
      proxy_read_timeout 600s;
      proxy_send_timeout 600s;
      proxy_set_header Host $http_host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
"""

NEW = f"""    # The replay API: exactly as before. Uploads are rate limited per address now that tokens are handed out on the site.
    location ^~ /v1/upload {{
{backend(UPLOAD_LIMIT)}    }}

    location ^~ /v1/ {{
{backend()}    }}

    location = /health {{
{backend()}    }}

    # Everything else is the website. X-Forwarded-For is OVERWRITTEN with the real address, so a visitor cannot invent one.
    location / {{
      set $r6_site 172.18.0.1:8091;
      proxy_pass http://$r6_site;
      proxy_http_version 1.1;
      proxy_read_timeout 60s;
      proxy_set_header Host $http_host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $remote_addr;
      proxy_set_header X-Forwarded-Proto $scheme;
    }}
"""

ZONE = "  limit_req_zone $binary_remote_addr zone=r6up:5m rate=120r/m;\n"
MARK = "  # --- r6.cyruson.ir: R6 replay server"


def sh(*a):
    return subprocess.run(a, capture_output=True, text=True)


text = open(CONF).read()
if "location ^~ /v1/upload" in text:
    print("already applied")
    sys.exit(0)
assert text.count(OLD) == 1, "the r6 block is not what was expected; nothing changed"
assert text.count(MARK) == 1
backup = f"{CONF}.bak-before-r6-site-{time.strftime('%Y%m%d%H%M')}"
shutil.copy2(CONF, backup)
new = text.replace(OLD, NEW).replace(MARK, ZONE + "\n" + MARK)
with open(CONF, "r+") as f:  # same inode, so the container sees the change
    f.seek(0)
    f.write(new)
    f.truncate()
t = sh("docker", "exec", CONTAINER, "nginx", "-t")
if t.returncode != 0:
    with open(CONF, "r+") as f:
        f.seek(0)
        f.write(text)
        f.truncate()
    print("nginx rejected it; restored the old file\n" + t.stderr)
    sys.exit(1)
r = sh("docker", "exec", CONTAINER, "nginx", "-s", "reload")
print("reloaded" if r.returncode == 0 else "reload failed: " + r.stderr, "| backup:", backup)
