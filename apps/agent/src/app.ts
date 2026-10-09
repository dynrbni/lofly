import http from 'http';
import { WebSocketServer, WebSocket } from 'ws';
import type {
  AssistantEvent,
  ConfirmationRequest,
  ConfirmationResponse,
  LLMProvider,
  TextToSpeechProvider,
} from '@lofly/types';
import { getConfig, type LoflyConfig } from '@lofly/config';
import type { IntegrationDescriptor, ToolCallRequest, AgentRunResult } from '@lofly/types';
import { ToolExecutor, getToolSafety } from '@lofly/tools';
import {
  AgentRuntime,
  StructuredLogger,
  NineRouterProvider,
  GeminiLLMProvider,
  OpenAILLMProvider,
  MockLLMProvider,
  MacOSSayTTSProvider,
  MockTTSProvider,
  FileConversationStore,
  FileMemoryStore,
  TaskManager,
  ActivityLog,
  SettingsStore,
  AccountStore,
  describeIntegrations,
  humanizeToolName,
  capabilityLabel,
  firstSentence,
  SttDiagnosticsStore,
  parseUtteranceDiagnostics,
  buildSttReport,
  formatSttReport,
  type OutcomeDiagnostics,
} from '@lofly/core';
import { execFile } from 'child_process';
import { promisify } from 'util';

const execFileAsync = promisify(execFile);

/**
 * A request body that is not valid JSON.
 *
 * Thrown while reading the body so the caller gets a 400 — the mistake is the
 * client's, not the server's — and so the request can never be left without an
 * answer. Both clients send well-formed JSON, but a hand-rolled request or a
 * proxy in the middle must not be able to hang a route or trip an unhandled
 * rejection.
 */
class InvalidJsonBodyError extends Error {
  constructor() {
    super('Request body is not valid JSON.');
    this.name = 'InvalidJsonBodyError';
  }
}

export interface LoflyAppOptions {
  config?: LoflyConfig;
  llmProvider?: LLMProvider;
  ttsProvider?: TextToSpeechProvider;

  /**
   * Store overrides. Tests inject isolated paths so the suite never reads or
   * writes the developer's real ~/.lofly data.
   */
  conversations?: FileConversationStore;
  memory?: FileMemoryStore;
  tasks?: TaskManager;
  activity?: ActivityLog;
  settings?: SettingsStore;
  account?: AccountStore;
  sttDiagnostics?: SttDiagnosticsStore;
}

export class LoflyAgentApp {
  public config: LoflyConfig;
  public logger: StructuredLogger;
  public runtime: AgentRuntime;
  public executor: ToolExecutor;
  public httpServer: http.Server;
  public wss: WebSocketServer;
  public llmProvider: LLMProvider;

  /** Shared state consumed by both the notch and the desktop app. */
  public conversations: FileConversationStore;
  public memory: FileMemoryStore;
  public tasks: TaskManager;
  public activity: ActivityLog;
  public settings: SettingsStore;
  public account: AccountStore;
  /** Opt-in per-utterance STT diagnostics (written only when the app asks). */
  public sttDiagnostics: SttDiagnosticsStore;

  private currentConversationId: string | null = null;
  private currentTaskId: string | null = null;
  private integrationProbeCache: { at: number; value: IntegrationDescriptor[] } | null = null;

  private pendingConfirmations = new Map<
    string,
    {
      request: ConfirmationRequest;
      resolve: (approved: boolean) => void;
      timeoutId: NodeJS.Timeout;
    }
  >();

  constructor(options: LoflyAppOptions = {}) {
    this.config = options.config || getConfig();
    this.logger = new StructuredLogger(this.config.logging.level, 'AgentServer');

    // 1. Configure LLM Provider
    const llmProvider = options.llmProvider || this.resolveLLMProvider();
    this.llmProvider = llmProvider;

    // 2. Configure TTS Provider
    const ttsProvider = options.ttsProvider || this.resolveTTSProvider();

    // 3. Configure Tool Executor with Confirmation Hook
    this.executor = new ToolExecutor({
      logger: this.logger,
      confirmSensitive: this.config.security.confirmSensitiveActions,
      confirmDangerous: this.config.security.confirmDangerousActions,
      requestConfirmation: (req) => this.handleConfirmationRequest(req),
    });

    // 4. Configure Agent Runtime (full computer-use capabilities)
    this.runtime = new AgentRuntime({
      llmProvider,
      toolExecutor: this.executor,
      ttsProvider,
      logger: this.logger,
      assistantName: this.config.assistant.name,
    });

    // 5. Shared stores backing the desktop control center
    this.conversations = options.conversations || new FileConversationStore();
    this.memory = options.memory || new FileMemoryStore();
    this.tasks = options.tasks || new TaskManager();
    this.activity = options.activity || new ActivityLog();
    this.settings = options.settings || new SettingsStore();
    this.account = options.account || new AccountStore();
    this.sttDiagnostics = options.sttDiagnostics || new SttDiagnosticsStore();

    // 6. Create HTTP & WebSocket Servers
    // Every request must be answered. The route handlers below return early, so
    // a rejection that escapes one of them — an unreadable body on a route with
    // no local try/catch — would otherwise leave the socket open until the
    // client timed out, with nothing logged but an unhandled rejection.
    this.httpServer = http.createServer((req, res) => {
      this.handleHttpRequest(req, res).catch((err) => {
        const badBody = err instanceof InvalidJsonBodyError;
        this.logger.warn(
          `Unanswered request ${req.method} ${req.url}: ${err instanceof Error ? err.message : String(err)}`
        );
        if (!res.headersSent) {
          res.writeHead(badBody ? 400 : 500, { 'Content-Type': 'application/json' });
          res.end(
            JSON.stringify({
              error: badBody ? 'Request body is not valid JSON.' : 'Internal error.',
            })
          );
        }
      });
    });
    this.wss = new WebSocketServer({ server: this.httpServer, path: '/ws' });

    this.setupWebSocket();
    this.setupRuntimeEvents();
    this.setupTaskBroadcast();
  }

  /** Pushes every task state change to all surfaces over the shared socket. */
  private setupTaskBroadcast(): void {
    this.tasks.subscribe((task) => {
      this.broadcast({ type: 'task_update', payload: task, timestamp: Date.now() });
    });
  }

  public getConversationId(): string | null {
    return this.currentConversationId;
  }

  private resolveLLMProvider(): LLMProvider {
    const {
      provider,
      model,
      nineRouterBaseUrl,
      nineRouterApiKey,
      nineRouterModel,
      geminiApiKey,
      openAiApiKey,
      ollamaBaseUrl,
    } = this.config.llm;

    if (
      provider === 'ninerouter' ||
      (nineRouterBaseUrl && provider !== 'gemini' && provider !== 'openai' && provider !== 'ollama')
    ) {
      const activeModel = nineRouterModel || model || 'ag/gemini-3.8-flash-high';
      this.logger.info(`Using 9Router LLM Provider at ${nineRouterBaseUrl} (model: ${activeModel})`);
      return new NineRouterProvider({
        baseUrl: nineRouterBaseUrl,
        apiKey: nineRouterApiKey,
        model: activeModel,
        logger: this.logger,
      });
    }

    if (provider === 'gemini' && geminiApiKey) {
      this.logger.info(`Using Gemini LLM Provider (model: ${model})`);
      return new GeminiLLMProvider({ apiKey: geminiApiKey, model });
    }

    if (provider === 'openai' && openAiApiKey) {
      this.logger.info(`Using OpenAI LLM Provider (model: ${model})`);
      return new OpenAILLMProvider({ apiKey: openAiApiKey, model });
    }

    if (provider === 'ollama') {
      this.logger.info(`Using Ollama LLM Provider at ${ollamaBaseUrl}`);
      return new OpenAILLMProvider({
        baseUrl: `${ollamaBaseUrl}/v1`,
        model: this.config.llm.ollamaModel,
      });
    }

    this.logger.warn('No LLM API key configured. Falling back to MockLLMProvider for offline execution.');
    return new MockLLMProvider();
  }

  private resolveTTSProvider(): TextToSpeechProvider {
    // When running with the native macOS app, speech synthesis is handled natively
    // by AVSpeechSynthesizer upon receiving WebSocket 'speech_start' events.
    // Having Node simultaneously execute `say` causes audio doubling/echo.
    if (this.config.tts.provider === 'macos' && process.env.ENABLE_NODE_SAY === 'true') {
      return new MacOSSayTTSProvider({
        defaultVoice: this.config.tts.voice,
        defaultSpeed: this.config.tts.speed,
      });
    }
    return new MockTTSProvider();
  }

  private handleConfirmationRequest(
    req: Omit<ConfirmationRequest, 'id' | 'timestamp'>
  ): Promise<boolean> {
    if (!this.config.security.confirmSensitiveActions && !this.config.security.confirmDangerousActions) {
      this.logger.info(`Auto-approving action: "${req.toolName}" (confirmation disabled in config)`);
      return Promise.resolve(true);
    }

    const id = `conf_${Date.now()}_${Math.random().toString(36).substring(2, 6)}`;
    const fullRequest: ConfirmationRequest = {
      ...req,
      id,
      timestamp: Date.now(),
    };

    return new Promise<boolean>((resolve) => {
      // Auto-timeout after 60 seconds -> denies by default
      const timeoutId = setTimeout(() => {
        if (this.pendingConfirmations.has(id)) {
          this.logger.warn(`Confirmation request timed out: ${id}`);
          this.pendingConfirmations.delete(id);
          resolve(false);
        }
      }, 60_000);

      this.pendingConfirmations.set(id, {
        request: fullRequest,
        resolve,
        timeoutId,
      });

      // Broadcast confirmation request to all connected UI clients
      this.broadcast({
        type: 'confirmation_required',
        payload: fullRequest,
        timestamp: Date.now(),
      });
    });
  }

  public resolveConfirmation(response: ConfirmationResponse): boolean {
    const pending = this.pendingConfirmations.get(response.id);
    if (!pending) {
      return false;
    }

    clearTimeout(pending.timeoutId);
    this.pendingConfirmations.delete(response.id);
    pending.resolve(response.approved);

    this.broadcast({
      type: 'confirmation_received',
      payload: response,
      timestamp: Date.now(),
    });

    return true;
  }

  private setupRuntimeEvents(): void {
    this.runtime.onEvent((event) => {
      this.broadcast(event);

      // Fold runtime events into the authoritative task record so the notch and
      // the desktop app render the same progress from the same source.
      if (event.type === 'tool_start') {
        const payload = event.payload as {
          toolName?: string;
          parameters?: Record<string, unknown>;
          callId?: string;
        };
        if (this.currentTaskId && payload.toolName) {
          // The call id is the exact correlation key: the fast router announces
          // a batch and then each call, and parallel runs reuse one tool name.
          this.tasks.addStep(this.currentTaskId, {
            id: payload.callId || `step_${Date.now()}_${Math.random().toString(36).substring(2, 6)}`,
            label: humanizeToolName(payload.toolName, payload.parameters || {}),
            state: 'running',
            toolName: payload.toolName,
          });
        }
      }

      if (event.type === 'tool_end') {
        const payload = event.payload as {
          toolName?: string;
          success?: boolean;
          error?: string;
          callId?: string;
        };
        if (this.currentTaskId && payload.toolName) {
          const stepId = payload.callId;
          let label: string | undefined;

          if (stepId) {
            const task = this.tasks.get(this.currentTaskId);
            const step = task?.steps.find((s) => s.id === stepId);
            if (step) {
              this.tasks.updateStep(
                this.currentTaskId,
                stepId,
                payload.success ? 'completed' : 'failed',
                payload.error
              );
              // Reuse the label captured at tool_start; tool_end carries no
              // parameters, so the target would otherwise be lost.
              label = step.label;
            }
          }

          // Activity records what happened, including whether the policy
          // suppressed the side effect entirely.
          const safety = getToolSafety(this.executor.getRegistry().get(payload.toolName)?.safety);
          const policy = this.executor.getPolicy();
          const simulated = policy.mode !== 'live' && safety.sideEffect !== 'none';

          this.activity.record({
            label: label || humanizeToolName(payload.toolName),
            toolName: payload.toolName,
            status: simulated ? 'simulated' : payload.success ? 'success' : 'failure',
            taskId: this.currentTaskId || undefined,
            conversationId: this.currentConversationId || undefined,
            detail: simulated ? `Suppressed by ${policy.mode} policy — no external side effect.` : payload.error,
            dryRun: simulated,
          });
        }
      }
    });
  }

  private setupWebSocket(): void {
    this.wss.on('connection', (ws: WebSocket) => {
      this.logger.info('WebSocket client connected');

      // Send initial handshake state
      ws.send(
        JSON.stringify({
          type: 'state_change',
          payload: {
            previousState: 'idle',
            newState: this.runtime.getState(),
          },
          timestamp: Date.now(),
        })
      );

      ws.on('message', async (data) => {
        try {
          const msg = JSON.parse(data.toString());
          await this.handleClientMessage(msg, ws);
        } catch (err) {
          this.logger.error('Failed to parse WebSocket message', { error: String(err) });
        }
      });

      ws.on('close', () => {
        this.logger.info('WebSocket client disconnected');
      });
    });
  }

  public broadcast(event: AssistantEvent): void {
    const data = JSON.stringify(event);
    for (const client of this.wss.clients) {
      if (client.readyState === WebSocket.OPEN) {
        client.send(data);
      }
    }
  }

  private async handleClientMessage(msg: Record<string, unknown>, ws: WebSocket): Promise<void> {
    if (msg.type === 'query' && typeof msg.text === 'string') {
      const result = await this.runtime.run(msg.text);
      ws.send(JSON.stringify({ type: 'query_result', payload: result, timestamp: Date.now() }));
    } else if (msg.type === 'confirm' && typeof msg.id === 'string' && typeof msg.approved === 'boolean') {
      const resolved = this.resolveConfirmation({
        id: msg.id,
        approved: msg.approved,
        reason: typeof msg.reason === 'string' ? msg.reason : undefined,
        timestamp: Date.now(),
      });
      ws.send(JSON.stringify({ type: 'confirm_ack', payload: { id: msg.id, resolved }, timestamp: Date.now() }));
    } else if (msg.type === 'wake') {
      this.runtime.setState('listening');
    } else if (msg.type === 'cancel') {
      const cancelled = this.runtime.cancelCurrentTask();
      ws.send(JSON.stringify({ type: 'cancel_ack', payload: { cancelled }, timestamp: Date.now() }));
    } else if (msg.type === 'reset') {
      this.runtime.resetConversation();
      this.runtime.setState('idle');
    }
  }

  private async handleHttpRequest(req: http.IncomingMessage, res: http.ServerResponse): Promise<void> {
    // CORS headers for local UI
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');

    if (req.method === 'OPTIONS') {
      res.writeHead(204);
      res.end();
      return;
    }

    const url = new URL(req.url || '/', `http://${req.headers.host || 'localhost'}`);
    const pathname = url.pathname;

    // Helper to send JSON
    const sendJson = (statusCode: number, data: unknown) => {
      res.writeHead(statusCode, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(data));
    };

    // 1. GET /health
    if (req.method === 'GET' && pathname === '/health') {
      sendJson(200, {
        status: 'ok',
        assistant: this.config.assistant.name,
        state: this.runtime.getState(),
        timestamp: Date.now(),
      });
      return;
    }

    // 2. GET /state
    if (req.method === 'GET' && pathname === '/state') {
      sendJson(200, {
        state: this.runtime.getState(),
        pendingConfirmations: Array.from(this.pendingConfirmations.values()).map((p) => p.request),
      });
      return;
    }

    // 3. GET /config
    if (req.method === 'GET' && pathname === '/config') {
      sendJson(200, {
        assistant: this.config.assistant,
        security: this.config.security,
        tools: this.executor.getRegistry().list().map((t) => ({
          name: t.name,
          description: t.description,
          permissionLevel: t.permissionLevel,
        })),
      });
      return;
    }

    // Helper to read JSON body
    const readBody = async (): Promise<Record<string, unknown>> => {
      return new Promise((resolve, reject) => {
        let body = '';
        req.on('data', (chunk) => {
          body += chunk.toString();
        });
        req.on('end', () => {
          try {
            resolve(body ? JSON.parse(body) : {});
          } catch {
            reject(new InvalidJsonBodyError());
          }
        });
        req.on('error', reject);
      });
    };

    // 4. POST /query
    if (req.method === 'POST' && pathname === '/query') {
      try {
        const body = await readBody();
        const text = typeof body.text === 'string' ? body.text : '';
        const attachments = Array.isArray(body.attachments) ? body.attachments.map(String) : [];

        if (!text.trim() && attachments.length === 0) {
          sendJson(400, { error: 'Missing or empty "text" parameter in query request.' });
          return;
        }

        // Push-to-talk is marked with source "voice": same runtime, but it
        // never lands in conversation history (see runTracked).
        const source = body.source === 'voice' ? 'voice' : 'text';
        const reasoningLevel = (typeof body.reasoningLevel === 'string' && ['low', 'medium', 'high'].includes(body.reasoningLevel))
          ? (body.reasoningLevel as 'low' | 'medium' | 'high')
          : undefined;

        let fullQuery = text;
        if (attachments.length > 0) {
          const attachmentList = attachments.map((p) => `- ${p}`).join('\n');
          fullQuery = `${text}\n\n[Lampiran file/gambar:\n${attachmentList}\n(Gunakan tool read_file atau tool yang relevan untuk membaca/memeriksa lampiran ini jika diperlukan)]`.trim();
        }

        const conversationIdParam = typeof body.conversationId === 'string' && body.conversationId.trim().length > 0
          ? body.conversationId.trim()
          : undefined;

        const voiceSessionId = (typeof body.voiceSessionId === 'string' && body.voiceSessionId.trim().length > 0)
          ? body.voiceSessionId.trim()
          : (typeof body.sessionId === 'string' && body.sessionId.trim().length > 0)
            ? body.sessionId.trim()
            : undefined;
        const sttDiagnostics = source === 'voice' && body.sttDiagnostics === true;

        const isStream = Boolean(body.stream) || req.headers.accept?.includes('text/event-stream');
        const requestId = `chat_${Date.now()}_${Math.random().toString(36).substring(2, 6)}`;

        if (isStream) {
          res.writeHead(200, {
            'Content-Type': 'text/event-stream',
            'Cache-Control': 'no-cache, no-transform',
            'Connection': 'keep-alive',
            'X-Accel-Buffering': 'no',
          });

          res.write(`data: ${JSON.stringify({ type: 'start', requestId })}\n\n`);

          let clientAborted = false;
          req.on('close', () => {
            clientAborted = true;
          });

          try {
            const { result, taskId, conversationId } = await this.runTracked(
              fullQuery,
              requestId,
              {
                source,
                reasoningLevel,
                attachments,
                conversationId: conversationIdParam,
                voiceSessionId,
                sttDiagnostics,
                onChunk: (chunk: string) => {
                  if (!clientAborted) {
                    res.write(`data: ${JSON.stringify({ type: 'chunk', text: chunk, requestId })}\n\n`);
                  }
                },
              }
            );

            if (!clientAborted) {
              res.write(
                `data: ${JSON.stringify({
                  type: 'done',
                  text: result.text,
                  taskId,
                  conversationId,
                  error: result.error,
                  completed: result.completed,
                  rawTranscript: result.rawTranscript,
                  normalizedTranscript: result.normalizedTranscript,
                })}\n\n`
              );
              res.end();
            }
          } catch (err) {
            if (!clientAborted) {
              res.write(`data: ${JSON.stringify({ type: 'error', error: String(err) })}\n\n`);
              res.end();
            }
          }
          return;
        }

        const { result, taskId, conversationId } = await this.runTracked(
          fullQuery,
          requestId,
          { source, reasoningLevel, attachments, conversationId: conversationIdParam, voiceSessionId, sttDiagnostics }
        );
        sendJson(200, { ...result, taskId, conversationId });
      } catch (err) {
        // An unreadable body is the caller's mistake: let the outer handler
        // answer 400 instead of reporting a server failure.
        if (err instanceof InvalidJsonBodyError) throw err;
        sendJson(500, { error: String(err) });
      }
      return;
    }

    // 5. POST /confirm
    if (req.method === 'POST' && pathname === '/confirm') {
      try {
        const body = await readBody();
        const id = String(body.id || '');
        const approved = Boolean(body.approved);
        const reason = typeof body.reason === 'string' ? body.reason : undefined;

        const resolved = this.resolveConfirmation({
          id,
          approved,
          reason,
          timestamp: Date.now(),
        });

        if (resolved) {
          sendJson(200, { success: true, message: `Confirmation ${id} resolved: ${approved ? 'APPROVED' : 'DENIED'}` });
        } else {
          sendJson(404, { success: false, error: `Confirmation request "${id}" not found or already resolved.` });
        }
      } catch (err) {
        if (err instanceof InvalidJsonBodyError) throw err;
        sendJson(500, { error: String(err) });
      }
      return;
    }

    // 6. POST /wake
    if (req.method === 'POST' && pathname === '/wake') {
      this.runtime.setState('listening');
      sendJson(200, { success: true, state: 'listening' });
      return;
    }

    // 7. POST /audio (Audio buffer transcription & execution)
    if (req.method === 'POST' && pathname === '/audio') {
      try {
        const chunks: Buffer[] = [];
        req.on('data', (c) => chunks.push(c));
        await new Promise((resolve) => req.on('end', resolve));
        const audioBuffer = Buffer.concat(chunks);
        this.logger.info(`Received audio recording for transcription (${audioBuffer.length} bytes)`);

        let transcript = '';
        if (this.config.stt.groqApiKey) {
          try {
            const form = new FormData();
            const blob = new Blob([audioBuffer], { type: 'audio/wav' });
            form.append('file', blob, 'audio.wav');
            form.append('model', 'whisper-large-v3-turbo');
            form.append('prompt', 'WhatsApp, Spotify, CapCut, VS Code, GitHub, Safari, Google Chrome, Word, Discord, Telegram, Terminal, Finder, Dimas, Backsy, buka, putar, chat, kirim pesan, lagu, playlist.');
            const groqRes = await fetch('https://api.groq.com/openai/v1/audio/transcriptions', {
              method: 'POST',
              headers: { Authorization: `Bearer ${this.config.stt.groqApiKey}` },
              body: form,
            });
            if (groqRes.ok) {
              const groqData = (await groqRes.json()) as { text: string };
              transcript = groqData.text;
            }
          } catch (e) {
            this.logger.warn(`Groq STT error: ${e}`);
          }
        }

        if (!transcript.trim()) {
          this.logger.warn('Audio could not be transcribed (no STT provider returned a transcript)');
          sendJson(400, {
            error: 'Suara tidak terdengar atau tidak dapat ditranskripsikan. Pastikan berbicara lebih jelas atau ketik langsung di kolom input.',
          });
          return;
        }

        this.logger.info(`Audio transcribed to: "${transcript}"`);
        // Voice and text share one pipeline, so a spoken command is tracked as
        // a task — but it is voice, so it never lands in chat history.
        const headerSessionId = req.headers['x-voice-session-id'] as string | undefined;
        const { result: agentResult, taskId } = await this.runTracked(
          transcript,
          `voice_${Date.now()}`,
          { source: 'voice', voiceSessionId: headerSessionId }
        );
        sendJson(200, {
          ...agentResult,
          taskId,
          rawTranscript: agentResult.rawTranscript || transcript,
          normalizedTranscript: agentResult.normalizedTranscript || transcript,
        });
      } catch (err) {
        sendJson(500, { error: String(err) });
      }
      return;
    }

    // 7b. GET /stt/config (STT configuration & shared vocabulary)
    if (req.method === 'GET' && pathname === '/stt/config') {
      sendJson(200, {
        cloudProvider: this.config.stt.groqApiKey ? 'whisper' : null,
        contextualStrings: [
          'WhatsApp', 'Spotify', 'CapCut', 'VS Code', 'GitHub', 'Safari', 'Google Chrome',
          'Word', 'Discord', 'Telegram', 'Terminal', 'Finder', 'Dimas', 'Backsy', 'buka',
          'putar', 'chat', 'kirim pesan', 'lagu', 'playlist', 'Sabrina Carpenter', 'Manchild',
          'manchild', 'Radiohead', 'Creep', 'Bruno Mars', 'Taylor Swift', 'Billie Eilish', 'Dongker'
        ],
      });
      return;
    }

    // 7c. POST /stt/diagnostics (opt-in per-utterance record from the app)
    if (req.method === 'POST' && pathname === '/stt/diagnostics') {
      const record = parseUtteranceDiagnostics(await readBody());
      if (!record) {
        sendJson(400, { error: 'Invalid utterance diagnostics record.' });
        return;
      }
      this.recordSttDiagnostics(record);
      sendJson(200, { success: true });
      return;
    }

    // 7d. GET /stt/diagnostics/report ("why did it miss" summary)
    if (req.method === 'GET' && pathname === '/stt/diagnostics/report') {
      const report = buildSttReport(this.sttDiagnostics.readAll());
      if (url.searchParams.get('format') === 'text') {
        res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8' });
        res.end(formatSttReport(report));
        return;
      }
      sendJson(200, report);
      return;
    }

    // 8. POST /cancel
    if (req.method === 'POST' && pathname === '/cancel') {
      const cancelled = this.runtime.cancelCurrentTask();
      sendJson(200, { success: true, cancelled, state: this.runtime.getState() });
      return;
    }

    // 9. POST /reset
    if (req.method === 'POST' && pathname === '/reset') {
      this.runtime.resetConversation();
      this.runtime.setState('idle');
      sendJson(200, { success: true, state: 'idle' });
      return;
    }

    // ───────────────────────────────────────────────────────────────────────
    // Desktop control center
    // ───────────────────────────────────────────────────────────────────────

    // Conversations
    if (req.method === 'GET' && pathname === '/conversations') {
      const q = url.searchParams.get('q');
      const list = q ? await this.conversations.search(q) : await this.conversations.list();
      // The list view omits message bodies to keep the sidebar payload small.
      sendJson(200, {
        conversations: list.map(({ messages, ...rest }) => ({
          ...rest,
          messageCount: messages.length,
        })),
        activeConversationId: this.currentConversationId,
      });
      return;
    }

    if (req.method === 'POST' && pathname === '/conversations') {
      const body = await readBody();
      const created = await this.conversations.create(
        typeof body.title === 'string' ? body.title : undefined
      );
      this.currentConversationId = created.id;
      this.runtime.resetConversation();
      sendJson(200, { success: true, conversation: created });
      return;
    }

    if (req.method === 'POST' && pathname === '/conversations/reset') {
      this.currentConversationId = null;
      this.runtime.resetConversation();
      sendJson(200, { success: true });
      return;
    }

    const conversationMatch = pathname.match(/^\/conversations\/([^/]+)$/);
    if (conversationMatch) {
      const id = decodeURIComponent(conversationMatch[1]);

      if (req.method === 'GET') {
        const conversation = await this.conversations.get(id);
        if (!conversation) {
          sendJson(404, { error: `Conversation "${id}" not found.` });
          return;
        }
        this.currentConversationId = id;
        sendJson(200, { conversation });
        return;
      }

      if (req.method === 'DELETE') {
        const deleted = await this.conversations.delete(id);
        if (this.currentConversationId === id) {
          this.currentConversationId = null;
        }
        sendJson(200, { success: deleted });
        return;
      }

      if (req.method === 'PATCH') {
        const body = await readBody();
        const updated = await this.conversations.updateTitle(
          id,
          typeof body.title === 'string' ? body.title : ''
        );
        if (!updated) {
          sendJson(404, { error: `Conversation "${id}" not found.` });
          return;
        }
        sendJson(200, { success: true, conversation: updated });
        return;
      }
    }

    // Tasks
    if (req.method === 'GET' && pathname === '/tasks') {
      sendJson(200, {
        tasks: this.tasks.list(),
        activeTask: this.tasks.active(),
      });
      return;
    }

    const taskCancelMatch = pathname.match(/^\/tasks\/([^/]+)\/cancel$/);
    if (req.method === 'POST' && taskCancelMatch) {
      const cancelled = this.runtime.cancelCurrentTask();
      const task = this.tasks.cancel(decodeURIComponent(taskCancelMatch[1]));
      sendJson(200, { success: cancelled, task });
      return;
    }

    const MEMORY_CATEGORIES = ['preference', 'fact', 'project', 'instruction'] as const;
    const readCategory = (value: unknown, fallback: (typeof MEMORY_CATEGORIES)[number]) =>
      MEMORY_CATEGORIES.includes(value as (typeof MEMORY_CATEGORIES)[number])
        ? (value as (typeof MEMORY_CATEGORIES)[number])
        : fallback;

    // Memory
    if (req.method === 'GET' && pathname === '/memory') {
      const category = url.searchParams.get('category') || undefined;
      const items = category ? await this.memory.search('', category) : await this.memory.list();
      sendJson(200, { memory: items });
      return;
    }

    const memoryMatch = pathname.match(/^\/memory\/([^/]+)$/);
    if (memoryMatch) {
      const id = decodeURIComponent(memoryMatch[1]);

      if (req.method === 'DELETE') {
        const deleted = await this.memory.delete(id);
        sendJson(deleted ? 200 : 404, { success: deleted });
        return;
      }

      if (req.method === 'PATCH') {
        const body = await readBody();
        const patch: Parameters<typeof this.memory.update>[1] = {};
        if (typeof body.content === 'string') patch.content = body.content;
        if (body.category !== undefined) patch.category = readCategory(body.category, 'fact');

        const updated = await this.memory.update(id, patch);
        if (!updated) {
          sendJson(404, { error: `Memory "${id}" not found.` });
          return;
        }
        sendJson(200, { success: true, memory: updated });
        return;
      }
    }

    if (req.method === 'POST' && pathname === '/memory') {
      const body = await readBody();
      if (typeof body.content !== 'string' || !body.content.trim()) {
        sendJson(400, { error: 'content is required' });
        return;
      }
      const saved = await this.memory.save({
        category: readCategory(body.category, 'fact'),
        content: body.content,
      });
      sendJson(200, { success: true, memory: saved });
      return;
    }

    if (req.method === 'DELETE' && pathname === '/memory') {
      for (const item of await this.memory.list()) {
        await this.memory.delete(item.id);
      }
      sendJson(200, { success: true });
      return;
    }

    // Activity
    if (req.method === 'GET' && pathname === '/activity') {
      const limitParam = url.searchParams.get('limit');
      const sinceParam = url.searchParams.get('since');
      sendJson(200, {
        activity: this.activity.list({
          limit: limitParam ? parseInt(limitParam, 10) : undefined,
          since: sinceParam ? parseInt(sinceParam, 10) : undefined,
        }),
      });
      return;
    }

    if (req.method === 'DELETE' && pathname === '/activity') {
      this.activity.clear();
      sendJson(200, { success: true });
      return;
    }

    // Integrations
    if (req.method === 'GET' && pathname === '/integrations') {
      sendJson(200, { integrations: await this.probeIntegrations() });
      return;
    }

    // Skills — what the agent can actually do, read straight from the tool
    // registry that executes the calls, so the screen can never advertise a
    // capability that is not wired up. Parameter schemas stay on the server.
    if (req.method === 'GET' && pathname === '/skills') {
      const policy = this.executor.getPolicy();
      const skills = this.executor
        .getRegistry()
        .list()
        .map((tool) => ({
          id: tool.name,
          // A capability phrase, not the activity log's past tense: this route
          // answers "what can Lofly do?", not "what did it just do?".
          name: capabilityLabel(tool.name),
          // The first sentence whole, so a row never ends mid-sentence.
          summary: firstSentence(tool.description),
          // Full text for the tooltip: shorter than the model's view of it only
          // by what a person does not need on one line.
          description: tool.description,
          permissionLevel: tool.permissionLevel,
          sideEffect: getToolSafety(tool.safety).sideEffect,
          // True while the policy simulates real actions. Surfaced so the
          // screen never presents a dry run as a live capability.
          simulated: policy.mode !== 'live',
        }));
      sendJson(200, { skills, executionMode: policy.mode });
      return;
    }

    // Settings
    if (req.method === 'GET' && pathname === '/settings') {
      sendJson(200, { settings: this.settings.get() });
      return;
    }

    if (req.method === 'PATCH' && pathname === '/settings') {
      const body = await readBody();
      sendJson(200, { success: true, settings: this.settings.update(body) });
      return;
    }

    if (req.method === 'POST' && pathname === '/settings/reset') {
      sendJson(200, { success: true, settings: this.settings.reset() });
      return;
    }

    // Account
    if (req.method === 'GET' && pathname === '/account') {
      sendJson(200, { account: this.account.get() });
      return;
    }

    if (req.method === 'POST' && pathname === '/account/sign-in') {
      const body = await readBody();
      sendJson(200, { success: true, account: this.account.signIn(String(body.displayName || '')) });
      return;
    }

    if (req.method === 'POST' && pathname === '/account/sign-out') {
      sendJson(200, { success: true, account: this.account.signOut() });
      return;
    }

    sendJson(404, { error: `Route not found: ${req.method} ${pathname}` });
  }

  /**
   * Probes installed applications once and caches briefly, so opening the
   * Integrations screen does not spawn a shell per row.
   */
  private async probeIntegrations(): Promise<IntegrationDescriptor[]> {
    const CACHE_MS = 15_000;
    if (this.integrationProbeCache && Date.now() - this.integrationProbeCache.at < CACHE_MS) {
      return this.integrationProbeCache.value;
    }

    const present = async (bundleId: string): Promise<boolean> => {
      try {
        const { stdout } = await execFileAsync('mdfind', [`kMDItemCFBundleIdentifier == '${bundleId}'`]);
        return stdout.trim().length > 0;
      } catch {
        return false;
      }
    };

    const [hasWhatsApp, hasMusic, hasSpotify, hasWord, hasChrome] = await Promise.all([
      present('net.whatsapp.WhatsApp'),
      present('com.apple.Music'),
      present('com.spotify.client'),
      present('com.microsoft.Word'),
      present('com.google.Chrome'),
    ]);

    const value = describeIntegrations({
      llmConfigured: this.config.llm.provider !== 'mock' && Boolean(this.config.llm.nineRouterApiKey || this.config.llm.geminiApiKey || this.config.llm.openAiApiKey),
      llmProvider: this.config.llm.provider,
      hasWhatsApp,
      hasMusic,
      hasSpotify,
      hasWord,
      hasChrome,
    });

    this.integrationProbeCache = { at: Date.now(), value };
    return value;
  }

  /**
   * Runs a query while recording it as a task. Typed input (`source: 'text'`,
   * the default) is appended to the shared conversation so the sidebar shows
   * it as chat history. Push-to-talk (`source: 'voice'`) shares the same
   * runtime, task tracking, and activity log but never lands in conversation
   * history — voice is transient, history is what the user typed.
   * Used by both POST /query and POST /audio so voice and text share one path.
   */
  /** Diagnostics are best-effort: a disk error must never fail a command. */
  private recordSttDiagnostics(record: Parameters<SttDiagnosticsStore['append']>[0]): void {
    try {
      this.sttDiagnostics.append(record);
    } catch (err) {
      this.logger.warn(`STT diagnostics write failed: ${err instanceof Error ? err.message : String(err)}`);
    }
  }

  private async runTracked(
    text: string,
    requestId: string,
    options: {
      source?: 'voice' | 'text';
      reasoningLevel?: 'low' | 'medium' | 'high';
      attachments?: string[];
      conversationId?: string;
      voiceSessionId?: string;
      onChunk?: (chunk: string) => void;
      /** The app opted in to STT diagnostics for this voice query. */
      sttDiagnostics?: boolean;
    } = {}
  ): Promise<{ result: AgentRunResult; conversationId: string | null; taskId: string }> {
    const persistToConversation = options.source !== 'voice';
    let conversationId: string | null = null;

    if (persistToConversation) {
      if (options.conversationId) {
        this.currentConversationId = options.conversationId;
      }
      if (!this.currentConversationId) {
        const conversation = await this.conversations.create();
        this.currentConversationId = conversation.id;
      }

      conversationId = this.currentConversationId;
      await this.conversations.appendMessage(conversationId, { role: 'user', text });
    }

    const taskId = `task_${requestId}`;
    this.currentTaskId = taskId;
    this.tasks.start(taskId, conversationId ?? 'voice', text.slice(0, 60));

    const diag: OutcomeDiagnostics | null =
      options.sttDiagnostics && options.voiceSessionId
        ? {
            kind: 'outcome',
            sessionId: options.voiceSessionId,
            ts: Date.now(),
            rawTranscript: text,
            normalizedTranscript: text,
            isValid: true,
            corrections: [],
          }
        : null;

    try {
      const result = await this.runtime.handleTranscript(text, {
        requestId,
        voiceSessionId: options.voiceSessionId,
        reasoningLevel: options.reasoningLevel,
        attachments: options.attachments,
        onChunk: options.onChunk,
        onTranscriptProcessed: diag
          ? (p) => {
              diag.normalizedTranscript = p.normalizedTranscript;
              diag.isValid = p.isValid;
              diag.validationReason = p.validationReason;
              diag.corrections = p.corrections.map((c) => ({ from: c.from, to: c.to, reason: c.reason }));
            }
          : undefined,
        onRoute: diag
          ? (r) => {
              diag.routeMatched = r.matched;
              diag.routeDomain = r.toolDomain;
              diag.routeTools = r.tools;
            }
          : undefined,
      });

      if (diag) {
        diag.error = result.error;
        this.recordSttDiagnostics(diag);
      }

      const outcome =
        result.error === 'cancelled' ? 'cancelled' : result.completed ? 'completed' : 'failed';

      // Close any step the runtime never explicitly ended (parallel tool
      // batches emit a start without a matching end).
      this.tasks.settleOpenSteps(taskId, outcome);
      this.tasks.setStatus(taskId, outcome);

      if (persistToConversation && conversationId) {
        const stored = await this.conversations.appendMessage(conversationId, {
          role: 'assistant',
          text: result.text,
          taskId,
          error: result.error,
        });

        const conversation = await this.conversations.get(conversationId);
        if (conversation && !conversation.taskReferences.includes(taskId)) {
          conversation.taskReferences.push(taskId);
        }

        // Generate AI title on the first interaction (conversation has <= 2 messages)
        if (conversation && conversation.messages.length <= 2) {
          try {
            await Promise.race([
              this.generateConversationTitle(conversationId, text, result.text),
              new Promise((r) => setTimeout(r, 1800)),
            ]);
          } catch {
            // best-effort
          }
        }

        this.broadcast({
          type: 'conversation_updated',
          payload: { conversationId, message: stored },
          timestamp: Date.now(),
        });
      } else {
        // Voice has no conversation to attach to, so the interaction itself is
        // recorded in activity — otherwise a spoken command that triggers no
        // tool would leave no trace at all.
        this.activity.record({
          label: text.length > 60 ? `${text.slice(0, 59)}…` : text,
          status: outcome === 'completed' ? 'success' : outcome === 'failed' ? 'failure' : 'cancelled',
          taskId,
        });
      }

      return { result, conversationId, taskId };
    } finally {
      this.currentTaskId = null;
    }
  }

  /**
   * Generates a concise, natural conversation title using AI (like ChatGPT),
   * matching the user's intent and language, instead of using raw prompt text.
   */
  public async generateConversationTitle(
    conversationId: string,
    userText: string,
    assistantText?: string
  ): Promise<string | null> {
    try {
      const cleanUser = userText
        .replace(/\[Lampiran file.*?\]/gs, '')
        .replace(/\s+/g, ' ')
        .trim();

      if (!cleanUser) return null;

      const prompt = `You are an AI conversation title generator, exactly like ChatGPT.
Task: Generate a concise, clear title (2 to 5 words maximum, plain text only, no quotes, no markdown, no trailing period).
Language: MUST be in the exact same language as the user's message (Indonesian or English).
Guidelines:
- Capture the main topic or task (e.g., "Bahaya Rokok WhatsApp", "Profil Bigmo", "Rencana Kerja Marketing", "Musik Bruno Mars").
- Do NOT use generic words like "Chat", "Percakapan", "Tanya", "Prompt", "Diskusi".
- Do NOT output anything else except the title.

User: "${cleanUser.slice(0, 300)}"
${assistantText ? `Assistant: "${assistantText.slice(0, 150)}"` : ''}

Title:`;

      const response = await this.llmProvider.complete({
        messages: [{ role: 'user', content: prompt }],
        temperature: 0.3,
        maxTokens: 25,
      });

      let title = response.content?.trim() || '';
      title = title.replace(/^["'«»“”„]+|["'«»“”„]+$/g, '');
      title = title.replace(/^(Title|Judul):\s*/i, '');
      title = title.replace(/\.+$/, '').trim();

      if (title.length > 0 && title !== 'New Chat') {
        if (title.length > 45) {
          title = title.slice(0, 42).trim() + '…';
        }

        const updated = await this.conversations.updateTitle(conversationId, title);
        if (updated) {
          this.logger.info(`AI generated title for conversation ${conversationId}: "${title}"`);
          this.broadcast({
            type: 'conversation_updated',
            payload: { conversationId, title },
            timestamp: Date.now(),
          });
          return title;
        }
      }
    } catch (err) {
      this.logger.warn(`AI conversation title generation failed: ${err}`);
    }
    return null;
  }

  public listen(port: number, host: string = '127.0.0.1'): Promise<void> {
    return new Promise((resolve) => {
      this.httpServer.listen(port, host, () => {
        this.logger.info(`Lofly Agent Server listening on http://${host}:${port} (ws://${host}:${port}/ws)`);
        resolve();
      });
    });
  }

  public close(): Promise<void> {
    return new Promise((resolve) => {
      this.wss.close(() => {
        this.httpServer.close(() => {
          resolve();
        });
      });
    });
  }
}
