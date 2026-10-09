/**
 * Lofly — Core Types & Contracts
 */

// ============================================================================
// Assistant States & Lifecycle
// ============================================================================

export type AssistantState =
  | 'idle'
  | 'listening'
  | 'thinking'
  | 'executing'
  | 'speaking'
  | 'error';

export interface StateChangeEvent {
  previousState: AssistantState;
  newState: AssistantState;
  timestamp: number;
  metadata?: Record<string, unknown>;
}

// ============================================================================
// Security & Permission Levels
// ============================================================================

/**
 * SAFE: Read-only operations, screenshots, searches, safe app opening.
 * SENSITIVE: File modifications, standard terminal commands, message sending.
 * DANGEROUS: System configuration, file deletions, destructive terminal commands.
 */
export const PermissionLevel = {
  SAFE: 'SAFE',
  SENSITIVE: 'SENSITIVE',
  DANGEROUS: 'DANGEROUS',
} as const;

export type PermissionLevel = (typeof PermissionLevel)[keyof typeof PermissionLevel];

export type Tool<TArgs = unknown, TResult = unknown> = {
  name: string;
  description: string;
  inputSchema: unknown;
  permission: PermissionLevel;
  execute(args: TArgs): Promise<ToolResult<TResult>>;
};

export interface ConfirmationRequest {
  id: string;
  toolName: string;
  parameters: Record<string, unknown>;
  permissionLevel: PermissionLevel;
  description: string;
  timestamp: number;
}

export interface ConfirmationResponse {
  id: string;
  approved: boolean;
  reason?: string;
  timestamp: number;
}

// ============================================================================
// Tool System Definitions
// ============================================================================

export type JSONSchemaType = 'string' | 'number' | 'integer' | 'boolean' | 'object' | 'array' | 'null';

export interface ToolParameterProperty {
  type: JSONSchemaType;
  description: string;
  enum?: string[];
  default?: unknown;
  items?: ToolParameterProperty;
  minLength?: number;
  maxLength?: number;
  minimum?: number;
  maximum?: number;
}

export interface ToolParametersSchema {
  type: 'object';
  properties: Record<string, ToolParameterProperty>;
  required?: string[];
}

// ============================================================================
// Conversations, Tasks & Activity
// ============================================================================

export type ConversationMessageRole = 'user' | 'assistant' | 'system';

/**
 * One high-level step the agent reports. Deliberately coarser than a tool
 * call: the UI shows intent ("Reading package.json"), never raw payloads or
 * model reasoning.
 */
export interface TaskStep {
  id: string;
  label: string;
  state: 'pending' | 'running' | 'completed' | 'failed' | 'cancelled' | 'skipped';
  toolName?: string;
  error?: string;
}

export interface TaskSnapshot {
  id: string;
  conversationId: string;
  title: string;
  status: TaskStatus;
  steps: TaskStep[];
  createdAt: number;
  updatedAt: number;
}

export interface ConversationMessage {
  id: string;
  role: ConversationMessageRole;
  text: string;
  createdAt: number;
  /** Present on assistant messages that drove tools. */
  taskId?: string;
  error?: string;
}

export interface Conversation {
  id: string;
  title: string;
  createdAt: number;
  updatedAt: number;
  /**
   * Monotonic insertion counter. Wall-clock timestamps collide when several
   * conversations are created in the same millisecond, so ordering and
   * pagination rely on this instead.
   */
  seq: number;
  messages: ConversationMessage[];
  taskReferences: string[];
}

export type ActivityStatus = 'success' | 'failure' | 'cancelled' | 'simulated';

export interface ActivityEntry {
  id: string;
  timestamp: number;
  taskId?: string;
  conversationId?: string;
  label: string;
  toolName?: string;
  status: ActivityStatus;
  detail?: string;
  /**
   * True when the execution policy simulated the action. Surfaced verbatim in
   * the UI so a dry run is never presented as a completed action.
   */
  dryRun: boolean;
}

export type IntegrationStatus =
  | 'connected'
  | 'not_connected'
  | 'needs_authentication'
  | 'needs_permission'
  | 'error';

export interface IntegrationDescriptor {
  id: string;
  name: string;
  category: 'messaging' | 'browser' | 'music' | 'developer' | 'system';
  status: IntegrationStatus;
  /** Non-sensitive human explanation of what is missing. Never a secret. */
  detail?: string;
}

export interface AccountSession {
  signedIn: boolean;
  displayName?: string;
  /** Where the token lives. The token itself is never sent to the client. */
  storage: 'keychain' | 'none';
  updatedAt?: number;
}

// ============================================================================
// Side-Effect Classification & Safe Execution
// ============================================================================

/**
 * Declares how far a tool reaches outside the process.
 *
 * none:        read-only observation (screenshot, list_directory, inspect_ui)
 * reversible:  locally reversible state (move_file, open_app, set_volume)
 * external:    reaches another person or service (send_whatsapp_message, web_search)
 * destructive: irreversible local damage (delete_file, run_command with rm -rf)
 */
export type SideEffectLevel = 'none' | 'reversible' | 'external' | 'destructive';

export interface ToolSafetyMetadata {
  sideEffect: SideEffectLevel;
  supportsDryRun: boolean;
  supportsSandbox: boolean;
}

/**
 * dry_run: simulate the action, perform no external side effect
 * sandbox: execute against an explicitly isolated resource
 * live:     perform the real side effect
 */
export type ExecutionMode = 'dry_run' | 'sandbox' | 'live';

export interface ExecutionPolicy {
  mode: ExecutionMode;
  safeTestMode: boolean;
  liveSideEffects: boolean;
  sandboxRoot: string;
  /** Set when SAFE_TEST_MODE / LIVE_SIDE_EFFECTS were declared inconsistently. */
  configError?: string;
}

/**
 * Every simulated result carries this so a caller can never mistake a
 * simulation for a real execution.
 */
export interface ExecutionStatus {
  mode: ExecutionMode;
  executed: boolean;
  dryRun: boolean;
}

export interface ToolDefinition<TParams = Record<string, unknown>, TResult = unknown> {
  name: string;
  description: string;
  parameters: ToolParametersSchema;
  permissionLevel: PermissionLevel;
  /** Declares the tool's side-effect class. Defaults to `external` when omitted. */
  safety?: ToolSafetyMetadata;
  execute: (params: TParams, context: ToolExecutionContext) => Promise<ToolResult<TResult>>;
  validate?: (params: unknown) => { valid: boolean; error?: string };
}

export interface ToolExecutionContext {
  requestId: string;
  requestConfirmation?: (req: Omit<ConfirmationRequest, 'id' | 'timestamp'>) => Promise<boolean>;
  logger: Logger;
  /** Resolved policy for the current process. Tools must honour this themselves. */
  policy: ExecutionPolicy;
}

export interface ToolCallRequest {
  id: string;
  name: string;
  parameters: Record<string, unknown>;
}

export interface ToolResult<T = unknown> {
  success: boolean;
  data?: T;
  error?: string;
  metadata?: Record<string, unknown>;
}

export interface ExecutedToolCall {
  id: string;
  name: string;
  parameters: Record<string, unknown>;
  result: ToolResult;
  durationMs: number;
}

// ============================================================================
// Agent & Conversation
// ============================================================================

export type MessageRole = 'system' | 'user' | 'assistant' | 'tool';

export interface ChatMessageToolCall {
  id: string;
  type: 'function';
  function: {
    name: string;
    arguments: string; // JSON encoded string
  };
}

export interface ChatMessage {
  role: MessageRole;
  content: string | null;
  name?: string;
  tool_call_id?: string;
  tool_calls?: ChatMessageToolCall[];
}

export interface AgentStep {
  stepIndex: number;
  thought?: string;
  toolCalls?: ToolCallRequest[];
  toolResults?: ExecutedToolCall[];
  response?: string;
}

export interface AgentRunOptions {
  requestId?: string;
  voiceSessionId?: string;
  maxSteps?: number;
  temperature?: number;
  context?: Record<string, unknown>;
  reasoningLevel?: 'low' | 'medium' | 'high';
  attachments?: string[];
  onChunk?: (chunk: string) => void;
  signal?: AbortSignal;
  /** Observes the fast-router decision (STT diagnostics). */
  onRoute?: (route: { matched: boolean; toolDomain?: string; tools: string[] }) => void;
  /** Observes transcript validation/normalization of voice input (STT diagnostics). */
  onTranscriptProcessed?: (processed: ProcessedTranscript) => void;
}

export interface AgentRunResult {
  text: string;
  steps: AgentStep[];
  completed: boolean;
  error?: string;
  rawTranscript?: string;
  normalizedTranscript?: string;
}

// ============================================================================
// Provider Interfaces
// ============================================================================

export interface LLMCompletionOptions {
  messages: ChatMessage[];
  tools?: ToolDefinition[];
  temperature?: number;
  maxTokens?: number;
  onChunk?: (chunk: string) => void;
  signal?: AbortSignal;
}

export interface LLMCompletionResponse {
  content: string | null;
  toolCalls?: ToolCallRequest[];
  rawResponse?: unknown;
}

export interface LLMProvider {
  name: string;
  model?: string;
  baseUrl?: string;
  complete: (options: LLMCompletionOptions) => Promise<LLMCompletionResponse>;
}

export interface STTOptions {
  language?: string; // e.g. "id-ID" or "en-US"
  sampleRate?: number;
}

export interface STTResult {
  text: string;
  confidence?: number;
  language?: string;
}

export interface SpeechToTextProvider {
  name: string;
  transcribe: (audioBuffer: Buffer | ArrayBuffer, options?: STTOptions) => Promise<STTResult>;
}

export interface TTSOptions {
  voice?: string;
  language?: string;
  speed?: number;
}

export interface TextToSpeechProvider {
  name: string;
  synthesize: (text: string, options?: TTSOptions) => Promise<Buffer | null>;
  speak?: (text: string, options?: TTSOptions) => Promise<void>;
}

export interface WakeWordDetector {
  name: string;
  start: (onWake: () => void) => Promise<void> | void;
  stop: () => Promise<void> | void;
  isListening: () => boolean;
}

// ============================================================================
// Memory & Persistence
// ============================================================================

export interface MemoryItem {
  id: string;
  category: 'preference' | 'fact' | 'project' | 'instruction';
  content: string;
  createdAt: number;
  updatedAt: number;
  metadata?: Record<string, unknown>;
}

export interface MemoryStore {
  save: (item: Omit<MemoryItem, 'id' | 'createdAt' | 'updatedAt'>) => Promise<MemoryItem>;
  get: (id: string) => Promise<MemoryItem | null>;
  search: (query: string, category?: string) => Promise<MemoryItem[]>;
  /** Edits an item in place. The id and createdAt are preserved. */
  update: (
    id: string,
    patch: Partial<Pick<MemoryItem, 'content' | 'category' | 'metadata'>>
  ) => Promise<MemoryItem | null>;
  delete: (id: string) => Promise<boolean>;
  list: () => Promise<MemoryItem[]>;
}

// ============================================================================
// Logging
// ============================================================================

export type LogLevel = 'debug' | 'info' | 'warn' | 'error';

export interface Logger {
  debug: (message: string, meta?: Record<string, unknown>) => void;
  info: (message: string, meta?: Record<string, unknown>) => void;
  warn: (message: string, meta?: Record<string, unknown>) => void;
  error: (message: string, meta?: Record<string, unknown>) => void;
}

// ============================================================================
// Real-time Event Stream (WebSocket / IPC)
// ============================================================================

export type AssistantEventType =
  | 'state_change'
  | 'wake_word'
  | 'transcription'
  | 'thought'
  | 'tool_start'
  | 'tool_end'
  | 'confirmation_required'
  | 'confirmation_received'
  | 'speech_start'
  | 'speech_end'
  | 'task_update'
  | 'activity'
  | 'conversation_updated'
  | 'stream_chunk'
  | 'stream_end'
  | 'error';

export interface AssistantEvent<T = unknown> {
  type: AssistantEventType;
  payload: T;
  timestamp: number;
}

// ============================================================================
// Computer Use & UI Inspection Types
// ============================================================================

export interface UIElement {
  role: string;
  title?: string;
  value?: string;
  description?: string;
  frame?: { x: number; y: number; width: number; height: number };
  actions?: string[];
  children?: UIElement[];
  focused?: boolean;
  enabled?: boolean;
}

export interface TaskObservation {
  timestamp: number;
  type: 'screen' | 'ui' | 'app_state' | 'command_output' | 'error' | 'verification';
  data: unknown;
}

export interface TaskAction {
  timestamp: number;
  name: string;
  parameters: Record<string, unknown>;
}

/**
 * Authoritative task lifecycle, shared by the notch and the desktop app.
 *
 * `pending`/`in_progress` are retained from the original computer-use model so
 * existing consumers keep working; they are treated as equivalents of
 * `queued`/`executing`.
 */
export type TaskStatus =
  | 'queued'
  | 'planning'
  | 'executing'
  | 'waiting'
  | 'completed'
  | 'failed'
  | 'cancelled'
  | 'requires_foreground'
  | 'pending'
  | 'in_progress';

/** States in which a task can still make progress. */
export const ACTIVE_TASK_STATUSES: TaskStatus[] = [
  'queued',
  'planning',
  'executing',
  'waiting',
  'requires_foreground',
  'pending',
  'in_progress',
];

/** States a task can never leave on its own. */
export const TERMINAL_TASK_STATUSES: TaskStatus[] = ['completed', 'failed', 'cancelled'];

export interface TaskContext {
  taskId: string;
  goal: string;
  currentApp?: string;
  observations: TaskObservation[];
  actions: TaskAction[];
  results: ToolResult[];
  status: TaskStatus;
}

export interface VerificationResult {
  verified: boolean;
  action: string;
  target?: string;
  details: string;
}

// ============================================================================
// Transcript & Voice Pipeline Types
// ============================================================================

export interface TranscriptCorrection {
  from: string;
  to: string;
  reason: string;
}

export interface ProcessedTranscript {
  rawTranscript: string;
  normalizedTranscript: string;
  confidence: number;
  detectedLanguage: 'id' | 'en' | 'mixed';
  isValid: boolean;
  validationReason?: string;
  hasCorrections: boolean;
  corrections: TranscriptCorrection[];
}

// ============================================================================
// Structured Intent & Messaging Command Pipeline
// ============================================================================

export type StructuredActionIntent =
  | {
      intent: 'send_whatsapp_message';
      recipient: string;
      message: string;
      rawMarker?: string;
      isDynamicGeneration?: boolean;
    }
  | {
      intent: 'open_whatsapp_chat';
      recipient: string;
      messageMissing?: boolean;
    }
  | {
      intent: 'open_app';
      app: string;
    }
  | {
      intent: 'play_music';
      query: string;
      app?: string;
    }
  | {
      intent: 'unknown';
      query: string;
    };

export interface WhatsAppIntentValidation {
  valid: boolean;
  reason?: 'recipient_missing' | 'message_missing' | 'invalid_intent' | 'ok';
  recipient?: string;
  message?: string;
}

export interface WhatsAppContact {
  name: string;
  phone?: string;
}

export interface WhatsAppMessageResult {
  recipient: string;
  text: string;
  sent: boolean;
  verified: boolean;
  details: string;
  /** Present on every simulated result; absent on genuine live sends. */
  mode?: ExecutionMode;
  dryRun?: boolean;
  executed?: boolean;
}

/**
 * The single seam every WhatsApp action passes through. Live and simulated
 * implementations share the same validation and result schema, so production
 * behaviour cannot diverge from what tests exercise.
 */
export interface WhatsAppExecutor {
  readonly mode: ExecutionMode;
  openWhatsApp(): Promise<{ target: 'app' | 'web'; message: string }>;
  searchContact(contactName: string): Promise<{ success: boolean; message: string }>;
  openChat(contact: string, phone?: string): Promise<{ success: boolean; message: string }>;
  sendMessage(contactName: string, text: string): Promise<WhatsAppMessageResult>;
}

export interface CommandParseResult {
  rawTranscript: string;
  normalizedTranscript: string;
  actions: StructuredActionIntent[];
  isStructured: boolean;
  primaryIntent?: StructuredActionIntent;
  validation?: WhatsAppIntentValidation;
}

export interface CommandTrace {
  rawTranscript: string;
  parsedIntent: StructuredActionIntent | StructuredActionIntent[];
  validation: {
    recipient: 'valid' | 'missing' | 'empty';
    message: 'valid' | 'missing' | 'empty' | 'na';
    reason?: string;
  };
  contactResolution?: {
    query: string;
    resolved: boolean;
    contactName?: string;
  };
  execution?: {
    tool: string;
    parameters: Record<string, unknown>;
  };
  result?: {
    success: boolean;
    details?: string;
  };
}
