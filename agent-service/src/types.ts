export type ConversationStatus = "active" | "archived";
export type MessageRole = "user" | "assistant" | "system";
export type MessageStatus = "queued" | "streaming" | "completed" | "failed";

export interface Principal {
  userId: string;
  ledgerId: string;
  deviceId: string;
}

export interface AgentConversation {
  id: string;
  userId: string;
  ledgerId: string;
  title: string;
  isPrimary: boolean;
  status: ConversationStatus;
  selectedModelId?: string;
  piSessionFile?: string;
  createdAt: string;
  updatedAt: string;
}

export interface AgentMessage {
  id: string;
  conversationId: string;
  role: MessageRole;
  text: string;
  status: MessageStatus;
  runId?: string;
  createdAt: string;
  completedAt?: string;
  errorCode?: string;
  attachmentIds?: string[];
}

export interface AgentAttachment {
  id: string;
  userId: string;
  ledgerId: string;
  fileName: string;
  mimeType: string;
  sizeBytes: number;
  sha256: string;
  originalPath: string;
  workingPath: string;
  createdAt: string;
}

export interface AgentEvent {
  cursor: number;
  conversationId: string;
  type: string;
  data: Record<string, unknown>;
  createdAt: string;
}

export interface AgentIdempotencyRecord {
  key: string;
  operation: string;
  requestHash: string;
  response: unknown;
  createdAt: string;
}

export interface AgentMemory {
  id: string;
  userId: string;
  ledgerId: string;
  content: string;
  reason: string;
  status: "suggested" | "active" | "rejected";
  createdAt: string;
  updatedAt: string;
}

export interface AgentQuoteCandidate {
  id: string;
  userId: string;
  ledgerId: string;
  kind: "instrument" | "fx";
  instrumentId?: string;
  price?: string;
  currency?: string;
  baseCurrency?: string;
  quoteCurrency?: string;
  rate?: string;
  asOf: string;
  source: string;
  sourceUrl: string;
  status: "suggested" | "applied" | "rejected";
  createdAt: string;
  updatedAt: string;
  appliedAt?: string;
}

export interface AgentQuoteWriter {
  applyQuoteCandidate(candidate: AgentQuoteCandidate): Promise<unknown>;
}

export type AgentAutomationKind =
  | "quote_refresh"
  | "subscription_due_scan"
  | "dca_due_check"
  | "financial_summary";

export interface AgentAutomation {
  id: string;
  userId: string;
  ledgerId: string;
  deviceId: string;
  kind: AgentAutomationKind;
  intervalHours: number;
  enabled: boolean;
  nextRunAt: string;
  lastRunAt?: string;
  lastStatus?: "success" | "failed";
  lastErrorCode?: string;
  createdAt: string;
  updatedAt: string;
}

export interface AgentNotification {
  id: string;
  userId: string;
  ledgerId: string;
  kind: AgentAutomationKind;
  title: string;
  body: string;
  action?: "review" | "quotes" | "dca" | "agent";
  createdAt: string;
  readAt?: string;
}

export interface AgentAutomationResult {
  title: string;
  body: string;
  action?: AgentNotification["action"];
  notify: boolean;
}

export interface AgentAutomationRunner {
  runAutomation(automation: AgentAutomation, scheduledFor: string): Promise<AgentAutomationResult>;
}

export interface UserState {
  schemaVersion: 1;
  conversations: AgentConversation[];
  messages: AgentMessage[];
  events: AgentEvent[];
  attachments: AgentAttachment[];
  memories: AgentMemory[];
  quoteCandidates: AgentQuoteCandidate[];
  automations: AgentAutomation[];
  notifications: AgentNotification[];
  idempotency: AgentIdempotencyRecord[];
  nextEventCursor: number;
}

export interface AgentModelInfo {
  id: string;
  provider: string;
  displayName: string;
  supportsImages: boolean;
}

export interface AgentProviderInfo {
  id: string;
  displayName: string;
  authMethods: Array<"oauth" | "api_key">;
  connectionStatus: "connected" | "disconnected" | "connecting";
}

export interface AgentProviderOAuthAttempt {
  attemptId: string;
  providerId: string;
  status: "pending" | "connected" | "failed" | "cancelled";
  verificationUri?: string;
  userCode?: string;
  expiresAt?: string;
  errorCode?: string;
}

export interface AgentProviderManager {
  listProviders(): Promise<AgentProviderInfo[]>;
  startOAuth(providerId: string): Promise<AgentProviderOAuthAttempt>;
  getOAuthAttempt(attemptId: string): AgentProviderOAuthAttempt;
  disconnect(providerId: string): Promise<void>;
}

export interface RunCallbacks {
  onDelta(delta: string): void;
  onToolStarted(name: string): void;
  onToolCompleted(name: string, isError: boolean): void;
}

export interface AgentEngine {
  listModels(): Promise<AgentModelInfo[]>;
  run(
    conversation: AgentConversation,
    text: string,
    attachments: AgentAttachment[],
    callbacks: RunCallbacks,
  ): Promise<{ text: string; piSessionFile?: string }>;
  cancel(conversationId: string): Promise<boolean>;
}
