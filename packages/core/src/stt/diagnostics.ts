/**
 * STT diagnostics: per-utterance records written by the macOS app and the
 * agent, a classifier that explains *why* an utterance probably missed, and a
 * report that aggregates those reasons.
 *
 * Records are only written when the user opts in (`stt.diagnostics`), because
 * they contain transcripts. They live in ~/.lofly/stt/diagnostics.jsonl.
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

export interface SttEngineResult {
  /** "apple" | "whisper" | provider id. */
  engine: string;
  locale?: string;
  text: string;
  confidence?: number | null;
  isFinal?: boolean;
  /** The engine did not deliver its final result before the timeout. */
  timedOut?: boolean;
  error?: string;
  latencyMs?: number;
  lowConfidenceWords?: string[];
  onDevice?: boolean;
}

export type UtteranceOutcome =
  | 'submitted'
  | 'dictation'
  | 'audio-fallback'
  | 'no-speech'
  | 'cancelled'
  | 'ptt-no-speech'
  | 'superseded';

/** Written by the macOS app once per utterance. */
export interface UtteranceDiagnostics {
  kind: 'utterance';
  sessionId: string;
  ts: number;
  endpointing: 'manual' | 'vad';
  finishReason: string;
  outcome: UtteranceOutcome;
  isDictation?: boolean;
  device?: string;
  inputSampleRate?: number;
  inputChannels?: number;

  /** Hotkey press → session start (includes the push-to-talk arm delay). */
  triggerToSessionMs?: number | null;
  /** Session start → first audio buffer from the microphone. */
  sessionToFirstBufferMs?: number | null;
  recordedMs?: number;
  speechMs?: number;
  vadStartMs?: number | null;
  vadEndMs?: number | null;
  /** Silence after the last voiced block when capture stopped. */
  trailingSilenceMs?: number | null;
  noiseFloorDb?: number;
  peakDb?: number;
  gainDb?: number;
  clippingPct?: number;
  /** Speech energy already present in the first ~100 ms of capture. */
  voicedAtStart?: boolean;
  /** The VAD still considered the signal speech when capture stopped. */
  voicedAtStop?: boolean;
  sttLatencyMs?: number;

  contextualStringsCount?: number;
  contextualSource?: 'agent' | 'fallback';
  cloudProvider?: string | null;

  /** Last partial shown live before the user stopped. */
  liveTranscriptAtStop?: string;
  engines: SttEngineResult[];
  finalEngine?: string | null;
  finalLocale?: string | null;
  finalText?: string;
  audioFile?: string | null;
}

/** Written by the agent for voice queries when the app asks for diagnostics. */
export interface OutcomeDiagnostics {
  kind: 'outcome';
  sessionId: string;
  ts: number;
  rawTranscript: string;
  normalizedTranscript: string;
  isValid: boolean;
  validationReason?: string;
  corrections: { from: string; to: string; reason: string }[];
  routeMatched?: boolean;
  routeDomain?: string;
  routeTools?: string[];
  error?: string;
}

export type SttDiagnosticsRecord = UtteranceDiagnostics | OutcomeDiagnostics;

export type MissReason =
  | 'start-clipped'
  | 'slow-capture-start'
  | 'end-clipped'
  | 'final-timeout'
  | 'quiet-speech-missed'
  | 'empty-transcript'
  | 'engine-error'
  | 'locale-disagreement'
  | 'low-confidence'
  | 'max-duration'
  | 'ended-mid-sentence'
  | 'live-final-mismatch'
  | 'validator-rejected'
  | 'router-miss'
  | 'heavy-normalization'
  | 'cancelled-with-speech';

export const MISS_REASON_DESCRIPTIONS: Record<MissReason, string> = {
  'start-clipped': 'Energi suara sudah ada saat capture mulai: suku kata pertama kemungkinan hilang',
  'slow-capture-start': 'Lebih dari 350 ms antara tekan hotkey dan buffer audio pertama',
  'end-clipped': 'Push-to-talk dilepas saat user masih bicara',
  'final-timeout': 'Engine tidak mengirim hasil final; hipotesis parsial yang dipakai',
  'quiet-speech-missed': 'Ada suara jelas di atas noise floor, tapi VAD tidak pernah mendeteksi speech',
  'empty-transcript': 'Speech terdeteksi tapi semua engine mengembalikan teks kosong',
  'engine-error': 'Engine STT gagal (network, 404, izin, …)',
  'locale-disagreement': 'id-ID dan en-US mendengar kalimat yang jauh berbeda',
  'low-confidence': 'Transcript terpilih punya confidence rata-rata < 0.6',
  'max-duration': 'Ucapan mencapai batas durasi maksimum',
  'ended-mid-sentence': 'Teks final diakhiri kata sambung: endpointing memotong user',
  'live-final-mismatch': 'Teks final jauh berbeda dari yang terlihat live',
  'validator-rejected': 'Validator agent menolak transcript',
  'router-miss': 'Fast router tidak match; perintah jatuh ke LLM',
  'heavy-normalization': 'Normalizer mengubah ≥ 2 bagian: output STT meleset',
  'cancelled-with-speech': 'Sesi dibatalkan/dibuang padahal audio berisi suara',
};

const CONNECTIVES = new Set([
  'terus', 'lalu', 'dan', 'habis', 'abis', 'kemudian', 'sama', 'ke', 'yang', 'untuk', 'buat',
  'di', 'dari', 'trus', 'tapi', 'atau', 'bilang', 'kalau', 'kalo', 'and', 'then', 'to', 'the',
  'or', 'but', 'with', 'for', 'a', 'an', 'of',
]);

export function tokenize(text: string): string[] {
  return (text || '')
    .toLowerCase()
    .normalize('NFKD')
    .replace(/[\u0300-\u036f]/g, '')
    .replace(/[^\p{L}\p{N}\s]/gu, ' ')
    .split(/\s+/)
    .filter(Boolean);
}

/** Word error rate of `hypothesis` against `reference` (Levenshtein over words). */
export function wordErrorRate(reference: string, hypothesis: string): number {
  const ref = tokenize(reference);
  const hyp = tokenize(hypothesis);
  if (ref.length === 0) return hyp.length === 0 ? 0 : 1;
  let prev = Array.from({ length: hyp.length + 1 }, (_, j) => j);
  for (let i = 1; i <= ref.length; i++) {
    const cur = [i];
    for (let j = 1; j <= hyp.length; j++) {
      const cost = ref[i - 1] === hyp[j - 1] ? 0 : 1;
      cur[j] = Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost);
    }
    prev = cur;
  }
  return prev[hyp.length] / ref.length;
}

/** Outcomes where nothing reached the agent although the user may have spoken. */
const DISCARDED_OUTCOMES: UtteranceOutcome[] = ['cancelled', 'ptt-no-speech', 'superseded'];

/** Explains why an utterance probably failed. Empty array = no detected problem. */
export function classifyUtterance(u: UtteranceDiagnostics, outcome?: OutcomeDiagnostics): MissReason[] {
  const reasons: MissReason[] = [];
  const nonEmpty = u.engines.filter((e) => e.text.trim().length > 0);
  const speechMs = u.speechMs ?? 0;
  const speechDetected = speechMs > 0 || nonEmpty.length > 0 || !!u.liveTranscriptAtStop?.trim();

  if (u.voicedAtStart) reasons.push('start-clipped');
  if (u.triggerToSessionMs != null) {
    const captureDelay = u.triggerToSessionMs + (u.sessionToFirstBufferMs ?? 0);
    if (captureDelay > 350) reasons.push('slow-capture-start');
  }
  if (u.endpointing === 'manual' && u.voicedAtStop) reasons.push('end-clipped');
  if (u.engines.some((e) => e.timedOut)) reasons.push('final-timeout');

  if ((u.outcome === 'no-speech' || u.outcome === 'ptt-no-speech') && speechMs === 0) {
    const headroom = (u.peakDb ?? -90) - (u.noiseFloorDb ?? -60);
    if (headroom >= 12) reasons.push('quiet-speech-missed');
  }
  if (speechMs > 0 && nonEmpty.length === 0 && u.outcome !== 'cancelled' && u.outcome !== 'superseded') {
    reasons.push('empty-transcript');
  }
  if (u.engines.some((e) => !!e.error)) reasons.push('engine-error');

  const apple = nonEmpty.filter((e) => e.engine === 'apple');
  if (apple.length >= 2 && wordErrorRate(apple[0].text, apple[1].text) >= 0.5) {
    reasons.push('locale-disagreement');
  }

  const final = u.engines.find(
    (e) => e.engine === u.finalEngine && (u.finalLocale == null || e.locale === u.finalLocale)
  );
  if (final?.confidence != null && final.confidence < 0.6) reasons.push('low-confidence');
  if (u.finishReason === 'max-duration') reasons.push('max-duration');

  const finalWords = tokenize(u.finalText ?? '');
  if (u.endpointing === 'vad' && finalWords.length > 0 && CONNECTIVES.has(finalWords[finalWords.length - 1])) {
    reasons.push('ended-mid-sentence');
  }
  if (u.liveTranscriptAtStop?.trim() && u.finalText?.trim() && wordErrorRate(u.finalText, u.liveTranscriptAtStop) >= 0.4) {
    reasons.push('live-final-mismatch');
  }
  if (DISCARDED_OUTCOMES.includes(u.outcome) && speechDetected) reasons.push('cancelled-with-speech');

  if (outcome) {
    if (!outcome.isValid) reasons.push('validator-rejected');
    if (outcome.isValid && outcome.routeMatched === false) reasons.push('router-miss');
    if (outcome.corrections.length >= 2) reasons.push('heavy-normalization');
  }
  return reasons;
}

function sorted(values: number[]): number[] {
  return values.filter((x) => Number.isFinite(x)).sort((a, b) => a - b);
}

function median(values: number[]): number | null {
  const v = sorted(values);
  if (v.length === 0) return null;
  const mid = Math.floor(v.length / 2);
  return v.length % 2 ? v[mid] : (v[mid - 1] + v[mid]) / 2;
}

function percentile(values: number[], p: number): number | null {
  const v = sorted(values);
  if (v.length === 0) return null;
  return v[Math.min(v.length - 1, Math.floor((p / 100) * v.length))];
}

export interface EngineStats {
  key: string;
  count: number;
  emptyCount: number;
  errorCount: number;
  timeoutCount: number;
  meanConfidence: number | null;
  chosenCount: number;
}

export interface SttReport {
  utterances: number;
  withProblem: number;
  outcomes: Record<string, number>;
  reasons: { reason: MissReason; count: number; pct: number; description: string }[];
  engines: EngineStats[];
  /** Median WER between the two Apple locales on the same audio. */
  localeAgreementWer: number | null;
  metrics: Record<string, { median: number | null; p90: number | null }>;
  examples: { sessionId: string; reasons: MissReason[]; finalText: string; engines: string[] }[];
}

const engineKey = (e: SttEngineResult) => `${e.engine}${e.locale ? `:${e.locale}` : ''}`;

export function buildSttReport(records: SttDiagnosticsRecord[], maxExamples = 15): SttReport {
  const utterances = records.filter((r): r is UtteranceDiagnostics => r.kind === 'utterance');
  const outcomes = new Map<string, OutcomeDiagnostics>();
  for (const r of records) if (r.kind === 'outcome') outcomes.set(r.sessionId, r);

  const reasonCounts = new Map<MissReason, number>();
  const outcomeCounts: Record<string, number> = {};
  const engineMap = new Map<string, EngineStats & { confSum: number; confN: number }>();
  const localeWers: number[] = [];
  const examples: SttReport['examples'] = [];
  let withProblem = 0;

  for (const u of utterances) {
    outcomeCounts[u.outcome] = (outcomeCounts[u.outcome] ?? 0) + 1;
    const reasons = classifyUtterance(u, outcomes.get(u.sessionId));
    if (reasons.length > 0) {
      withProblem++;
      if (examples.length < maxExamples) {
        examples.push({
          sessionId: u.sessionId,
          reasons,
          finalText: u.finalText ?? '',
          engines: u.engines.map((e) => `${engineKey(e)}="${e.text}"${e.error ? ` error=${e.error}` : ''}`),
        });
      }
    }
    for (const reason of reasons) reasonCounts.set(reason, (reasonCounts.get(reason) ?? 0) + 1);

    for (const e of u.engines) {
      const key = engineKey(e);
      const s = engineMap.get(key) ?? {
        key, count: 0, emptyCount: 0, errorCount: 0, timeoutCount: 0,
        meanConfidence: null, chosenCount: 0, confSum: 0, confN: 0,
      };
      s.count++;
      if (!e.text.trim()) s.emptyCount++;
      if (e.error) s.errorCount++;
      if (e.timedOut) s.timeoutCount++;
      if (e.confidence != null) { s.confSum += e.confidence; s.confN++; }
      if (e.engine === u.finalEngine && (u.finalLocale == null || e.locale === u.finalLocale)) s.chosenCount++;
      engineMap.set(key, s);
    }

    const apple = u.engines.filter((e) => e.engine === 'apple' && e.text.trim());
    if (apple.length >= 2) localeWers.push(wordErrorRate(apple[0].text, apple[1].text));
  }

  const n = utterances.length;
  const pick = (f: (u: UtteranceDiagnostics) => number | null | undefined) =>
    utterances.map(f).filter((x): x is number => typeof x === 'number');
  const metric = (values: number[]) => ({ median: median(values), p90: percentile(values, 90) });

  return {
    utterances: n,
    withProblem,
    outcomes: outcomeCounts,
    reasons: [...reasonCounts.entries()]
      .sort((a, b) => b[1] - a[1])
      .map(([reason, count]) => ({
        reason, count, pct: n ? (count / n) * 100 : 0, description: MISS_REASON_DESCRIPTIONS[reason],
      })),
    engines: [...engineMap.values()].map(({ confSum, confN, ...s }) => ({
      ...s, meanConfidence: confN ? confSum / confN : null,
    })),
    localeAgreementWer: median(localeWers),
    metrics: {
      triggerToSessionMs: metric(pick((u) => u.triggerToSessionMs)),
      sessionToFirstBufferMs: metric(pick((u) => u.sessionToFirstBufferMs)),
      recordedMs: metric(pick((u) => u.recordedMs)),
      speechMs: metric(pick((u) => u.speechMs)),
      trailingSilenceMs: metric(pick((u) => u.trailingSilenceMs)),
      sttLatencyMs: metric(pick((u) => u.sttLatencyMs)),
      noiseFloorDb: metric(pick((u) => u.noiseFloorDb)),
      peakDb: metric(pick((u) => u.peakDb)),
    },
    examples,
  };
}

export function formatSttReport(report: SttReport): string {
  const lines: string[] = [];
  const fmt = (v: number | null) => (v == null ? '-' : String(Math.round(v * 10) / 10));
  lines.push('# Laporan STT: kenapa miss', '');
  lines.push(`Ucapan: ${report.utterances}, dengan masalah terdeteksi: ${report.withProblem}`);
  const outcomeLine = Object.entries(report.outcomes).map(([k, v]) => `${k}=${v}`).join(', ');
  lines.push(`Outcome: ${outcomeLine || '-'}`, '');
  lines.push('## Penyebab (bisa lebih dari satu per ucapan)', '');
  if (report.reasons.length === 0) lines.push('Tidak ada masalah terdeteksi.');
  for (const r of report.reasons) {
    lines.push(`- ${r.reason}: ${r.count} (${r.pct.toFixed(1)}%) — ${r.description}`);
  }
  lines.push('', '## Engine', '');
  for (const e of report.engines) {
    const conf = e.meanConfidence == null ? 'n/a' : e.meanConfidence.toFixed(2);
    lines.push(
      `- ${e.key}: n=${e.count} dipilih=${e.chosenCount} kosong=${e.emptyCount} ` +
        `error=${e.errorCount} timeout=${e.timeoutCount} conf=${conf}`
    );
  }
  lines.push(`- median WER antar-locale Apple: ${fmt(report.localeAgreementWer)}`, '');
  lines.push('## Metrik (median / p90)', '');
  for (const [k, v] of Object.entries(report.metrics)) lines.push(`- ${k}: ${fmt(v.median)} / ${fmt(v.p90)}`);
  if (report.examples.length > 0) {
    lines.push('', '## Contoh', '');
    for (const ex of report.examples) {
      lines.push(`- ${ex.sessionId.slice(0, 8)} [${ex.reasons.join(', ')}] final="${ex.finalText}"`);
      for (const e of ex.engines) lines.push(`    ${e}`);
    }
  }
  return lines.join('\n');
}

export function defaultSttDiagnosticsPath(): string {
  return path.join(os.homedir(), '.lofly', 'stt', 'diagnostics.jsonl');
}

/** Append-only JSONL store, readable only by the current user. */
export class SttDiagnosticsStore {
  constructor(public readonly filePath: string = defaultSttDiagnosticsPath()) {}

  append(record: SttDiagnosticsRecord): void {
    fs.mkdirSync(path.dirname(this.filePath), { recursive: true, mode: 0o700 });
    fs.appendFileSync(this.filePath, `${JSON.stringify(record)}\n`, { mode: 0o600 });
  }

  readAll(): SttDiagnosticsRecord[] {
    if (!fs.existsSync(this.filePath)) return [];
    const out: SttDiagnosticsRecord[] = [];
    for (const line of fs.readFileSync(this.filePath, 'utf-8').split('\n')) {
      if (!line.trim()) continue;
      try {
        const parsed = JSON.parse(line) as SttDiagnosticsRecord;
        if (parsed && (parsed.kind === 'utterance' || parsed.kind === 'outcome')) out.push(parsed);
      } catch {
        // A truncated last line (crash mid-write) must not break the report.
      }
    }
    return out;
  }
}

/** Validates an utterance record posted by the app. Returns null when unusable. */
export function parseUtteranceDiagnostics(body: unknown): UtteranceDiagnostics | null {
  if (!body || typeof body !== 'object') return null;
  const b = body as Record<string, unknown>;
  if (typeof b.sessionId !== 'string' || !b.sessionId.trim()) return null;
  if (!Array.isArray(b.engines)) return null;
  for (const e of b.engines) {
    if (!e || typeof e !== 'object') return null;
    const er = e as Record<string, unknown>;
    if (typeof er.engine !== 'string' || typeof er.text !== 'string') return null;
  }
  return {
    ...(b as unknown as UtteranceDiagnostics),
    kind: 'utterance',
    ts: typeof b.ts === 'number' ? b.ts : Date.now(),
    endpointing: b.endpointing === 'manual' ? 'manual' : 'vad',
    finishReason: typeof b.finishReason === 'string' ? b.finishReason : 'unknown',
    outcome: (typeof b.outcome === 'string' ? b.outcome : 'submitted') as UtteranceOutcome,
    engines: b.engines as SttEngineResult[],
  };
}
