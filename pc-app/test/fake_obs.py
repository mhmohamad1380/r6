"""Stands in for OBS's WebSocket server (obs-websocket 5) in tests: hello with a password challenge, identify, and the
three requests the uploader uses. It also sends an unrelated event before each answer, as real OBS can.
usage: fake_obs.py PORT [PASSWORD]"""
import asyncio
import base64
import hashlib
import json
import sys
import time

import websockets

PORT = int(sys.argv[1])
PASSWORD = sys.argv[2] if len(sys.argv) > 2 else ""
SALT, CHALLENGE = "lM1GncleQOaCu9lT1yeUZhFYnqhsLLP1G5lAGo3ixaI=", "+IxH4CnCiqpX1rM9scsNynZzbOe4KhDeYcTNS3PDaeY="
state = {"active": False, "since": 0.0, "buffer": False, "saves": 0, "last": ""}
import os
NO_BUFFER = bool(os.environ.get("FAKE_OBS_NO_BUFFER"))     # as when Replay Buffer is not enabled in OBS's settings
REPLAY_DIR = os.environ.get("FAKE_OBS_REPLAY_DIR", "/tmp")


def expected_auth():
    secret = base64.b64encode(hashlib.sha256((PASSWORD + SALT).encode()).digest()).decode()
    return base64.b64encode(hashlib.sha256((secret + CHALLENGE).encode()).digest()).decode()


async def handler(ws, path=None):
    try:
        await serve_one(ws)
    except websockets.ConnectionClosed:
        pass   # the client went away: normal at the end of every test


async def serve_one(ws):
    hello = {"obsWebSocketVersion": "5.5.0", "rpcVersion": 1}
    if PASSWORD:
        hello["authentication"] = {"challenge": CHALLENGE, "salt": SALT}
    await ws.send(json.dumps({"op": 0, "d": hello}))
    ident = json.loads(await ws.recv())
    if ident.get("op") != 1 or (PASSWORD and ident["d"].get("authentication") != expected_auth()):
        await ws.close(4009, "Authentication failed.")
        return
    await ws.send(json.dumps({"op": 2, "d": {"negotiatedRpcVersion": 1}}))
    async for raw in ws:
        m = json.loads(raw)
        if m.get("op") != 6:
            continue
        d = m["d"]
        rt, rid = d["requestType"], d["requestId"]
        await ws.send(json.dumps({"op": 5, "d": {"eventType": "CurrentSceneChanged", "eventIntent": 4, "eventData": {}}}))
        ok, code, data, comment = True, 100, {}, None
        if rt == "StartRecord":
            if state["active"]:
                ok, code, comment = False, 500, "Record is already active."
            else:
                state.update(active=True, since=time.monotonic())
        elif rt == "StopRecord":
            if not state["active"]:
                ok, code, comment = False, 501, "Record is not active."
            else:
                state["active"] = False
                data = {"outputPath": "C:\\Users\\me\\Videos\\2026-11-10 20-00-00.mkv"}
        elif rt == "GetRecordStatus":
            ms = int((time.monotonic() - state["since"]) * 1000) if state["active"] else 0
            data = {"outputActive": state["active"], "outputPaused": False, "outputDuration": ms, "outputTimecode": "", "outputBytes": 0}
        elif rt == "GetReplayBufferStatus":
            if NO_BUFFER:
                ok, code, comment = False, 604, "Replay buffer is not available."
            else:
                data = {"outputActive": state["buffer"]}
        elif rt == "StartReplayBuffer":
            if NO_BUFFER:
                ok, code, comment = False, 604, "Replay buffer is not available."
            else:
                state["buffer"] = True
        elif rt == "SaveReplayBuffer":
            if not state["buffer"]:
                ok, code, comment = False, 501, "Replay buffer is not active."
            else:
                state["saves"] += 1
                state["last"] = os.path.join(REPLAY_DIR, f"Replay {state['saves']}.mkv")
                open(state["last"], "wb").write(b"saved minutes")
        elif rt == "GetLastReplayBufferReplay":
            data = {"savedReplayPath": state["last"]}
        elif rt == "FakeObsCounters":   # only this stand-in has it: lets tests count saves
            data = {"replaySaves": state["saves"]}
        else:
            ok, code, comment = False, 204, "Your request type is not valid."
        status = {"result": ok, "code": code}
        if comment:
            status["comment"] = comment
        out = {"op": 7, "d": {"requestType": rt, "requestId": rid, "requestStatus": status}}
        if ok:
            out["d"]["responseData"] = data
        await ws.send(json.dumps(out))


async def main():
    async with websockets.serve(handler, "127.0.0.1", PORT):
        print("ready", flush=True)
        await asyncio.Future()


asyncio.run(main())
