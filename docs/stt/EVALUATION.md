# STT Pipeline Evaluation

This document outlines the testing and evaluation of the newly overhauled Speech-to-Text (STT) pipeline in Lofly, specifically addressing the reliability issues found in the previous audit.

## Improvements Addressed

The new architecture (using `SpeechRecognizer`, `AppleSpeechEngine`, `SpeechSegmenter`, and `AgentWhisperEngine`) resolves the previous pain points:

1. **Missing Trailing Words**: The engine now waits for the `isFinal` result from Apple Speech after the user stops speaking, rather than capturing the latest partial hypothesis and cutting it off.
2. **Push-to-Talk Early Release**: If the user releases the push-to-talk button quickly, the pipeline captures the complete audio (up to the release) and properly processes it, rather than instantly discarding it as "no speech". A short tail delay (release tail) ensures the last syllable is not clipped.
3. **Adaptive VAD**: The `SpeechSegmenter` implements an adaptive noise floor that recalculates based on ambient background noise (preventing the mic from being permanently stuck "on" in loud environments).
4. **Multi-Locale / Mixed Speech**: We now stream audio concurrently to primary (`id-ID`) and secondary (`en-US` by default) recognizers, picking the one with the highest confidence or using the primary as the fallback. This drastically improves detection of English application names and code-switching.
5. **Cloud Fallback**: If Apple Speech returns no text or the transcription is highly uncertain, the recorded 16kHz WAV is sent to the server for processing with Whisper (`AgentWhisperEngine`), acting as a safety net for complex terminology or edge-case numbers.
6. **Thread Safety**: All state mutation during the real-time audio tap is contained in `SpeechSegmenter` with internal locking, and only safe summary events are dispatched back to the main thread.

## Manual Test Plan for the User

Since automated integration tests for audio require pre-recorded voice files, you can manually verify the fixes using the following scenarios:

### Test 1: Push-To-Talk Speed (Trailing Words)
- **Action**: Hold the hotkey, say quickly "Buka aplikasi Spotify", and release the key immediately after the last syllable.
- **Expected**: The transcript correctly includes "Spotify" and doesn't get clipped as "Buka aplika".

### Test 2: Background Noise (VAD Adaptation)
- **Action**: Play background music or fan noise in your room. Use hands-free voice input (don't hold a hotkey, just trigger voice). Speak a sentence and stop.
- **Expected**: The system should successfully detect when you stop speaking and submit the transcription automatically, rather than getting stuck listening forever due to the background noise.

### Test 3: Mixed Language & Technical Terms
- **Action**: Speak the following: "Tolong jalankan script deploy to production di terminal."
- **Expected**: The multi-locale engine or the cloud fallback should accurately catch "script", "deploy", "production", and "terminal" without mangling them into Indonesian look-alike words.

### Test 4: Number and Entity Invariants
- **Action**: "Kirim uang 250 ribu ke Budi."
- **Expected**: Numbers should remain stable, and not be hallucinated out by the previous over-aggressive normalization rules.

### Test 5: In-App Dictation
- **Action**: Click the microphone icon in the chat composer to start dictation. Speak a sentence, wait a few seconds, speak another sentence, then press the checkmark.
- **Expected**: The dictation stays open during pauses (because it uses manual endpointing), and the transcript only gets appended to the composer when you press the checkmark. No duplicate submission to the agent.
