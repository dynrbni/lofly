import type { ToolCallRequest } from '@lofly/types';
import { parseCommand } from '../parser/command-parser.js';
import { validateWhatsAppIntent } from '../parser/validator.js';
import { extractMusicIntent } from '../parser/music-parser.js';

/**
 * Fast Command Router — deterministic routing that bypasses the LLM entirely
 * for simple, unambiguous voice commands. Returns tool calls directly without
 * any LLM reasoning when the intent is crystal clear.
 *
 * This is the single biggest latency win: eliminates the LLM round trip
 * (~1-3 seconds) for commands like "Open Spotify", "Set volume to 50",
 * or "WhatsApp Reja Agung terus bilang Yuli bubur".
 */

export interface FastRouteResult {
  /** Whether the router found a deterministic match */
  matched: boolean;
  /** Direct tool calls to execute (no LLM needed) */
  toolCalls?: ToolCallRequest[];
  /** Short confirmation text for the UI */
  confirmText?: string;
  /** Whether the tool calls can be executed concurrently in parallel */
  isParallel?: boolean;
  /** Restrict LLM to a specific tool domain if not fully matched */
  toolDomain?: string;
  /** Clarification question if required (e.g. missing message) */
  clarificationText?: string;
}

// ─────────────────────────────────────────────────────────────────────────────
// Pattern definitions for deterministic routing
// ─────────────────────────────────────────────────────────────────────────────

const OPEN_APP_PATTERNS = [
  /^(?:coba\s+|tolong\s+|please\s+)?(?:buka|open|launch|jalankan|run)\s+(?:aplikasi\s+|app\s+)?(.+?)(?:\s+dong|\s+ya|\s+deh|\s+please)?\.?$/i,
];

const CLOSE_APP_PATTERNS = [
  /^(?:coba\s+|tolong\s+|please\s+)?(?:tutup|close|quit|exit|kill)\s+(?:aplikasi\s+|app\s+)?(.+?)(?:\s+dong|\s+ya|\s+deh|\s+please)?\.?$/i,
];

const VOLUME_PATTERNS = [
  // "Set volume to 50", "Volume ke 50", "Set volume 40", "Volume 80%"
  /^(?:set\s+)?volume(?:\s+ke|\s+to|\s+jadi)?\s+(\d+)(?:\s*%)?\.?$/i,
  // "Kecilin volume", "Turunin volume", "Volume down", "Kecilkan suara", "Turunkan suara"
  /^(?:kecilin|turunin|kecilkan|turunkan|kurangin|kurangkan|turn\s+down|lower|decrease)\s+(?:the\s+)?(?:volume|suara|audio)\.?$/i,
  // "Besarin volume", "Naikin volume", "Volume up", "Besarkan suara", "Naikkan suara"
  /^(?:besarin|naikin|besarkan|naikkan|tambahin|tambahkan|turn\s+up|raise|increase)\s+(?:the\s+)?(?:volume|suara|audio)\.?$/i,
  // "Mute", "Matikan suara"
  /^(?:mute|matikan\s+suara|diam(?:in)?\s+suara)\.?$/i,
  // "Unmute", "Nyalakan suara"
  /^(?:unmute|nyalakan\s+suara|aktifkan\s+suara)\.?$/i,
];

const PLAY_MUSIC_PATTERNS = [
  /^(?:coba\s+|tolong\s+|please\s+)?(?:putar|puter|setel|play|mainkan|nyalakan)\s+(?:lagu\s+|musik\s+|music\s+|song\s+)?(.+?)(?:\s+di\s+(?:spotify|apple\s+music))?(?:\s+dong|\s+ya|\s+deh)?\.?$/i,
];

const MEDIA_CONTROL_PATTERNS = [
  /^(?:coba\s+|tolong\s+|please\s+)?(?:pause|berhentikan|jeda|stop)(?:\s+(?:lagu|musik|music|song))?\.?$/i,
  /^(?:coba\s+|tolong\s+|please\s+)?(?:resume|lanjut|lanjutkan)(?:\s+(?:lagu|musik|music|song))?\.?$/i,
  /^(?:coba\s+|tolong\s+|please\s+)?(?:skip|next|berikutnya|selanjutnya)(?:\s+(?:lagu|musik|music|song))?\.?$/i,
  /^(?:coba\s+|tolong\s+|please\s+)?(?:previous|sebelumnya|kembali|prev)(?:\s+(?:lagu|musik|music|song))?\.?$/i,
];

const SCREENSHOT_PATTERNS = [
  /^(?:ambil\s+)?(?:screenshot|screen\s*shot|tangkap\s+layar|ss)(?:\s+layar)?\.?$/i,
];

const FIND_FILE_PATTERNS = [
  /^(?:cari|find|search)\s+(?:file\s+|berkas\s+)(.+?)\.?$/i,
];

const OPEN_URL_PATTERNS = [
  /^(?:buka|open)\s+(https?:\/\/\S+)\.?$/i,
];

const WEB_SEARCH_PATTERNS = [
  /^(?:cari|search|google|googling)\s+(?:di\s+(?:google|web|internet)\s+)?(.+?)(?:\s+di\s+(?:google|web|internet))?\.?$/i,
];

// ─────────────────────────────────────────────────────────────────────────────
// Tool domain classification for LLM tool filtering
// ─────────────────────────────────────────────────────────────────────────────

const DOMAIN_KEYWORDS: Record<string, string[]> = {
  apps: ['buka', 'open', 'tutup', 'close', 'launch', 'quit', 'exit', 'jalankan', 'run', 'fokus', 'focus'],
  music: ['putar', 'play', 'lagu', 'musik', 'music', 'song', 'playlist', 'spotify', 'apple music'],
  volume: ['volume', 'suara', 'audio', 'mute', 'unmute', 'kecilin', 'besarin', 'turunin', 'naikin'],
  whatsapp: ['whatsapp', 'wa', 'chat', 'message', 'kirim pesan', 'bilang'],
  web: ['browse', 'search', 'cari', 'google', 'url', 'website', 'web', 'buka http', 'open http'],
  filesystem: ['file', 'folder', 'directory', 'rename', 'hapus', 'delete', 'copy', 'move', 'buat folder'],
  screen: ['screenshot', 'screen', 'layar', 'tangkap'],
  document: ['word', 'document', 'dokumen', 'tulis', 'write', 'research'],
  keyboard: ['ketik', 'type', 'tekan', 'press', 'shortcut', 'hotkey'],
  mouse: ['klik', 'click', 'drag', 'scroll'],
};

const DOMAIN_TOOLS: Record<string, string[]> = {
  apps: ['open_app', 'close_app', 'focus_app', 'is_app_running'],
  music: ['play_music', 'search_music', 'open_app'],
  volume: ['set_volume'],
  whatsapp: ['open_whatsapp', 'search_whatsapp_contact', 'open_whatsapp_chat', 'send_whatsapp_message'],
  web: ['open_url', 'web_search', 'read_web_page', 'open_app'],
  filesystem: ['read_file', 'write_file', 'find_file', 'list_directory', 'create_directory', 'copy_file', 'move_file', 'delete_file'],
  screen: ['screenshot', 'screenshot_app', 'inspect_ui'],
  document: ['write_word_document', 'web_search', 'read_web_page', 'open_app'],
  keyboard: ['type_text', 'press_key', 'hotkey'],
  mouse: ['click', 'double_click', 'right_click', 'move_mouse', 'drag', 'scroll'],
};

// ─────────────────────────────────────────────────────────────────────────────
// Main Router
// ─────────────────────────────────────────────────────────────────────────────

export function fastRoute(transcript: string): FastRouteResult {
  const input = (transcript || '').trim();
  if (!input) return { matched: false };

  const lower = input.toLowerCase();

  // ── 1. WhatsApp Deterministic Parser (Section 4) ──
  // Check WhatsApp intent FIRST to preserve verbatim message & avoid any LLM overhead
  const parsedWa = parseCommand(input);
  if (parsedWa.isStructured && parsedWa.primaryIntent) {
    if (parsedWa.primaryIntent.intent === 'send_whatsapp_message') {
      // If dynamic research or generation is requested (e.g. Google search summary, draft a message),
      // DO NOT fast-route: forward to LLM agent to search, synthesize, and compose!
      if (parsedWa.primaryIntent.isDynamicGeneration) {
        return { matched: false };
      }

      const validation = validateWhatsAppIntent(parsedWa.primaryIntent);
      if (validation.valid && parsedWa.primaryIntent.recipient && parsedWa.primaryIntent.message) {
        const calls: ToolCallRequest[] = [
          {
            id: `fast_wa_${Date.now()}`,
            name: 'send_whatsapp_message',
            parameters: {
              recipient: parsedWa.primaryIntent.recipient,
              message: parsedWa.primaryIntent.message,
            },
          },
        ];

        // Check if there are subsequent actions (e.g. "terus buka Spotify")
        if (parsedWa.actions && parsedWa.actions.length > 1) {
          for (let i = 1; i < parsedWa.actions.length; i++) {
            const sub = parsedWa.actions[i];
            if (sub.intent === 'open_app' && sub.app) {
              calls.push({
                id: `fast_sub_${Date.now()}_${i}`,
                name: 'open_app',
                parameters: { appName: normalizeAppName(sub.app) },
              });
            } else if (sub.intent === 'play_music' && sub.query) {
              const intent = extractMusicIntent(sub.query, 'play');
              const params: any = { app: 'auto' };
              if (intent.title) params.title = intent.title;
              if (intent.artist) params.artist = intent.artist;
              if (intent.query) params.query = intent.query;
              
              calls.push({
                id: `fast_sub_${Date.now()}_${i}`,
                name: 'play_music',
                parameters: params,
              });
            }
          }
        }

        return {
          matched: true,
          toolCalls: calls,
          confirmText: `✓ Sending WhatsApp to ${parsedWa.primaryIntent.recipient}: "${parsedWa.primaryIntent.message}"`,
        };
      } else if (!validation.valid && validation.reason === 'message_missing') {
        return {
          matched: true,
          toolCalls: [],
          clarificationText: parsedWa.primaryIntent.recipient
            ? `Mau kirim pesan apa ke ${parsedWa.primaryIntent.recipient}?`
            : 'Penerima pesan belum disebutkan. Mau kirim pesan apa?',
        };
      }
    } else if (parsedWa.primaryIntent.intent === 'open_whatsapp_chat' && parsedWa.primaryIntent.recipient) {
      // Guard: recipient of open_whatsapp_chat MUST be a plausible contact name (1-3 words, no conversational sentences)
      const recipient = parsedWa.primaryIntent.recipient.trim();
      const words = recipient.split(/\s+/);
      const invalidContactWords = /\b(?:tentang|soal|buat|google|ringkas|pesan|rokok|makan|nanti|besok|tahu|kasih|suruh|ambil)\b/i;

      if (words.length > 3 || invalidContactWords.test(recipient)) {
        // Not a plausible standalone contact name, let LLM agent handle it
        return { matched: false };
      }

      return {
        matched: true,
        toolCalls: [
          {
            id: `fast_wa_${Date.now()}`,
            name: 'open_whatsapp_chat',
            parameters: {
              contact: recipient,
            },
          },
        ],
        confirmText: `✓ Opening WhatsApp chat with ${recipient}`,
      };
    }
  }

  // ── 2. Multi-Action Commands (Section 12 & 27) ──
  // Check for multi-action commands separated by conjunctions (e.g. "Open Spotify terus buka Safari")
  const multiSplit = input.split(/\s+(?:terus|trus|lalu|habis\s+itu|kemudian|and\s+then|and|dan|sekalian)\s+/i);
  if (multiSplit.length > 1) {
    const multiCalls: ToolCallRequest[] = [];
    let allMatched = true;

    for (let i = 0; i < multiSplit.length; i++) {
      const part = multiSplit[i].trim();
      const singleMatch = matchSingleDeterministicCommand(part, i);
      if (singleMatch && singleMatch.toolCalls && singleMatch.toolCalls.length > 0) {
        multiCalls.push(...singleMatch.toolCalls);
      } else {
        allMatched = false;
        break;
      }
    }

    if (allMatched && multiCalls.length > 0) {
      // Independent actions (e.g. open Spotify + open Safari) can run concurrently!
      const isParallel = multiCalls.every((c) => c.name === 'open_app' || c.name === 'close_app');
      return {
        matched: true,
        toolCalls: multiCalls,
        isParallel,
        confirmText: `✓ Executing ${multiCalls.length} actions`,
      };
    }
  }

  // ── 3. Single Deterministic Command ──
  const single = matchSingleDeterministicCommand(input, 0);
  if (single) {
    return single;
  }

  // ── 4. Fallback: Classify Tool Domain for LLM Filtering ──
  const domain = classifyDomain(lower);
  return { matched: false, toolDomain: domain || undefined };
}

/**
 * A captured "app name" is only trustworthy when it is actually a short noun
 * phrase. Without this guard the open/close patterns swallow whole sentences —
 * "jalankan command pwd di terminal dan tampilkan hasilnya" would otherwise be
 * routed to open_app with an app name that is an entire clause.
 */
function looksLikeAppName(target: string): boolean {
  const cleaned = target.trim();
  if (cleaned.length < 2) return false;
  if (cleaned.includes('http')) return false;
  if (cleaned.startsWith('di ')) return false;

  // Multi-action sentences must reach the multi-action splitter or the LLM.
  if (/[,;]/.test(cleaned)) return false;
  if (/\b(terus|trus|lalu|habis\s+itu|kemudian|sekalian|and\s+then|then|dan|comma)\b/i.test(cleaned)) {
    return false;
  }

  // App names are short. Anything longer is a sentence the LLM should parse.
  const words = cleaned.split(/\s+/).filter(Boolean);
  return words.length <= 4;
}

/**
 * Match a single command to a deterministic tool call
 */
function matchSingleDeterministicCommand(input: string, indexOffset: number = 0): FastRouteResult | null {
  // ── A. Open App ──
  for (const pattern of OPEN_APP_PATTERNS) {
    const m = input.match(pattern);
    if (m && looksLikeAppName(m[1])) {
      const appName = normalizeAppName(m[1].trim());
      return {
        matched: true,
        toolCalls: [{ id: `fast_open_${Date.now()}_${indexOffset}`, name: 'open_app', parameters: { appName } }],
        confirmText: `✓ Opening ${appName}`,
      };
    }
  }

  // ── B. Close App ──
  for (const pattern of CLOSE_APP_PATTERNS) {
    const m = input.match(pattern);
    if (m && looksLikeAppName(m[1])) {
      const appName = normalizeAppName(m[1].trim());
      return {
        matched: true,
        toolCalls: [{ id: `fast_close_${Date.now()}_${indexOffset}`, name: 'close_app', parameters: { appName } }],
        confirmText: `✓ Closing ${appName}`,
      };
    }
  }

  // ── C. Volume Control ──
  {
    const setMatch = input.match(VOLUME_PATTERNS[0]);
    if (setMatch) {
      const level = parseInt(setMatch[1], 10);
      return {
        matched: true,
        toolCalls: [{ id: `fast_vol_${Date.now()}_${indexOffset}`, name: 'set_volume', parameters: { action: 'set', level } }],
        confirmText: `✓ Volume → ${level}%`,
      };
    }
    if (VOLUME_PATTERNS[1].test(input)) {
      return {
        matched: true,
        toolCalls: [{ id: `fast_vol_${Date.now()}_${indexOffset}`, name: 'set_volume', parameters: { action: 'down', step: 15 } }],
        confirmText: '✓ Volume down',
      };
    }
    if (VOLUME_PATTERNS[2].test(input)) {
      return {
        matched: true,
        toolCalls: [{ id: `fast_vol_${Date.now()}_${indexOffset}`, name: 'set_volume', parameters: { action: 'up', step: 15 } }],
        confirmText: '✓ Volume up',
      };
    }
    if (VOLUME_PATTERNS[3].test(input)) {
      return {
        matched: true,
        toolCalls: [{ id: `fast_vol_${Date.now()}_${indexOffset}`, name: 'set_volume', parameters: { action: 'mute' } }],
        confirmText: '✓ Muted',
      };
    }
    if (VOLUME_PATTERNS[4].test(input)) {
      return {
        matched: true,
        toolCalls: [{ id: `fast_vol_${Date.now()}_${indexOffset}`, name: 'set_volume', parameters: { action: 'unmute' } }],
        confirmText: '✓ Unmuted',
      };
    }
  }

  // ── D. Play Music ──
  for (const pattern of PLAY_MUSIC_PATTERNS) {
    const m = input.match(pattern);
    if (m) {
      const rawQuery = m[1].trim();
      if (rawQuery.length >= 2) {
        console.log(`\n========================================`);
        console.log(`[MUSIC_INPUT]`);
        console.log(`"${rawQuery}"`);
        const intent = extractMusicIntent(rawQuery, 'play');
        console.log(`[MUSIC_TOOL_INPUT]`);
        console.log(`title = ${intent.title || 'none'}\nartist = ${intent.artist || 'none'}\nquery = ${intent.query || rawQuery}`);
        console.log(`========================================\n`);

        const params: any = { app: 'auto' };
        if (intent.title) params.title = intent.title;
        if (intent.artist) params.artist = intent.artist;
        if (intent.query) params.query = intent.query;

        const confirmText = intent.title && intent.artist ? `✓ Playing ${intent.title} — ${intent.artist}` 
                          : intent.title ? `✓ Playing ${intent.title}`
                          : `✓ Playing ${rawQuery}`;

        return {
          matched: true,
          toolCalls: [{ id: `fast_music_${Date.now()}_${indexOffset}`, name: 'play_music', parameters: params }],
          confirmText,
        };
      }
    }
  }

  // ── DD. Media Controls ──
  if (MEDIA_CONTROL_PATTERNS[0].test(input)) {
    return {
      matched: true,
      toolCalls: [{ id: `fast_mc_${Date.now()}_${indexOffset}`, name: 'play_music', parameters: { action: 'pause' } }],
      confirmText: '✓ Pausing music',
    };
  }
  if (MEDIA_CONTROL_PATTERNS[1].test(input)) {
    return {
      matched: true,
      toolCalls: [{ id: `fast_mc_${Date.now()}_${indexOffset}`, name: 'play_music', parameters: { action: 'resume' } }],
      confirmText: '✓ Resuming music',
    };
  }
  if (MEDIA_CONTROL_PATTERNS[2].test(input)) {
    return {
      matched: true,
      toolCalls: [{ id: `fast_mc_${Date.now()}_${indexOffset}`, name: 'play_music', parameters: { action: 'skip' } }],
      confirmText: '✓ Skipping track',
    };
  }
  if (MEDIA_CONTROL_PATTERNS[3].test(input)) {
    return {
      matched: true,
      toolCalls: [{ id: `fast_mc_${Date.now()}_${indexOffset}`, name: 'play_music', parameters: { action: 'previous' } }],
      confirmText: '✓ Previous track',
    };
  }

  // ── E. Screenshot ──
  if (SCREENSHOT_PATTERNS.some((p) => p.test(input))) {
    return {
      matched: true,
      toolCalls: [{ id: `fast_ss_${Date.now()}_${indexOffset}`, name: 'screenshot', parameters: {} }],
      confirmText: '✓ Screenshot taken',
    };
  }

  // ── F. Find File ──
  for (const pattern of FIND_FILE_PATTERNS) {
    const m = input.match(pattern);
    if (m) {
      const query = m[1].trim();
      return {
        matched: true,
        toolCalls: [{ id: `fast_find_${Date.now()}_${indexOffset}`, name: 'find_file', parameters: { query } }],
        confirmText: `✓ Finding file "${query}"`,
      };
    }
  }

  // ── G. Open URL ──
  for (const pattern of OPEN_URL_PATTERNS) {
    const m = input.match(pattern);
    if (m) {
      return {
        matched: true,
        toolCalls: [{ id: `fast_url_${Date.now()}_${indexOffset}`, name: 'open_url', parameters: { url: m[1] } }],
        confirmText: '✓ Opening URL',
      };
    }
  }

  // ── H. Web Search ──
  for (const pattern of WEB_SEARCH_PATTERNS) {
    const m = input.match(pattern);
    if (m) {
      const query = m[1].trim();
      if (query.length >= 2) {
        return {
          matched: true,
          toolCalls: [{ id: `fast_search_${Date.now()}_${indexOffset}`, name: 'web_search', parameters: { query } }],
          confirmText: `✓ Searching web for "${query}"`,
        };
      }
    }
  }

  return null;
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

/** Normalize common app name variations from speech recognition */
export function normalizeAppName(raw: string): string {
  const map: Record<string, string> = {
    'vs code': 'Visual Studio Code',
    'vscode': 'Visual Studio Code',
    'chrome': 'Google Chrome',
    'google chrome': 'Google Chrome',
    'word': 'Microsoft Word',
    'microsoft word': 'Microsoft Word',
    'excel': 'Microsoft Excel',
    'powerpoint': 'Microsoft PowerPoint',
    'terminal': 'Terminal',
    'finder': 'Finder',
    'music': 'Music',
    'apple music': 'Music',
    'capcut': 'CapCut',
    'discord': 'Discord',
    'telegram': 'Telegram',
    'whatsapp': 'WhatsApp',
    'safari': 'Safari',
    'spotify': 'Spotify',
    'notes': 'Notes',
    'messages': 'Messages',
    'slack': 'Slack',
    'zoom': 'zoom.us',
    'calculator': 'Calculator',
    'settings': 'System Settings',
    'system settings': 'System Settings',
    'preferences': 'System Settings',
    'mail': 'Mail',
    'calendar': 'Calendar',
    'reminders': 'Reminders',
    'preview': 'Preview',
    'photos': 'Photos',
  };

  const key = raw.toLowerCase().replace(/\s+/g, ' ').trim();
  return map[key] || raw;
}

/** Classify which tool domain a command belongs to */
export function classifyDomain(lower: string): string | null {
  let bestDomain: string | null = null;
  let bestScore = 0;

  for (const [domain, keywords] of Object.entries(DOMAIN_KEYWORDS)) {
    let score = 0;
    for (const kw of keywords) {
      if (lower.includes(kw)) {
        score += kw.length; // longer keyword = more specific match
      }
    }
    if (score > bestScore) {
      bestScore = score;
      bestDomain = domain;
    }
  }

  return bestDomain;
}

/** Get relevant tool names for a domain */
export function getToolsForDomain(domain: string | undefined): string[] | undefined {
  if (!domain) return undefined;
  const tools = DOMAIN_TOOLS[domain];
  if (!tools) return undefined;
  // Always include basic tools that any domain might need
  const base = ['wait', 'wait_for_app'];
  return [...new Set([...tools, ...base])];
}

/**
 * Dynamically determine the required reasoning level based on prompt complexity.
 * Implements Section 2 of the speed specification.
 */
export function determineReasoningLevel(query: string): 'low' | 'medium' | 'high' {
  const lower = query.toLowerCase();

  // High reasoning: multi-step file manipulation, code modifications, visual debugging, research & write
  const highKeywords = [
    'research',
    'riset',
    'kesimpulan',
    'analisis',
    'analyze',
    'organize the folder',
    'rapikan folder',
    'edit project',
    'fix the problem',
    'perbaiki masalah',
    'lihat layar',
    'inspect',
  ];
  if (highKeywords.some((k) => lower.includes(k))) {
    return 'high';
  }

  // Medium reasoning: multi-step commands connected by then/terus that need planning
  if (/\b(?:terus|lalu|habis\s+itu|kemudian|and\s+then|then)\b/i.test(lower)) {
    return 'medium';
  }

  // Default to LOW for everything else (Section 2)
  return 'low';
}

/**
 * Get the target 9Router model for a given reasoning level.
 */
export function getModelForReasoningLevel(level: 'low' | 'medium' | 'high', defaultModel?: string): string {
  if (level === 'low') {
    return 'ag/gemini-3.8-flash-low';
  }
  if (level === 'medium') {
    return 'ag/gemini-3.8-flash';
  }
  return defaultModel || 'ag/gemini-3.8-flash-high';
}
