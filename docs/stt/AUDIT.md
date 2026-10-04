# STT Pipeline Audit (pre-overhaul)

Snapshot of the speech pipeline as found on `feat/desktop-companion` @ `d22bbd2`,
before the `feat/stt-overhaul` branch. Every finding below references the code
that produced it.

## Architecture as found

```text
Control+Option held 200 ms (HotkeyManager → AppState.beginPushToTalk)
  → SpeechRecognizer.startListening()                     [Audio/SpeechRecognizer.swift]
      AVAudioEngine.inputNode tap (native format, 1024 frames)
        ├─ SFSpeechAudioBufferRecognitionRequest.append()  (locale fixed to id-ID)
        ├─ AVAudioFile write  /tmp/lofly-speech.wav         (native rate, float, all channels)
        └─ RMS energy VAD → auto-finalize after 1.35 s silence
  → finishListening(): endAudio(), wait fixed 0.5 s, read *partial* liveTranscript,
    cancel task
  → AppState.onTranscriptFinalized → AgentClient.sendQuery(source: voice)
  → agent /query → runtime.handleTranscript → processTranscript (regex normalizer)
  → fastRoute / LLM
Fallback: empty transcript + speech → POST /audio → Groq whisper (only if GROQ_API_KEY)
```

| Item | Found |
| --- | --- |
| Capture | `AVAudioEngine` input tap, hardware format (typically 48 kHz Float32, 1–N ch) |
| Format to STT | Raw hardware buffers, every channel, straight into `SFSpeechAudioBufferRecognitionRequest` |
| Engine | Apple `SFSpeechRecognizer`, **single locale `id-ID`**, server or on-device (unset) |
| Normalization (audio) | None (no DC removal, no high-pass, no gain) |
| Noise suppression | None |
| Silence removal | None (whole session streamed; fallback WAV includes leading silence) |
| Chunking | Continuous stream, single request per session (good) |
| Transcript cleanup | `packages/core/src/transcript/normalizer.ts` regex rules, run for voice **and typed** text |
| Config | `STT_PROVIDER` (unused by the app), `GROQ_API_KEY`, `DEFAULT_LANGUAGES` (unused by the app) |
| Debug | Unconditional `print()` of transcripts (not visible via `log stream`, and not opt-in) |

## Root causes of unreliable transcription

1. **Last words dropped / unstable text.** `finishListening()` waits a fixed
   500 ms after `endAudio()`, then reads `liveTranscript` – the latest *partial*
   hypothesis – and calls `recognitionTask.cancel()`. The final (`isFinal`)
   result, which is the one Apple revises with full context, is never awaited
   and is thrown away. This is the main source of dropped trailing words and
   of "same sentence, different result".
2. **Push-to-talk throws speech away.** `AppState.handleHotkeyRelease` only
   submits when a partial transcript already exists. Partials lag the audio
   by 300–800 ms, so a quick "buka Spotify" + release is discarded as "no
   speech". Release also stops the mic instantly, clipping the final syllable.
3. **Auto-endpointing while the key is held.** The VAD auto-submits after
   1.35 s silence even in push-to-talk, splitting "buka Spotify… terus putar
   lagu" into one premature command.
4. **VAD can get stuck.** The noise floor starts at 0.008 RMS and only adapts
   when `rms < floor * 1.5`. In a room louder than ~0.012 RMS (fan, café) the
   floor never rises, every frame counts as "voice", and the session only
   ends at the 45 s cap. In addition, every recognizer partial resets
   `lastSpeechTime`, so a late partial revision postpones endpointing.
5. **English and code-switching.** The recognizer is pinned to `id-ID`. Pure
   English commands ("Lofly open Safari") go through the Indonesian acoustic
   + language model only.
6. **Data races.** The audio tap runs on the realtime audio thread but mutates
   `@MainActor` state (`hasSpoken`, `noiseFloor`, `preRollBuffers`,
   `lastSpeechTime`). Undefined behaviour; occasionally wrong VAD state.
7. **Dead pre-roll.** `preRollBuffers` are filled but never used (harmless,
   because the whole session is streamed, but misleading).
8. **Multi-channel input.** Aggregate/USB interfaces deliver >1 channel; all
   channels were appended to the recognizer and written to the WAV.
9. **Dictation double submit.** `ChatView.confirmVoiceRecording` sets
   `isInAppDictation = false` before the 500 ms finalize fires, so the
   dictation is inserted into the composer *and* sent to the agent as a voice
   command.
10. **Unsafe normalizer rules.** `seperti → Spotify` whenever the sentence
    contains "buka"/"open"/"lagu" ("buka file seperti ini" → "buka file
    Spotify ini"); `git up → GitHub`; the normalizer also rewrites *typed*
    text. No invariant protects numbers.
11. **No confidence / safety link.** Apple segment confidences are never read;
    the agent cannot tell a clear "kirim 250 ribu ke Budi" from a mumbled one,
    and the notch auto-approves tool confirmations.

## What was good and is kept

- One continuous recognition request per utterance (no tiny-chunk STT).
- Contextual strings biasing Apple's recognizer toward app names.
- Raw transcript preserved next to the normalized one (`ProcessedTranscript`).
- Validator for empty / looping / "thanks for watching" hallucinations.
- Push-to-talk arming threshold (200 ms) and the cancel path.
