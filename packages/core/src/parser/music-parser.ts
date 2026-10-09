import type { StructuredActionIntent } from '@lofly/types';

export interface MusicIntent {
  action: 'play' | 'pause' | 'resume' | 'skip' | 'previous' | 'search';
  title?: string;
  artist?: string;
  album?: string;
  query?: string;
}

/**
 * Extracts structured music fields from a natural language query.
 * Handles patterns like "Title dari Artist", "Title oleh Artist", "Title - Artist".
 */
export function extractMusicIntent(query: string, defaultAction: MusicIntent['action'] = 'play'): MusicIntent {
  let cleaned = query.trim();

  // Normalize common STT errors and spacings
  cleaned = cleaned.replace(/\s+/g, ' ');

  // Look for separators indicating "Title - Artist" or "Title by Artist"
  const separatorRegex = /\s+(dari|oleh|by|[-—])\s+/i;
  const match = cleaned.match(separatorRegex);

  if (match) {
    const titlePart = cleaned.slice(0, match.index).trim();
    let artistPart = cleaned.slice(match.index! + match[0].length).trim();

    // Handle STT misspellings like "Sabrina carpenther"
    artistPart = normalizeArtistName(artistPart);

    return {
      action: defaultAction,
      title: titlePart,
      artist: artistPart,
    };
  }

  // Handle cases where the separator is missing, e.g., "play Creep radiohead"
  // This is hard to deterministically split without a catalog.
  // We'll leave it as query if we can't safely split.
  
  // Also handle "play lagu Sabrina Carpenter" -> this is an artist search.
  // But since we can't definitively know without an API, we leave it as query
  // unless we apply some heuristics.
  
  return {
    action: defaultAction,
    query: cleaned,
  };
}

export function normalizeArtistName(raw: string): string {
  const lower = raw.toLowerCase();
  
  // Common STT misspellings mapping
  const mappings: Record<string, string> = {
    'sabrina carpenther': 'Sabrina Carpenter',
    'sabrina carpentter': 'Sabrina Carpenter',
    'radio hed': 'Radiohead',
    'the weekend': 'The Weeknd',
  };

  if (mappings[lower]) {
    return mappings[lower];
  }

  // Basic cleanup
  return raw;
}

export function normalizeSongTitle(raw: string): string {
  const lower = raw.toLowerCase();
  
  const mappings: Record<string, string> = {
    'man child': 'Manchild',
    'blinding lite': 'Blinding Lights',
  };

  if (mappings[lower]) {
    return mappings[lower];
  }

  return raw;
}
