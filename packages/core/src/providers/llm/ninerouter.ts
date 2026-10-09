import OpenAI from 'openai';
import type {
  LLMProvider,
  LLMCompletionOptions,
  LLMCompletionResponse,
  ToolCallRequest,
  ToolDefinition,
  ChatMessage,
} from '@lofly/types';

export interface NineRouterOptions {
  apiKey?: string;
  baseUrl?: string;
  model?: string;
  timeoutMs?: number;
  logger?: unknown;
}

export class NineRouterProvider implements LLMProvider {
  public name = 'ninerouter';
  public model: string;
  public baseUrl: string;
  private client: OpenAI;

  constructor(options: NineRouterOptions = {}) {
    this.baseUrl = (
      options.baseUrl ||
      process.env.NINEROUTER_BASE_URL ||
      'http://localhost:20128/v1'
    ).replace(/\/$/, '');

    const apiKey =
      options.apiKey ||
      process.env.NINEROUTER_API_KEY ||
      'dummy-key-not-empty';

    this.model =
      options.model ||
      process.env.NINEROUTER_MODEL ||
      'ag/gemini-3.8-flash-high';

    this.client = new OpenAI({
      baseURL: this.baseUrl,
      apiKey: apiKey,
      timeout: options.timeoutMs ?? 30000,
    });
  }

  public async complete(options: LLMCompletionOptions): Promise<LLMCompletionResponse> {
    const formattedTools = options.tools && options.tools.length > 0
      ? options.tools.map((tool: ToolDefinition) => ({
          type: 'function' as const,
          function: {
            name: tool.name,
            description: tool.description,
            parameters: tool.parameters as unknown as Record<string, unknown>,
          },
        }))
      : undefined;

    const formattedMessages = options.messages.map((m: ChatMessage) => {
      if (m.role === 'tool') {
        return {
          role: 'tool' as const,
          content: m.content || '',
          tool_call_id: m.tool_call_id || '',
        };
      }
      if (m.role === 'assistant' && m.tool_calls && m.tool_calls.length > 0) {
        return {
          role: 'assistant' as const,
          content: m.content || null,
          tool_calls: m.tool_calls.map((tc) => ({
            id: tc.id,
            type: 'function' as const,
            function: {
              name: tc.function.name,
              arguments: tc.function.arguments,
            },
          })),
        };
      }
      return {
        role: m.role as 'system' | 'user' | 'assistant',
        content: m.content || '',
      };
    });

    const candidateModels = Array.from(
      new Set([
        this.model,
        'ag/gemini-3.8-flash-high',
        'nara/gemini-3.8-flash-high',
        'ag/gemini-3.8-flash',
        'gc/gemini-2.5-flash',
      ])
    );

    let lastError: unknown = null;

    for (const targetModel of candidateModels) {
      try {
        if (options.onChunk) {
          const stream = await this.client.chat.completions.create(
            {
              model: targetModel,
              messages: formattedMessages,
              tools: formattedTools,
              temperature: options.temperature ?? 0.3,
              max_tokens: options.maxTokens ?? 2048,
              stream: true,
            },
            { signal: options.signal }
          );

          let accumulatedContent = '';
          const toolCallAccumulator: Record<number, { id: string; name: string; args: string }> = {};

          for await (const chunk of stream) {
            if (options.signal?.aborted) break;
            const choice = chunk.choices?.[0];
            const delta = choice?.delta;
            if (!delta) continue;

            if (delta.content) {
              accumulatedContent += delta.content;
              options.onChunk(delta.content);
            }

            if (delta.tool_calls) {
              for (const tc of delta.tool_calls) {
                const idx = tc.index ?? 0;
                if (!toolCallAccumulator[idx]) {
                  toolCallAccumulator[idx] = {
                    id: tc.id || `call_${Date.now()}_${idx}`,
                    name: '',
                    args: '',
                  };
                }
                if (tc.id) toolCallAccumulator[idx].id = tc.id;
                if (tc.function?.name) {
                  if (!toolCallAccumulator[idx].name) {
                    toolCallAccumulator[idx].name = tc.function.name;
                  } else if (!toolCallAccumulator[idx].name.includes(tc.function.name)) {
                    toolCallAccumulator[idx].name += tc.function.name;
                  }
                }
                if (tc.function?.arguments) toolCallAccumulator[idx].args += tc.function.arguments;
              }
            }
          }

          const toolCalls: ToolCallRequest[] = [];
          for (const item of Object.values(toolCallAccumulator)) {
            if (item.name) {
              let parsedArgs: Record<string, unknown> = {};
              try {
                parsedArgs = JSON.parse(item.args || '{}');
              } catch {
                // best-effort
              }
              toolCalls.push({
                id: item.id,
                name: item.name,
                parameters: parsedArgs,
              });
            }
          }

          return {
            content: accumulatedContent || null,
            toolCalls: toolCalls.length > 0 ? toolCalls : undefined,
            rawResponse: null,
          };
        }

        const response = await this.client.chat.completions.create(
          {
            model: targetModel,
            messages: formattedMessages,
            tools: formattedTools,
            temperature: options.temperature ?? 0.3,
            max_tokens: options.maxTokens ?? 2048,
          },
          { signal: options.signal }
        );

        const choice = response.choices?.[0]?.message;
        if (!choice) {
          return { content: '', rawResponse: response };
        }

        const toolCalls: ToolCallRequest[] = [];
        if (choice.tool_calls && choice.tool_calls.length > 0) {
          for (const tc of choice.tool_calls) {
            if (tc.type === 'function' && tc.function) {
              try {
                toolCalls.push({
                  id: tc.id,
                  name: tc.function.name,
                  parameters: JSON.parse(tc.function.arguments || '{}'),
                });
              } catch {
                toolCalls.push({
                  id: tc.id,
                  name: tc.function.name,
                  parameters: {},
                });
              }
            }
          }
        }

        return {
          content: choice.content || null,
          toolCalls: toolCalls.length > 0 ? toolCalls : undefined,
          rawResponse: response,
        };
      } catch (err: unknown) {
        lastError = err;
        const msg = err instanceof Error ? err.message : String(err);
        // If connection refused or 401 auth error, fail immediately without rotating models
        if (
          msg.includes('ECONNREFUSED') ||
          msg.includes('fetch failed') ||
          msg.includes('ENOTFOUND') ||
          msg.includes('401') ||
          msg.includes('Unauthorized') ||
          msg.includes('Incorrect API key')
        ) {
          break;
        }
        // Otherwise continue loop to try fallback model
      }
    }

    const message = lastError instanceof Error ? lastError.message : String(lastError);

    // Friendly, clean error categorization
    if (message.includes('ECONNREFUSED') || message.includes('fetch failed') || message.includes('ENOTFOUND')) {
      throw new Error(
        `Gue nggak bisa terhubung ke 9Router di ${this.baseUrl}. Pastikan 9Router sedang berjalan.`
      );
    }
    if (message.includes('401') || message.includes('Unauthorized') || message.includes('Incorrect API key')) {
      throw new Error(
        'Autentikasi 9Router gagal. Periksa kembali NINEROUTER_API_KEY di file .env Anda.'
      );
    }
    if (message.includes('404') || message.includes('model_not_found') || message.includes('does not exist')) {
      throw new Error(
        `Model "${this.model}" tidak ditemukan di 9Router. Periksa konfigurasi NINEROUTER_MODEL.`
      );
    }
    if (message.includes('timeout') || message.includes('ETIMEDOUT')) {
      throw new Error('Permintaan ke 9Router mengalami batas waktu (timeout).');
    }

    throw new Error(`9Router error: ${message}`);
  }
}
