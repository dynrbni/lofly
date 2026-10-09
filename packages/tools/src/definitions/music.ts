import { execFile, execFileSync } from 'child_process';
import { promisify } from 'util';
import fs from 'fs';
import type { ToolDefinition, ToolExecutionContext, ToolResult } from '@lofly/types';
import { toolSafety } from '../safety/policy.js';

const execFileAsync = promisify(execFile);

export interface PlayMusicParams {
  action?: 'play' | 'pause' | 'resume' | 'skip' | 'previous' | 'search';
  title?: string;
  artist?: string;
  query?: string;
  app?: 'auto' | 'music' | 'spotify';
}

export interface PlayMusicResultData {
  app: string;
  query: string;
  trackName?: string;
  artistName?: string;
  action: 'playing_library' | 'playing_catalog' | 'catalog_search' | 'spotify_app' | 'spotify_web' | 'media_control';
  message: string;
}

/**
 * Checks whether Spotify application is installed on this Mac.
 */
async function isSpotifyInstalled(): Promise<boolean> {
  const commonPaths = [
    '/Applications/Spotify.app',
    `${process.env.HOME}/Applications/Spotify.app`,
  ];
  for (const p of commonPaths) {
    if (fs.existsSync(p)) return true;
  }

  try {
    const { stdout } = await execFileAsync('mdfind', [
      "kMDItemCFBundleIdentifier == 'com.spotify.client'",
    ]);
    return stdout.trim().length > 0;
  } catch {
    return false;
  }
}

/**
 * Searches Apple Music catalog via official iTunes Search API.
 */
async function searchAppleMusicCatalog(params: PlayMusicParams): Promise<{ trackName: string; artistName: string; trackUrl: string } | null> {
  const { title, artist, query } = params;
  let term = '';
  
  if (title && artist) {
    term = `${title} ${artist}`;
  } else if (title) {
    term = title;
  } else if (query) {
    term = query;
  } else if (artist) {
    term = artist;
  }

  if (!term) return null;

  try {
    const apiUrl = `https://itunes.apple.com/search?term=${encodeURIComponent(term)}&entity=song&limit=10`;
    const res = await fetch(apiUrl, { signal: AbortSignal.timeout(3000) });
    if (!res.ok) return null;
    const data = await res.json() as { results?: Array<{ trackName?: string; artistName?: string; trackViewUrl?: string }> };
    
    if (!data.results || data.results.length === 0) return null;

    // Rank results
    const { rankMusicResults } = await import('./music-helpers.js');
    const ranked = rankMusicResults(data.results, title, artist, query);
    const first = ranked[0];

    if (first && first.trackViewUrl) {
      // If we asked for a specific artist, ensure the result matches reasonably well,
      // otherwise we might have fetched a completely wrong song.
      if (artist) {
        // rankMusicResults ensures higher score for matching artist
        if (first._score < 5) { // Arbitrary threshold, meaning neither title nor artist matched well
          return null; // Don't silently play unrelated track
        }
      }

      return {
        trackName: first.trackName || term,
        artistName: first.artistName || '',
        trackUrl: first.trackViewUrl,
      };
    }
  } catch {}
  
  // Fallback to query only if strict search failed
  if (title && artist) {
    try {
      const fallbackTerm = term;
      const apiUrl = `https://itunes.apple.com/search?term=${encodeURIComponent(fallbackTerm)}&entity=song&limit=5`;
      const res = await fetch(apiUrl, { signal: AbortSignal.timeout(3000) });
      if (res.ok) {
        const data = await res.json() as { results?: Array<{ trackName?: string; artistName?: string; trackViewUrl?: string }> };
        if (data.results && data.results.length > 0) {
           const first = data.results[0];
           if (first && first.trackViewUrl) {
             return {
               trackName: first.trackName || term,
               artistName: first.artistName || '',
               trackUrl: first.trackViewUrl,
             };
           }
        }
      }
    } catch {}
  }
  
  return null;
}

export const playMusicTool: ToolDefinition<PlayMusicParams, PlayMusicResultData> = {
  name: 'play_music',
  description:
    'Searches and plays a song, artist, album, or playlist in Apple Music or Spotify on macOS.',
  permissionLevel: 'SAFE',
  safety: toolSafety('reversible', { supportsSandbox: true }),
  parameters: {
    type: 'object',
    properties: {
      action: {
        type: 'string',
        enum: ['play', 'pause', 'resume', 'skip', 'previous', 'search'],
        description: 'The media control action to perform. Defaults to play.',
      },
      title: {
        type: 'string',
        description: 'The song title.',
      },
      artist: {
        type: 'string',
        description: 'The artist name.',
      },
      query: {
        type: 'string',
        description: 'The raw query if title/artist cannot be extracted cleanly.',
      },
      app: {
        type: 'string',
        enum: ['auto', 'music', 'spotify'],
        description: 'Target music player ("music" for Apple Music, "spotify" for Spotify, or "auto" to automatically pick). Default: "auto".',
      },
    },
    required: [],
  },
  validate(params: unknown) {
    if (!params || typeof params !== 'object') {
      return { valid: false, error: 'Parameters must be an object' };
    }
    const p = params as Record<string, unknown>;
    if (p.action && ['pause', 'resume', 'skip', 'previous'].includes(p.action as string)) {
      return { valid: true };
    }
    if (!p.query && !p.title && !p.artist) {
      return { valid: false, error: 'Either query, title, or artist is required for searching/playing' };
    }
    return { valid: true };
  },
  async execute(
    params: PlayMusicParams,
    context: ToolExecutionContext
  ): Promise<ToolResult<PlayMusicResultData>> {
    let targetApp = params.app || 'auto';
    const action = params.action || 'play';
    
    if (['pause', 'resume', 'skip', 'previous'].includes(action)) {
      try {
        let script = '';
        if (action === 'pause') script = 'tell application "Music" to pause';
        if (action === 'resume') script = 'tell application "Music" to play';
        if (action === 'skip') script = 'tell application "Music" to next track';
        if (action === 'previous') script = 'tell application "Music" to previous track';
        
        await execFileAsync('osascript', ['-e', script]);
        return {
          success: true,
          data: {
            app: 'Apple Music',
            query: action,
            action: 'media_control',
            message: `Media control: ${action} executed.`,
          }
        };
      } catch (err) {
        return { success: false, error: `Gagal menjalankan kontrol media: ${err}` };
      }
    }

    const rawQuery = params.query || (params.title && params.artist ? `${params.title} ${params.artist}` : params.title || params.artist || '');
    const query = rawQuery.trim();

    // Auto-detect target based on user keywords if set to auto
    if (targetApp === 'auto') {
      const lower = query.toLowerCase();
      if (lower.includes('spotify')) {
        targetApp = 'spotify';
      } else {
        targetApp = 'music';
      }
    }

    context.logger.info(`play_music requested for "${query}" on target: ${targetApp}`);

    // Clean query from player names (e.g. "di spotify", "in apple music")
    const cleanQuery = query
      .replace(/\b(di|in|on)\s+(spotify|apple\s*music|music)\b/gi, '')
      .replace(/\b(spotify|apple\s*music)\b/gi, '')
      .trim();

    // 1. SPOTIFY HANDLING
    if (targetApp === 'spotify') {
      const hasSpotify = await isSpotifyInstalled();
      
      let spotifyQuery = cleanQuery;
      if (params.title && params.artist) {
        spotifyQuery = `track:${params.title} artist:${params.artist}`;
      } else if (params.artist) {
        spotifyQuery = `artist:${params.artist}`;
      } else if (params.title) {
        spotifyQuery = `track:${params.title}`;
      }

      if (hasSpotify) {
        try {
          await execFileAsync('open', [`spotify:search:${encodeURIComponent(spotifyQuery)}`]);
          // Short delay then send play command
          await new Promise((r) => setTimeout(r, 400));
          try {
            await execFileAsync('osascript', ['-e', 'tell application "Spotify" to play']);
          } catch {}

          return {
            success: true,
            data: {
              app: 'Spotify',
              query: spotifyQuery,
              action: 'spotify_app',
              message: `Membuka dan memutar "${cleanQuery}" di aplikasi Spotify.`,
            },
          };
        } catch (err) {
          const msg = err instanceof Error ? err.message : String(err);
          context.logger.warn(`Failed to open Spotify URI: ${msg}`);
        }
      }

      // Fallback to Spotify Web if app not installed
      const webUrl = `https://open.spotify.com/search/${encodeURIComponent(cleanQuery)}`;
      try {
        await execFileAsync('open', [webUrl]);
        return {
          success: true,
          data: {
            app: 'Spotify Web',
            query: cleanQuery,
            action: 'spotify_web',
            message: `Aplikasi Spotify belum terpasang di Mac, membuka lagu "${cleanQuery}" di Spotify Web browser.`,
          },
        };
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        return {
          success: false,
          error: `Gagal membuka Spotify Web: ${msg}`,
        };
      }
    }

    // 2. APPLE MUSIC HANDLING (Native macOS Player)
    try {
      // Step A: Check if song exists in local user's library and play directly
      const safeQueryForAppleScript = cleanQuery.replace(/"/g, '\\"');
      const script = `
        tell application "Music"
          activate
          set searchResults to (search playlist 1 for "${safeQueryForAppleScript}")
          if (count of searchResults) > 0 then
            play (item 1 of searchResults)
            return "playing_library"
          else
            return "not_in_library"
          end if
        end tell
      `;

      const { stdout } = await execFileAsync('osascript', ['-e', script]);
      const status = stdout.trim();

      if (status === 'playing_library') {
        return {
          success: true,
          data: {
            app: 'Apple Music',
            query: cleanQuery,
            action: 'playing_library',
            message: `Memutar "${cleanQuery}" langsung dari perpustakaan Apple Music.`,
          },
        };
      }
    } catch (err) {
      context.logger.warn(`Local Music library check skipped: ${err}`);
    }

    // Step B: Search catalog via iTunes Search API to get exact track deep link
    const catalogMatch = await searchAppleMusicCatalog({ ...params, query: cleanQuery });
    if (catalogMatch && catalogMatch.trackUrl) {
      try {
        // 1. Pause any currently playing track first so player does not resume previous song
        try {
          await execFileAsync('osascript', ['-e', 'tell application "Music" to pause']);
        } catch {}

        // 2. Open new track/album deep link
        const nativeUrl = catalogMatch.trackUrl.replace(/^https?:\/\//i, 'music://');
        context.logger.info(`Opening Apple Music deep link: ${nativeUrl}`);
        await execFileAsync('open', [nativeUrl]);

        // 3. Wait for Music app to load and render the new album view
        await new Promise((r) => setTimeout(r, 1400));

        // 4. Locate the exact track row and double-click it directly so playback starts on that song
        const safeTargetTitle = (catalogMatch.trackName || cleanQuery).replace(/"/g, '\\"');
        const findTrackScript = `
          tell application "Music" to activate
          delay 0.4
          tell application "System Events"
            tell process "Music"
              set frontmost to true
              try
                set sg to first UI element of front window whose role is "AXSplitGroup"
                repeat with el in every UI element of sg
                  try
                    if description of el is "album details" then
                      set trackTable to first UI element of el whose description is "track list"
                      set rc to count of rows of trackTable
                      repeat with idx from 1 to rc
                        set r to row idx of trackTable
                        set isMatch to false
                        try
                          if (value of attribute "AXSelected" of r) is true then
                            set isMatch to true
                          end if
                        end try
                        if not isMatch then
                          try
                            repeat with subEl in every UI element of r
                              if name of subEl contains "${safeTargetTitle}" then
                                set isMatch to true
                                exit repeat
                              end if
                            end repeat
                          end try
                        end if
                        if isMatch then
                          set pos to position of r
                          set sz to size of r
                          return "found:" & ((item 1 of pos as integer) as string) & ":" & ((item 2 of pos as integer) as string) & ":" & ((item 1 of sz as integer) as string) & ":" & ((item 2 of sz as integer) as string)
                        end if
                      end repeat
                    end if
                  end try
                end repeat
              end try
              return "not_found"
            end tell
          end tell
        `;

        let playedTrack = false;
        try {
          const { stdout: findOut } = await execFileAsync('osascript', ['-e', findTrackScript]);
          const resultText = findOut.trim();
          if (resultText.startsWith('found:')) {
            const parts = resultText.split(':');
            const posX = parseInt(parts[1], 10);
            const posY = parseInt(parts[2], 10);
            const height = parseInt(parts[4], 10) || 46;
            const clickX = posX + 120;
            const clickY = posY + Math.floor(height / 2);

            const swiftDoubleClick = `
import CoreGraphics
import Foundation

let point = CGPoint(x: ${clickX}, y: ${clickY})
let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
move?.post(tap: .cghidEventTap)
usleep(15000)

let down1 = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
down1?.setIntegerValueField(.mouseEventClickState, value: 1)
down1?.post(tap: .cghidEventTap)
usleep(30000)

let up1 = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
up1?.setIntegerValueField(.mouseEventClickState, value: 1)
up1?.post(tap: .cghidEventTap)
usleep(50000)

let down2 = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
down2?.setIntegerValueField(.mouseEventClickState, value: 2)
down2?.post(tap: .cghidEventTap)
usleep(30000)

let up2 = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
up2?.setIntegerValueField(.mouseEventClickState, value: 2)
up2?.post(tap: .cghidEventTap)
`;
            execFileSync('swift', ['-'], { input: swiftDoubleClick, encoding: 'utf-8' });
            playedTrack = true;
            context.logger.info(`Double-clicked track row for "${catalogMatch.trackName}" at (${clickX}, ${clickY})`);
          }
        } catch (err) {
          context.logger.warn(`Finding/double-clicking track row encountered error: ${err}`);
        }

        if (!playedTrack) {
          // Fallback to album play button or telling Music to play
          try {
            await execFileAsync('osascript', ['-e', 'tell application "Music" to play']);
          } catch {}
        }

        const songDisplay = catalogMatch.artistName
          ? `"${catalogMatch.trackName}" oleh ${catalogMatch.artistName}`
          : `"${catalogMatch.trackName}"`;

        return {
          success: true,
          data: {
            app: 'Apple Music',
            query: cleanQuery,
            trackName: catalogMatch.trackName,
            artistName: catalogMatch.artistName,
            action: 'playing_catalog',
            message: `Memutar ${songDisplay} di Apple Music.`,
          },
        };
      } catch (err) {
        context.logger.warn(`Failed opening deep link: ${err}`);
      }
    }

    // Step C: Fallback to general search URL if API match not found
    try {
      try {
        await execFileAsync('osascript', ['-e', 'tell application "Music" to pause']);
      } catch {}

      const appleMusicUrl = `music://music.apple.com/search?term=${encodeURIComponent(cleanQuery)}`;
      await execFileAsync('open', [appleMusicUrl]);
      await new Promise((r) => setTimeout(r, 1400));

      const fallbackClickScript = `
        tell application "Music" to activate
        delay 0.4
        tell application "System Events"
          tell process "Music"
            set frontmost to true
            try
              set sg to first UI element of front window whose role is "AXSplitGroup"
              repeat with el in every UI element of sg
                try
                  repeat with b in every button of el
                    try
                      if description of b is "play" or name of b is "Play" then
                        click b
                        return "clicked_play"
                      end if
                    end try
                  end repeat
                end try
              end repeat
            end try
            return "fallback"
          end tell
        end tell
      `;

      try {
        await execFileAsync('osascript', ['-e', fallbackClickScript]);
      } catch {
        try {
          await execFileAsync('osascript', ['-e', 'tell application "Music" to play']);
        } catch {}
      }

      return {
        success: true,
        data: {
          app: 'Apple Music',
          query: cleanQuery,
          action: 'catalog_search',
          message: `Membuka dan memutar "${cleanQuery}" di Apple Music.`,
        },
      };
    } catch (openErr) {
      const msg = openErr instanceof Error ? openErr.message : String(openErr);
      return {
        success: false,
        error: `Gagal membuka Apple Music: ${msg}`,
      };
    }
  },
};

export const searchMusicTool: ToolDefinition<PlayMusicParams, PlayMusicResultData> = {
  ...playMusicTool,
  name: 'search_music',
  description: 'Searches for songs, albums, or artists in Apple Music or Spotify on macOS.',
  // Spreading playMusicTool would otherwise inherit its `reversible` class
  // implicitly; restate it so the classification is deliberate.
  safety: toolSafety('reversible'),
};
