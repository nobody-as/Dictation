import json
import math
import os
import shutil
import struct
import subprocess
import tempfile
import threading
import wave
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import torch
import torchaudio
from speechbrain.inference.speaker import EncoderClassifier

# Ensure Homebrew and standard binary directories are in PATH so ffmpeg is always found
HOMEBREW_PATHS = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"]
_path_elements = os.environ.get("PATH", "").split(":")
for _p in reversed(HOMEBREW_PATHS):
    if _p not in _path_elements and os.path.exists(_p):
        _path_elements.insert(0, _p)
os.environ["PATH"] = ":".join(_path_elements)

import mlx_whisper


MODEL_PATH = "mlx-community/whisper-large-v3-turbo"
MODEL_LABEL = "Whisper Large v3 Turbo"
FFMPEG = shutil.which("ffmpeg")
MLX_EXECUTOR = ThreadPoolExecutor(max_workers=1, thread_name_prefix="mlx-whisper")
ENGINE_STATE_LOCK = threading.Lock()
ENGINE_STATE = {"state": "starting", "detail": "Loading speech model"}

HALLUCINATIONS = {
    "transcription by castingwords",
    "transcribed by castingwords",
    "subtitles by the amara.org community",
    "thank you for watching",
    "thank you for watching!",
    "thanks for watching",
    "thanks for watching!",
    "please subscribe",
    "please like and subscribe",
    "thank you.",
    "thank you",
    "you",
    "bye",
    "goodbye",
    "mbc",
    "english - us",
    "transcription by",
}


def set_engine_state(state, detail):
    with ENGINE_STATE_LOCK:
        ENGINE_STATE["state"] = state
        ENGINE_STATE["detail"] = detail


def engine_snapshot():
    with ENGINE_STATE_LOCK:
        return dict(ENGINE_STATE)


def check_audio_is_silent(audio_path, min_peak=500, min_rms=50.0):
    """Detect if an audio clip contains only pure silence or near-zero background noise."""
    try:
        with wave.open(audio_path, "rb") as wf:
            frames = wf.getnframes()
            if frames < 1600:  # less than 0.1s at 16kHz
                return True, "Audio too short (< 0.1s)"
            raw = wf.readframes(frames)
            count = len(raw) // 2
            if count == 0:
                return True, "Empty audio frames"
            samples = struct.unpack(f"<{count}h", raw)
            peak = max(abs(s) for s in samples)
            sum_sq = sum(s * s for s in samples)
            rms = (sum_sq / count) ** 0.5
            if peak < min_peak or rms < min_rms:
                return True, f"Silence detected (peak={peak}, rms={rms:.1f})"
            return False, f"Audio energy OK (peak={peak}, rms={rms:.1f})"
    except Exception as error:
        print(f"Energy check warning: {error}", flush=True)
        return False, "Check skipped"


def preprocess_audio(source_path, destination_path):
    """Apply gentle highpass filtering to remove low-frequency rumble without distorting speech."""
    if not FFMPEG:
        return source_path, False

    command = [
        FFMPEG,
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-i",
        source_path,
        "-af",
        "highpass=f=80,lowpass=f=8000",
        "-ar",
        "16000",
        "-ac",
        "1",
        "-c:a",
        "pcm_s16le",
        destination_path,
    ]

    try:
        file_size = os.path.getsize(source_path) if os.path.exists(source_path) else 0
        calc_timeout = max(120, int(file_size / 50000))
        subprocess.run(command, check=True, capture_output=True, timeout=calc_timeout)
        return destination_path, True
    except (OSError, subprocess.SubprocessError) as error:
        print(f"Audio preprocessing skipped; using original audio: {error}", flush=True)
        return source_path, False


def normalize_transcript(text):
    """Clean whitespace and filter out common Whisper silence hallucinations."""
    cleaned = " ".join(text.strip().split())
    stripped = cleaned.lower().strip(" .!?,:;\"'")
    if stripped in HALLUCINATIONS:
        print(f"Filtered silence hallucination: '{cleaned}'", flush=True)
        return ""
    for h in HALLUCINATIONS:
        if stripped == h or stripped.startswith(h):
            print(f"Filtered silence hallucination: '{cleaned}'", flush=True)
            return ""
    return cleaned


def prewarm_model():
    print(f"Pre-warming MLX Whisper model: {MODEL_PATH}...", flush=True)
    try:
        with tempfile.NamedTemporaryFile(suffix=".wav") as blank_audio:
            mlx_whisper.transcribe(blank_audio.name, path_or_hf_repo=MODEL_PATH)
    except Exception:
        pass
    set_engine_state("ready", f"{MODEL_LABEL} ready")
    print("Model pre-warmed and ready.", flush=True)


def transcribe_with_mlx(audio_path):
    # Use a demonstration prompt instead of instructions. Whisper uses the prompt
    # to infer style, capitalization, and punctuation, rather than obeying commands.
    # We include varied punctuation, numbers, and structural elements (titles, paragraphs, bullets).
    demo_prompt = (
        "Title: Dictation Formatting\n\n"
        "Welcome to this dictation. We format text with proper capitalization and punctuation.\n\n"
        "- We naturally support bullet points.\n"
        "- We handle names like Apple and numbers like $100.00 perfectly."
    )
    
    return mlx_whisper.transcribe(
        audio_path,
        path_or_hf_repo=MODEL_PATH,
        language="en",
        task="transcribe",
        # Standard fallback sequence to recover from hallucinations or low confidence
        temperature=(0.0, 0.2, 0.4, 0.6, 0.8, 1.0),
        condition_on_previous_text=False,
        initial_prompt=demo_prompt,
        word_timestamps=False,
        # Standard Whisper thresholds for suppressing hallucinations
        no_speech_threshold=0.6,
        compression_ratio_threshold=2.4,
        logprob_threshold=-1.0,
        hallucination_silence_threshold=1.5,
        verbose=False,
    )


# Model creation and every decode run on the same worker because MLX GPU streams
# are thread-bound. HTTP health checks remain responsive on their own threads.
MLX_EXECUTOR.submit(prewarm_model).result()

SPEAKER_DB_PATH = os.path.expanduser("~/.dictation_speakers.json")

class SpeakerIdentifier:
    def __init__(self):
        print("Loading speaker model...", flush=True)
        try:
            self.classifier = EncoderClassifier.from_hparams(
                source="speechbrain/spkrec-ecapa-voxceleb", 
                savedir=os.path.expanduser("~/.speechbrain/spkrec-ecapa-voxceleb"),
                run_opts={"device": "cpu"}
            )
            print("Speaker model loaded.", flush=True)
        except Exception as e:
            print(f"Failed to load speaker model: {e}", flush=True)
            self.classifier = None
        self.speakers = {}
        self.load_speakers()

    def load_speakers(self):
        if os.path.exists(SPEAKER_DB_PATH):
            try:
                with open(SPEAKER_DB_PATH, "r") as f:
                    data = json.load(f)
                    for k, v in data.items():
                        self.speakers[k] = torch.tensor(v)
            except Exception as e:
                print(f"Error loading speaker DB: {e}")

    def save_speakers(self):
        try:
            with open(SPEAKER_DB_PATH, "w") as f:
                serializable = {k: v.tolist() for k, v in self.speakers.items()}
                json.dump(serializable, f)
        except Exception as e:
            print(f"Error saving speaker DB: {e}")

    def identify_speaker(self, audio_path, start_sec=None, end_sec=None):
        if self.classifier is None:
            return None
        try:
            # Load using soundfile to avoid TorchCodec errors
            import soundfile as sf
            audio_data, fs = sf.read(audio_path, dtype='float32')
            if audio_data.ndim > 1:
                audio_data = audio_data.mean(axis=1) # mix to mono
            signal = torch.tensor(audio_data).unsqueeze(0)
            
            if fs != 16000:
                signal = torchaudio.transforms.Resample(orig_freq=fs, new_freq=16000)(signal)
            
            if start_sec is not None and end_sec is not None:
                start_sample = int(start_sec * 16000)
                end_sample = int(end_sec * 16000)
                signal = signal[:, start_sample:end_sample]
            
            if signal.shape[1] < 16000 * 0.3: # skip very short segments
                return None
                
            emb = self.classifier.encode_batch(signal).squeeze()
            
            if not self.speakers:
                self.speakers["Speaker 1"] = emb
                self.save_speakers()
                return "Speaker 1"
                
            best_sim = -1
            best_speaker = None
            
            for name, stored_emb in self.speakers.items():
                sim = torch.nn.functional.cosine_similarity(emb, stored_emb, dim=0).item()
                if sim > best_sim:
                    best_sim = sim
                    best_speaker = name
                    
            if best_sim > 0.65:
                # Update centroid (90% old, 10% new)
                self.speakers[best_speaker] = 0.9 * self.speakers[best_speaker] + 0.1 * emb
                self.save_speakers()
                return best_speaker
            else:
                new_id = len(self.speakers) + 1
                new_name = f"Speaker {new_id}"
                self.speakers[new_name] = emb
                self.save_speakers()
                return new_name
        except Exception as e:
            print(f"Speaker identification error: {e}")
            return None

# Speaker profiles are not used by the transcription endpoint. Do not load
# or modify the personal speaker database as a backend startup side effect.

class DictationServer(BaseHTTPRequestHandler):

    server_version = "MacLocalDictation/2.2"

    def log_message(self, format, *args):
        pass

    def send_json(self, status_code, payload):
        encoded = json.dumps(payload).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def do_GET(self):
        if self.path == "/health":
            state = engine_snapshot()
            self.send_json(
                200,
                {
                    "status": "ok",
                    "engine": state["state"],
                    "detail": state["detail"],
                    "model": MODEL_LABEL,
                },
            )
            return

        self.send_json(404, {"error": "not found"})

    def do_POST(self):
        if self.path == "/shutdown":
            self.send_json(202, {"status": "stopping"})
            threading.Thread(target=self.server.shutdown, daemon=True).start()
            return

        if self.path != "/transcribe":
            self.send_json(404, {"error": "not found"})
            return

        content_length = int(self.headers.get("Content-Length", 0))
        if content_length <= 0:
            self.send_json(400, {"error": "empty audio"})
            return

        source_path = None
        filtered_path = None
        try:
            with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as source:
                source_path = source.name
                source.write(self.rfile.read(content_length))

            # Step 1: Check if audio is pure silence or sub-audible noise
            is_silent, reason = check_audio_is_silent(source_path)
            if is_silent:
                print(f"Received audio but skipped transcription: {reason}", flush=True)
                self.send_json(
                    200,
                    {
                        "text": "",
                        "language": "en",
                        "model": MODEL_LABEL,
                        "noise_filtered": False,
                        "detail": reason,
                    },
                )
                return

            filtered_file = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
            filtered_path = filtered_file.name
            filtered_file.close()
            audio_path, did_filter = preprocess_audio(source_path, filtered_path)

            print("Received audio. Transcribing...", flush=True)
            set_engine_state("transcribing", "Converting speech to text")
            result = MLX_EXECUTOR.submit(transcribe_with_mlx, audio_path).result()

            segments = result.get("segments", [])
            final_text_parts = []
            current_speaker = None
            
            # If no segments (should be rare), fallback to raw text
            if not segments:
                text = normalize_transcript(result.get("text", ""))
                final_text_parts.append(text)
            else:
                for segment in segments:
                    seg_text = normalize_transcript(segment.get("text", ""))
                    if not seg_text:
                        continue
                    final_text_parts.append(f" {seg_text}" if final_text_parts else seg_text)
            
            text = "".join(final_text_parts).strip()
            
            print(f"Transcription: '{text}'", flush=True)
            self.send_json(
                200,
                {
                    "text": text,
                    "language": result.get("language", "en"),
                    "model": MODEL_LABEL,
                    "noise_filtered": did_filter,
                },
            )
        except Exception as error:
            print(f"Transcription error: {error}", flush=True)
            self.send_json(500, {"error": str(error)})
        finally:
            set_engine_state("ready", f"{MODEL_LABEL} ready")
            for path in (source_path, filtered_path):
                if path and os.path.exists(path):
                    try:
                        os.remove(path)
                    except OSError:
                        pass


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", 8080), DictationServer)
    print("Dictation Backend listening on http://127.0.0.1:8080", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        MLX_EXECUTOR.shutdown(wait=True)
