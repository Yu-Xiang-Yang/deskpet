"""DeskPet's local voice: Qwen3-TTS (mlx-audio, Apple Silicon) speaking in a cloned voice behind the OpenAI-compatible
POST /v1/audio/speech that the pet's cloud voice uses (Settings → General → Voice, preset "本机千问").

The model loads (and speaks a short warm-up line) when the service starts and on the first request after it was
unloaded, which happens after IDLE seconds without a request, so that its memory (about 5 GB while
speaking) is taken only while the pet talks. Each voice is a folder in voices/ with ref.wav (a few seconds of the
voice) and ref.txt (what it says); the request's "voice" picks one, otherwise "default". Qwen3-TTS ignores a speaking
rate, so the service changes the pace of the generated audio itself (`stretch`, keeping the pitch).

DeskPet starts it while its cloud voice points here and passes its process id in DESKPET_VOICE_PARENT: the service
quits when that process is gone. GET /health tells whether the model is loaded.
"""
import gc
import io
import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

os.environ.setdefault("HF_HUB_OFFLINE", "1")  # everything is local: never wait for the Hugging Face Hub

import numpy as np
import soundfile as sf

HOME = Path(os.environ.get("DESKPET_VOICE_HOME", Path.home() / "Library/Application Support/DeskPet/local-voice"))
MODEL = HOME / "models" / "Qwen3-TTS-12Hz-1.7B-Base-6bit"
VOICES = HOME / "voices"
PORT = int(os.environ.get("DESKPET_VOICE_PORT", "8790"))
IDLE = float(os.environ.get("DESKPET_VOICE_IDLE", "600"))
PARENT = int(os.environ.get("DESKPET_VOICE_PARENT", "0"))

lock = threading.Lock()  # one generation at a time on the GPU
model = None
last_use = 0.0


def voice_folder(name):
    folder = VOICES / (name or "default")
    return folder if (folder / "ref.wav").exists() else VOICES / "default"


def stretch(audio, speed, rate):
    """`audio` played `speed` times as fast at the same pitch (WSOLA: 40 ms Hann windows laid at half-window steps,
    each taken from within ±10 ms of its nominal place where it continues the previous one best)."""
    if abs(speed - 1) < 0.01 or len(audio) < rate // 10:
        return audio
    from scipy.signal import correlate
    n = int(0.04 * rate) // 2 * 2
    hop, tol = n // 2, int(0.01 * rate)
    window = np.hanning(n + 1)[:n].astype(np.float32)  # periodic: windows half a window apart add up to 1
    x = np.concatenate([np.zeros(tol, np.float32), audio.astype(np.float32), np.zeros(n + 2 * tol, np.float32)])
    frames = int(len(audio) / speed / hop) + 1
    out = np.zeros(frames * hop + n, np.float32)
    weight = np.zeros_like(out)
    previous = tol
    for k in range(frames):
        nominal = tol + int(round(k * hop * speed))
        if nominal + tol + n > len(x) or previous + hop + n > len(x):
            break
        start = nominal
        if k > 0:
            follow = x[previous + hop:previous + hop + n]
            region = x[nominal - tol:nominal + tol + n]
            start = nominal - tol + int(np.argmax(correlate(region, follow, mode="valid", method="fft")))
        out[k * hop:k * hop + n] += x[start:start + n] * window
        weight[k * hop:k * hop + n] += window
        previous = start
    out /= np.maximum(weight, 1e-3)
    return out[:int(len(audio) / speed)]


def speak(text, voice, speed):
    global model, last_use
    folder = voice_folder(voice)
    ref_text = (folder / "ref.txt").read_text(encoding="utf-8").strip()
    with lock:
        if model is None:
            from mlx_audio.tts.utils import load_model
            model = load_model(str(MODEL))
        results = list(model.generate(text=text, ref_audio=str(folder / "ref.wav"), ref_text=ref_text, language="Chinese"))
        last_use = time.time()
    if not results:
        raise RuntimeError("no audio")
    audio = np.concatenate([np.array(r.audio, dtype=np.float32).reshape(-1) for r in results])
    audio = stretch(audio, speed, results[0].sample_rate)
    out = io.BytesIO()
    sf.write(out, audio, results[0].sample_rate, format="WAV", subtype="PCM_16")
    return out.getvalue()


def unload_when_idle():
    global model
    while True:
        time.sleep(5)
        if PARENT:
            try:
                os.kill(PARENT, 0)
            except OSError:  # DeskPet is gone
                os._exit(0)
        with lock:
            if model is not None and time.time() - last_use > IDLE:
                import mlx.core as mx
                model = None
                gc.collect()
                mx.clear_cache()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, status, body, kind):
        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def error(self, status, message):
        self.reply(status, json.dumps({"error": {"message": message}}, ensure_ascii=False).encode(), "application/json")

    def do_GET(self):
        if self.path.rstrip("/") == "/health":
            voices = sorted(p.parent.name for p in VOICES.glob("*/ref.wav"))
            self.reply(200, json.dumps({"ok": True, "loaded": model is not None, "voices": voices}).encode(), "application/json")
        else:
            self.error(404, "not found")

    def do_POST(self):
        if not self.path.rstrip("/").endswith("/audio/speech"):
            return self.error(404, "not found")
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
            text = str(body.get("input", "")).strip()
            if not text:
                return self.error(400, "input is empty")
            speed = min(2.0, max(0.5, float(body.get("speed", 1.0))))
            self.reply(200, speak(text, body.get("voice"), speed), "audio/wav")
        except Exception as e:  # the pet falls back to its system voice and shows the message in the settings
            self.error(500, f"{type(e).__name__}: {e}")


def warm_up():
    try:
        speak("你好。", None, 1.0)
    except Exception as e:
        print(f"warm-up failed: {e}", flush=True)


if __name__ == "__main__":
    threading.Thread(target=unload_when_idle, daemon=True).start()
    threading.Thread(target=warm_up, daemon=True).start()
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
