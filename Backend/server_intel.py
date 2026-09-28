"""Local CPU transcription server for Intel Macs."""

import json
import os
import tempfile
import threading
import wave
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from faster_whisper import WhisperModel


MODEL_LABEL = "Whisper Small (CPU)"
STATE_LOCK = threading.Lock()
STATE = {"state": "starting", "detail": "Downloading or loading speech model", "progress": 0.0}
WORKER = ThreadPoolExecutor(max_workers=1, thread_name_prefix="cpu-whisper")


def set_state(state, detail, progress=0.0):
    with STATE_LOCK:
        STATE.update(state=state, detail=detail, progress=progress)


def load_model():
    try:
        model = WhisperModel(
            "small",
            device="cpu",
            compute_type="int8",
            cpu_threads=min(os.cpu_count() or 2, 4),
        )
        set_state("ready", f"{MODEL_LABEL} ready")
        return model
    except Exception as error:
        set_state("error", f"Could not load speech model: {error}")
        raise


MODEL_FUTURE = WORKER.submit(load_model)


def transcribe(path):
    model = MODEL_FUTURE.result()
    set_state("transcribing", "Converting speech to text")
    try:
        segments, info = model.transcribe(
            path,
            language="en",
            beam_size=1,
            condition_on_previous_text=False,
            vad_filter=True,
        )
        text = " ".join(segment.text.strip() for segment in segments).strip()
        return {"text": text, "language": info.language, "model": MODEL_LABEL, "noise_filtered": False}
    finally:
        set_state("ready", f"{MODEL_LABEL} ready")


class DictationServer(BaseHTTPRequestHandler):
    server_version = "MacLocalDictation/2.2"

    def log_message(self, format, *args):
        pass

    def send_json(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path != "/health":
            self.send_json(404, {"error": "not found"})
            return
        with STATE_LOCK:
            state = dict(STATE)
        self.send_json(200, {"status": "ok", "engine": state["state"], "detail": state["detail"], "model": MODEL_LABEL, "progress": state["progress"]})

    def do_POST(self):
        if self.path == "/shutdown":
            self.send_json(202, {"status": "stopping"})
            threading.Thread(target=self.server.shutdown, daemon=True).start()
            return
        if self.path != "/transcribe":
            self.send_json(404, {"error": "not found"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        if length <= 0 or length > 100 * 1024 * 1024:
            self.send_json(400, {"error": "invalid audio size"})
            return
        path = None
        try:
            with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as audio:
                path = audio.name
                audio.write(self.rfile.read(length))
            with wave.open(path, "rb") as audio:
                if audio.getnframes() < audio.getframerate() // 10:
                    self.send_json(200, {"text": "", "language": "en", "model": MODEL_LABEL, "noise_filtered": False})
                    return
            self.send_json(200, WORKER.submit(transcribe, path).result())
        except Exception as error:
            self.send_json(500, {"error": str(error)})
        finally:
            if path:
                os.unlink(path)


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", 8080), DictationServer)
    try:
        server.serve_forever()
    finally:
        server.server_close()
        WORKER.shutdown(wait=True)
