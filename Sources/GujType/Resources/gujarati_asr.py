#!/usr/bin/env python3
"""Offline Gujarati ASR entry point for GujType."""
import sys
import onnx_asr

if len(sys.argv) != 3:
    raise SystemExit("usage: gujarati_asr.py MODEL_DIRECTORY AUDIO_WAV")

model_directory, audio_path = sys.argv[1:]
model = onnx_asr.load_model(
    "nemo-conformer-ctc",
    path=model_directory,
    quantization="int8",
)
result = model.recognize(audio_path)
print(result)
