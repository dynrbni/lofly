import { describe, it, expect, vi, beforeEach } from 'vitest';
import { AgentRuntime } from '../packages/core/src/agent/runtime.js';
import { fastRoute } from '../packages/core/src/router/fast-router.js';
import { extractMusicIntent } from '../packages/core/src/parser/music-parser.js';
import type { LLMProvider } from '@lofly/types';

describe('Voice Pipeline & Session Isolation Acceptance Test', () => {
  let mockProvider: LLMProvider;
  let runtime: AgentRuntime;

  beforeEach(() => {
    mockProvider = {
      name: 'mock',
      complete: vi.fn().mockResolvedValue({
        content: 'Mock response',
        toolCalls: [],
      }),
    };

    runtime = new AgentRuntime({
      llmProvider: mockProvider,
      tools: [],
    });
  });

  it('runs consecutive voice commands without state leakage or previous command reuse (Requirement 12)', async () => {
    const sequence = [
      {
        id: 'session_1',
        utterance: 'play lagu mental dari Sabrina Carpenter',
        expectedKeyword: 'mental',
        forbiddenKeyword: 'manchild',
      },
      {
        id: 'session_2',
        utterance: 'play lagu manchild dari Sabrina Carpenter',
        expectedKeyword: 'manchild',
        forbiddenKeyword: 'mental',
      },
      {
        id: 'session_3',
        utterance: 'play lagu creep dari Radiohead',
        expectedKeyword: 'creep',
        forbiddenKeyword: 'manchild',
      },
      {
        id: 'session_4',
        utterance: 'play lagu manchild dari Sabrina Carpenter',
        expectedKeyword: 'manchild',
        forbiddenKeyword: 'mental',
      },
      {
        id: 'session_5',
        utterance: 'play lagu mental dari Sabrina Carpenter',
        expectedKeyword: 'mental',
        forbiddenKeyword: 'manchild',
      },
    ];

    for (let i = 0; i < sequence.length; i++) {
      const step = sequence[i];
      const res = await runtime.handleTranscript(step.utterance, {
        voiceSessionId: step.id,
      });

      // 1. Raw transcript must be preserved exactly
      expect(res.rawTranscript).toBe(step.utterance);

      // 2. Normalized transcript must contain expected keyword
      expect(res.normalizedTranscript?.toLowerCase()).toContain(step.expectedKeyword);

      // 3. Normalized transcript must NEVER contain forbidden keyword from another session
      expect(res.normalizedTranscript?.toLowerCase()).not.toContain(step.forbiddenKeyword);

      // 4. Fast route / music parser extraction
      const route = fastRoute(res.normalizedTranscript!);
      expect(route.matched).toBe(true);
      expect(route.toolCalls).toBeDefined();
      expect(route.toolCalls![0].name).toBe('play_music');

      const params = route.toolCalls![0].parameters as { title?: string; artist?: string; query?: string };
      const parsedTitle = params.title?.toLowerCase() || params.query?.toLowerCase() || '';
      expect(parsedTitle).toContain(step.expectedKeyword);
      expect(parsedTitle).not.toContain(step.forbiddenKeyword);
    }
  });

  it('verifies music parser correctly separates title and artist for manchild without mutating to mental', () => {
    const intent = extractMusicIntent('manchild dari Sabrina Carpenter', 'play');
    expect(intent.title?.toLowerCase()).toBe('manchild');
    expect(intent.artist?.toLowerCase()).toBe('sabrina carpenter');
    expect(intent.title?.toLowerCase()).not.toContain('mental');
  });
});
