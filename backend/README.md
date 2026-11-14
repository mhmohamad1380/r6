# R6 replay server

Siege saves one `.rec` replay per round on your PC, and the game only keeps the last 10 to 12 matches.
This server collects them so your phone can analyse them:

```
gaming PC ──upload .rec──▶ server (parses with r6-dissect) ──small JSON──▶ phone app
                                  ▲                                          │
                                  └────── ack: "saved it, delete the .rec" ──┘
```

A 9.4 MB `.rec` becomes about 6 KB of data, so the phone downloads the data, analyses it, saves it,
and then tells the server it is done. The phone cannot parse `.rec` files itself.

**The server does not keep the `.rec`.** As soon as a file is parsed, its analysis is stored in the database (`replays.db`, a few KB per round) and the `.rec` is deleted, so the disk only holds small data. The file's SHA-256 is kept, so the PC sending it again is ignored. A file that fails to parse is the exception: it is kept (up to 30 days) so a retry can parse it once the parser is updated, and it is released as soon as a retry succeeds. Set `R6_KEEP_REC=1` to keep every file.

Both files the PC sends are accepted: the plain `dissect` format that current game versions write, and zstd-compressed ones.

Two tokens, created on first run (`data/tokens.json`, mode 600):

| Token | Held by | Can |
|---|---|---|
| **upload token** | the PC uploader | upload only |
| **read token** | the phone | list, download, acknowledge, delete |

Send it as `Authorization: Bearer <token>` (or `X-Api-Key: <token>`). Use HTTPS when the server is on
the internet: the tokens are secrets.

## API

| Method and path | Token | What it does |
|---|---|---|
| `GET /health` | none | `{ok, version, dissect, arenyzeFallback}` |
| `POST /v1/upload` | upload | multipart; each file in a `files` (or `replayFiles`) field; up to 20 files |
| `POST /v1/upload/raw?filename=x.rec` | upload | the body is the `.rec` itself (`application/octet-stream`) |
| `GET /v1/rounds?after=0&limit=25` | read | rounds changed since `after`; follow `nextCursor` while `hasMore` |
| `GET /v1/rounds/{id}/rec` | read | the original `.rec`; only exists for a failed parse or with `R6_KEEP_REC=1` (404 otherwise) |
| `POST /v1/ack` `{"ids":[1,2],"purge":false}` | read | releases those `.rec` files if any are left; `purge` also drops the analysis (the phone calls this after saving) |
| `DELETE /v1/rounds/{id}?purge=0&force=0` | read | same for one round; `force` allows deleting a file that failed to parse |
| `POST /v1/rounds/{id}/retry` | read | parse a failed file again |
| `GET /v1/stats` | read | counts and disk use |

Upload result per file: `parsed`, `duplicate` (same content already known), `failed` (kept, with the
reason) or `rejected` (not a replay, too large, storage full).

```sh
curl -H "Authorization: Bearer $UPLOAD" --data-binary @Match-R01.rec \
     -H "Content-Type: application/octet-stream" "$URL/v1/upload/raw?filename=Match-R01.rec"
curl -H "Authorization: Bearer $READ" "$URL/v1/rounds?after=0"
curl -H "Authorization: Bearer $READ" -H "Content-Type: application/json" -d '{"ids":[1]}' "$URL/v1/ack"
```

Behaviour worth knowing:

- **Safe delete.** `ack` never deletes a file that failed to parse (it would be the only copy), unless forced.
- **Duplicates are remembered.** After a delete the server keeps only the file's fingerprint, so your PC
  re-sending an old file does not bring it back. `purge` also drops the parsed data.
- **The cursor follows changes**, not ids: a failed file that is later fixed by `retry` appears again
  even if the phone already passed it.
- **Retention.** Undelivered `.rec` files are removed after 30 days (the parsed data stays).
- **Parsers.** r6-dissect first (exact kill times). If it cannot read a file, for example a newer game
  version, and `R6_ARENYZE_KEY` is set, the file is sent to Arenyze instead (kill order only, and one of
  your replay credits per file).

## Settings (environment variables)

`R6_DATA_DIR` (default `./data`), `UPLOAD_TOKEN`, `READ_TOKEN`, `R6_DISSECT_BIN`, `R6_ARENYZE_KEY`,
`R6_MAX_FILE_MB` (60), `R6_MAX_FILES` (20), `R6_MAX_STORAGE_MB` (2048), `R6_REC_RETENTION_DAYS` (30),
`R6_DISSECT_TIMEOUT` (90).

## Run locally

```sh
uv sync && ./run.sh            # http://<this-machine>:8090, tokens printed on first run
uv run pytest                  # 48 tests, using real sample replays (see tests/samples)
```

Sample replays are not committed. Get them from
[r6-dissect](https://github.com/redraskal/r6-dissect/tree/main/dissect/test/data/replays) and put
`quick_1.rec`, `ranked_2.rec`, `corrupted.rec` and `not_zstd.rec` in `tests/samples/`.

## Deploy to an Ubuntu server

```sh
deploy/make-bundle.sh                       # builds r6-replay-server.tar.gz
scp r6-replay-server.tar.gz you@server:     # then on the server:
tar xzf r6-replay-server.tar.gz && bash deploy/install.sh
```

The installer sets up a systemd service running as an unprivileged user with a hardened unit, downloads
and checksums r6-dissect, and puts Caddy in front for HTTPS. With no domain it uses
`<ip-with-dashes>.sslip.io`, which resolves to your IP. Open ports 80 and 443 (also in the provider's
firewall). Use `--domain` for your own name or `--no-tls` for plain HTTP on port 8090.

Check it: `curl https://<name>/health`. Logs: `sudo journalctl -u r6-replay -f`.
