"""Highlight clips: the PC's resumable upload, the MP4 check and fast-start rewrite, and the phone's list, playback,
sharing, editing and deleting."""
import json
import struct
import time
import uuid

import pytest

from app import highlights as H
from .conftest import RD, UP, auth


def box(kind: bytes, body: bytes) -> bytes:
    return struct.pack(">I4s", 8 + len(body), kind) + body


def mp4(seconds: float = 12.5, moov_last: bool = True, co64: bool = False, scale: int = 3) -> tuple[bytes, list[bytes]]:
    """A small MP4 in the shape real encoders write: ftyp, mdat with three 'frames', and a moov whose chunk offsets
    point at them. Returns the file and the frames, so a test can check the offsets still point at the same bytes."""
    frames = [b"FRAME-ONE-" * scale, b"FRAME-TWO-" * scale, b"FRAME-THREE" * scale]
    ftyp = box(b"ftyp", b"isom\x00\x00\x02\x00isomiso2avc1mp41")
    mvhd = box(b"mvhd", b"\x00\x00\x00\x00" + struct.pack(">IIII", 0, 0, 1000, int(seconds * 1000)) + b"\x00" * 80)

    def moov_for(offsets: list[int]) -> bytes:
        if co64:
            table = box(b"co64", b"\x00\x00\x00\x00" + struct.pack(">I", len(offsets)) + b"".join(struct.pack(">Q", o) for o in offsets))
        else:
            table = box(b"stco", b"\x00\x00\x00\x00" + struct.pack(">I", len(offsets)) + b"".join(struct.pack(">I", o) for o in offsets))
        stbl = box(b"stbl", table)
        trak = box(b"trak", box(b"mdia", box(b"minf", stbl)))
        return box(b"moov", mvhd + trak)

    payload = b"".join(frames)
    mdat = box(b"mdat", payload)
    if moov_last:
        start = len(ftyp) + 8
        offsets = [start, start + len(frames[0]), start + len(frames[0]) + len(frames[1])]
        return ftyp + mdat + moov_for(offsets), frames
    moov_size = len(moov_for([0, 0, 0]))
    start = len(ftyp) + moov_size + 8
    offsets = [start, start + len(frames[0]), start + len(frames[0]) + len(frames[1])]
    return ftyp + moov_for(offsets) + mdat, frames


def chunk_offsets(data: bytes) -> list[int]:
    out = []

    def walk(start, end):
        for kind, off, size in H._boxes(data, start, end):
            if kind in (b"moov", b"trak", b"mdia", b"minf", b"stbl"):
                walk(off + 8, off + size)
            elif kind in (b"stco", b"co64"):
                n = struct.unpack(">I", data[off + 12:off + 16])[0]
                w = 4 if kind == b"stco" else 8
                fmt = ">I" if w == 4 else ">Q"
                out.extend(struct.unpack(fmt, data[off + 16 + w * i:off + 16 + w * (i + 1)])[0] for i in range(n))
    walk(0, len(data))
    return out


# ---------- MP4 handling ----------
@pytest.mark.parametrize("co64", [False, True])
def test_fast_start_moves_the_index_first_and_keeps_every_frame_reachable(tmp_path, co64):
    data, frames = mp4(co64=co64)
    p = tmp_path / "v.mp4"
    p.write_bytes(data)
    assert H.finish_mp4(p) == 12.5
    out = p.read_bytes()
    kinds = [b[0] for b in H._boxes(out, 0, len(out))]
    assert kinds == [b"ftyp", b"moov", b"mdat"]
    assert len(out) == len(data)
    for off, frame in zip(chunk_offsets(out), frames):
        assert out[off:off + len(frame)] == frame


def test_an_mp4_already_in_fast_start_order_is_left_alone(tmp_path):
    data, _ = mp4(moov_last=False)
    p = tmp_path / "v.mp4"
    p.write_bytes(data)
    assert H.finish_mp4(p) == 12.5 and p.read_bytes() == data


@pytest.mark.parametrize("bad", [b"", b"not a video at all", box(b"ftyp", b"isom") + box(b"mdat", b"x"), b"\x00\x00\x00\x08ftyp" + b"\xff" * 20])
def test_anything_else_is_not_an_mp4(tmp_path, bad):
    p = tmp_path / "v.mp4"
    p.write_bytes(bad)
    with pytest.raises((ValueError, struct.error)):
        H.finish_mp4(p)


# ---------- the API ----------
def meta(size: int, hid: str | None = None, **over) -> dict:
    m = {
        "id": hid or str(uuid.uuid4()), "match_id": "b03d682b-5e26-49c4-bf57-aca9acab58c4", "round": 4, "type": "multikill",
        "tags": ["multikill", "entry"], "score": 7, "clutch_vs": 0, "won": True, "side": "Attack", "operator": "Ash", "map": "Bank",
        "mode": "Ranked", "played_at": "2026-10-30T22:54:35Z",
        "kills": [{"t": 48.0, "clock": 132, "victim": "E0", "victim_operator": "Jager", "headshot": True, "post_plant": False}],
        "clip": {"from": 43.0, "to": 64.0, "approx": False}, "video": {"size": size, "duration": 21.0},
    }
    m.update(over)
    return m


def send(client, data: bytes, piece: int = 7, **over) -> dict:
    """Create the clip and upload it in pieces, the way the PC does."""
    m = meta(len(data), **over)
    r = client.post("/v1/highlights", headers=auth(UP), content=json.dumps(m))
    assert r.status_code == 201, r.text
    pos = 0
    while pos < len(data):
        r = client.put(f"/v1/highlights/{m['id']}/video?offset={pos}", headers=auth(UP), content=data[pos:pos + piece])
        assert r.status_code == 200, r.text
        pos = r.json()["received"]
    return {"id": m["id"], "last": r.json()}


def test_upload_in_pieces_ends_ready_with_its_length(client):
    data, _ = mp4()
    out = send(client, data)
    assert out["last"]["status"] == "ready" and out["last"]["duration"] == 12.5
    lst = client.get("/v1/highlights", headers=auth(RD)).json()
    h = lst["highlights"][0]
    assert h["id"] == out["id"] and h["status"] == "ready" and h["map"] == "Bank" and h["kills"][0]["victim"] == "E0"
    assert h["videoUrl"] == f"/v1/highlights/{out['id']}/video" and h["thumbnailUrl"] is None
    assert lst["storage"]["usedBytes"] == len(data)


def test_a_broken_upload_resumes_from_where_the_server_is(client):
    data, _ = mp4()
    m = meta(len(data))
    client.post("/v1/highlights", headers=auth(UP), content=json.dumps(m))
    assert client.put(f"/v1/highlights/{m['id']}/video?offset=0", headers=auth(UP), content=data[:10]).json()["received"] == 10
    # The PC lost the answer and sends the first piece again: refused, with the right place to continue.
    r = client.put(f"/v1/highlights/{m['id']}/video?offset=0", headers=auth(UP), content=data[:10])
    assert r.status_code == 409 and r.json()["received"] == 10
    # Or it starts again after a restart: creating the same clip again says how far it got.
    r = client.post("/v1/highlights", headers=auth(UP), content=json.dumps(m))
    assert r.json()["received"] == 10 and r.json()["status"] == "uploading"
    assert client.get(f"/v1/highlights/{m['id']}/upload", headers=auth(UP)).json()["received"] == 10
    assert client.put(f"/v1/highlights/{m['id']}/video?offset=10", headers=auth(UP), content=data[10:]).json()["status"] == "ready"
    # Sending a finished clip again is a no-op.
    r = client.post("/v1/highlights", headers=auth(UP), content=json.dumps(m))
    assert r.status_code == 200 and r.json()["status"] == "ready"


def test_a_file_that_is_not_an_mp4_is_refused_at_the_end(client):
    data = b"this is not a video, just some text " * 3
    m = meta(len(data))
    client.post("/v1/highlights", headers=auth(UP), content=json.dumps(m))
    r = client.put(f"/v1/highlights/{m['id']}/video?offset=0", headers=auth(UP), content=data)
    assert r.status_code == 422 and "MP4" in r.json()["detail"]
    assert client.get("/v1/highlights", headers=auth(RD)).json()["highlights"] == []


def test_more_than_announced_is_refused(client):
    m = meta(10)
    client.post("/v1/highlights", headers=auth(UP), content=json.dumps(m))
    assert client.put(f"/v1/highlights/{m['id']}/video?offset=0", headers=auth(UP), content=b"x" * 11).status_code == 400


def test_who_may_do_what(client):
    data, _ = mp4()
    m = meta(len(data))
    assert client.post("/v1/highlights", content=json.dumps(m)).status_code == 401
    assert client.post("/v1/highlights", headers=auth(RD), content=json.dumps(m)).status_code == 403   # the phone cannot upload
    out = send(client, data)
    assert client.get("/v1/highlights", headers=auth(UP)).status_code == 403                              # the PC cannot list
    assert client.get(f"/v1/highlights/{out['id']}/video").status_code == 401
    assert client.delete(f"/v1/highlights/{out['id']}", headers=auth(UP)).status_code == 403


@pytest.mark.parametrize("change,why", [
    ({"id": "not-an-id"}, "id"), ({"type": "dance"}, "type"), ({"tags": ["wow"]}, "tags"), ({"kills": []}, "kills"),
    ({"round": 0}, "round"), ({"score": "lots"}, "score"), ({"video": {"size": 0, "duration": 5}}, "video.size"),
    ({"map": "x" * 61}, "map"), ({"clip": None}, "clip"),
])
def test_details_are_checked(client, change, why):
    r = client.post("/v1/highlights", headers=auth(UP), content=json.dumps(meta(100, **change)))
    assert r.status_code == 422 and why in r.json()["detail"]


def test_storage_is_limited(make):
    c = make(clips_quota_bytes=1000)
    data, _ = mp4()
    send(c, data)
    r = c.post("/v1/highlights", headers=auth(UP), content=json.dumps(meta(1000)))
    assert r.status_code == 507 and "full" in r.json()["detail"]


def test_the_video_plays_with_seeking_and_the_thumbnail_is_a_jpeg(client):
    data, _ = mp4()
    out = send(client, data)
    hid = out["id"]
    full = client.get(f"/v1/highlights/{hid}/video", headers=auth(RD))
    assert full.status_code == 200 and full.headers["content-type"] == "video/mp4" and len(full.content) == len(data)
    part = client.get(f"/v1/highlights/{hid}/video", headers={**auth(RD), "Range": "bytes=10-19"})
    assert part.status_code == 206 and part.content == full.content[10:20]
    assert client.put(f"/v1/highlights/{hid}/thumbnail", headers=auth(UP), content=b"PNG not jpeg").status_code == 422
    assert client.put(f"/v1/highlights/{hid}/thumbnail", headers=auth(UP), content=b"\xff\xd8\xff\xe0" + b"j" * 100).status_code == 200
    h = client.get(f"/v1/highlights/{hid}", headers=auth(RD)).json()
    assert h["thumbnailUrl"] == f"/v1/highlights/{hid}/thumbnail"
    assert client.get(h["thumbnailUrl"], headers=auth(RD)).content.startswith(b"\xff\xd8")


def test_share_links_play_without_a_token_until_the_clip_is_made_private(client):
    data, _ = mp4()
    hid = send(client, data)["id"]
    link = client.post(f"/v1/highlights/{hid}/share", headers=auth(RD)).json()
    assert client.get(link["videoUrl"]).status_code == 200
    assert client.get(f"/v1/highlights/{hid}", headers=auth(RD)).json()["visibility"] == "unlisted"
    tampered = link["videoUrl"].replace("sig=", "sig=0")
    assert client.get(tampered).status_code == 403
    expired = f"/v1/highlights/{hid}/video?exp={int(time.time()) - 5}&sig=" + link["videoUrl"].split("sig=")[1]
    assert client.get(expired).status_code == 403
    client.patch(f"/v1/highlights/{hid}", headers=auth(RD), content=json.dumps({"visibility": "private"}))
    assert client.get(link["videoUrl"]).status_code == 403   # the old link stopped working
    link2 = client.post(f"/v1/highlights/{hid}/share", headers=auth(RD)).json()
    assert client.get(link2["videoUrl"]).status_code == 200  # a new one works


def test_rename_and_delete_show_up_in_the_feed(client):
    data, _ = mp4()
    a, b = send(client, data)["id"], send(client, data)["id"]
    first = client.get("/v1/highlights", headers=auth(RD)).json()
    cursor = first["nextCursor"]
    assert len(first["highlights"]) == 2
    r = client.patch(f"/v1/highlights/{a}", headers=auth(RD), content=json.dumps({"title": "  My best ace  "}))
    assert r.json()["title"] == "My best ace"
    assert client.patch(f"/v1/highlights/{a}", headers=auth(RD), content=json.dumps({"visibility": "public"})).status_code == 422
    d = client.delete(f"/v1/highlights/{b}", headers=auth(RD)).json()
    assert d["deleted"] and d["freedBytes"] == len(data)
    later = client.get(f"/v1/highlights?after={cursor}", headers=auth(RD)).json()["highlights"]
    assert [(x["id"], x.get("title"), x.get("deleted", False)) for x in later] == [(a, "My best ace", False), (b, None, True)]
    assert client.get(f"/v1/highlights/{b}/video", headers=auth(RD)).status_code == 404
    assert client.get("/v1/highlights", headers=auth(RD)).json()["storage"]["usedBytes"] == len(data)


def test_pages_follow_the_cursor(client):
    data, _ = mp4()
    ids = [send(client, data)["id"] for _ in range(5)]
    got, cursor = [], 0
    while True:
        page = client.get(f"/v1/highlights?after={cursor}&limit=2", headers=auth(RD)).json()
        got += [h["id"] for h in page["highlights"]]
        cursor = page["nextCursor"]
        if not page["hasMore"]:
            break
    assert got == ids
