import { describe, it, expect } from 'vitest';
import { extractMusicIntent } from '../packages/core/src/parser/music-parser.js';

describe('extractMusicIntent', () => {
  it('handles "dari" separator', () => {
    const result = extractMusicIntent('Manchild dari Sabrina Carpenter');
    expect(result.title).toBe('Manchild');
    expect(result.artist).toBe('Sabrina Carpenter');
  });

  it('handles "oleh" separator', () => {
    const result = extractMusicIntent('Manchild oleh Sabrina Carpenter');
    expect(result.title).toBe('Manchild');
    expect(result.artist).toBe('Sabrina Carpenter');
  });

  it('handles "by" separator', () => {
    const result = extractMusicIntent('Manchild by Sabrina Carpenter');
    expect(result.title).toBe('Manchild');
    expect(result.artist).toBe('Sabrina Carpenter');
  });

  it('handles dash separator', () => {
    const result = extractMusicIntent('Creep - Radiohead');
    expect(result.title).toBe('Creep');
    expect(result.artist).toBe('Radiohead');
  });

  it('normalizes common STT misspellings in artist name', () => {
    const result = extractMusicIntent('manchild dari Sabrina carpenther');
    expect(result.title).toBe('manchild');
    expect(result.artist).toBe('Sabrina Carpenter');
  });

  it('handles missing separator (fallback to query)', () => {
    const result = extractMusicIntent('Creep radiohead');
    expect(result.query).toBe('Creep radiohead');
    expect(result.title).toBeUndefined();
    expect(result.artist).toBeUndefined();
  });

  it('handles title only without separator', () => {
    const result = extractMusicIntent('Manchild');
    expect(result.query).toBe('Manchild');
    expect(result.title).toBeUndefined();
    expect(result.artist).toBeUndefined();
  });
});
