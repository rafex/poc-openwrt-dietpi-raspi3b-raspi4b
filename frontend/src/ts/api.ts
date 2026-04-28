/**
 * api.ts — cliente REST tipado para el backend Java.
 *
 * En producción las llamadas van a /api/* que nginx proxifica a :5000.
 * En desarrollo, vite.config.ts configura el proxy al mismo destino.
 * En ambos casos el frontend usa URLs relativas — sin hardcodear IPs.
 */

const BASE = '/api'

// ── Interfaces — alineadas con ApiServer.java ─────────────────────────────────

/** GET /health */
export interface HealthStatus {
  status:          string
  started_at:      string
  mqtt_connected:  boolean
  groq_enabled:    boolean
  chat_provider:   string   // "groq" | "llama"
  llama_url:       string
  db_path:         string
  batches_total:   number
  analyses_total:  number
  queue_pending:   number
  analyses_ok:     number
  analyses_error:  number
}

/** GET /api/stats */
export interface Stats {
  batches_total:      number
  batches_pending:    number
  analyses_total:     number
  analyses_by_risk:   string   // JSON object — parsear si se necesita desglose
  alerts_by_severity: string   // JSON object — parsear si se necesita desglose
  analyses_ok:        number
  analyses_error:     number
  llama_calls:        number
  llama_errors:       number
}

/** GET /api/analyses */
export interface Analysis {
  id:         number
  batch_id:   number
  timestamp:  string
  risk_level: string
  summary:    string
  meta?:      string
}

/** GET /api/alerts */
export interface Alert {
  id:        number
  timestamp: string
  severity:  string
  message:   string
  device_ip?: string
  meta?:     string
}

/**
 * POST /api/chat
 * Campo `question` — nombre que espera el backend Java en handleChat().
 */
export interface ChatRequest {
  session_id: string
  question:   string
}

/**
 * Respuesta de POST /api/chat
 * Campo `answer` — nombre que devuelve el backend Java.
 */
export interface ChatResponse {
  session_id: string
  answer:     string
  provider:   string   // "groq" | "llama"
}

/** GET /api/whitelist */
export interface WhitelistEntry {
  domain:   string
  reason?:  string
  added_at: string
}

/** GET /api/profiles */
export interface DeviceProfile {
  device_ip:    string
  device_type?: string
  last_seen:    string
  meta?:        string
}

/** GET /api/summaries */
export interface Summary {
  id:        number
  timestamp: string
  summary:   string
  meta?:     string
}

/** GET /api/reports */
export interface Report {
  id:        number
  timestamp: string
  report:    string
  meta?:     string
}

// ── HTTP helper ───────────────────────────────────────────────────────────────

async function request<T>(path: string, options?: RequestInit): Promise<T> {
  const res = await fetch(`${BASE}${path}`, {
    headers: { 'Content-Type': 'application/json', ...(options?.headers ?? {}) },
    ...options,
  })
  if (!res.ok) {
    const text = await res.text().catch(() => res.statusText)
    throw new Error(`HTTP ${res.status}: ${text}`)
  }
  return res.json() as Promise<T>
}

// ── Health ────────────────────────────────────────────────────────────────────

/** Llama a /health directamente (no bajo /api/). */
export const getHealth = (): Promise<HealthStatus> =>
  fetch('/health').then(r => {
    if (!r.ok) throw new Error(`HTTP ${r.status}`)
    return r.json() as Promise<HealthStatus>
  })

// ── Stats ─────────────────────────────────────────────────────────────────────

export const getStats = (): Promise<Stats> =>
  request<Stats>('/stats')

// ── Analyses ──────────────────────────────────────────────────────────────────

export const getAnalyses = (limit = 20): Promise<Analysis[]> =>
  request<Analysis[]>(`/analyses?limit=${limit}`)

// ── Alerts ────────────────────────────────────────────────────────────────────

export const getAlerts = (limit = 20): Promise<Alert[]> =>
  request<Alert[]>(`/alerts?limit=${limit}`)

// ── Chat ──────────────────────────────────────────────────────────────────────

export const sendChat = (body: ChatRequest): Promise<ChatResponse> =>
  request<ChatResponse>('/chat', { method: 'POST', body: JSON.stringify(body) })

export const getChatHistory = (sessionId: string): Promise<unknown[]> =>
  request<unknown[]>(`/chat/history?session_id=${encodeURIComponent(sessionId)}`)

export const clearChatSession = (sessionId: string): Promise<{ ok: string }> =>
  request<{ ok: string }>(`/chat/session?session_id=${encodeURIComponent(sessionId)}`, {
    method: 'DELETE',
  })

// ── Whitelist ─────────────────────────────────────────────────────────────────

export const getWhitelist = (): Promise<WhitelistEntry[]> =>
  request<WhitelistEntry[]>('/whitelist')

export const addWhitelist = (
  domain: string,
  reason?: string,
): Promise<{ ok: string }> =>
  request<{ ok: string }>('/whitelist', {
    method: 'POST',
    body:   JSON.stringify({ domain, reason: reason ?? '' }),
  })

/**
 * DELETE /api/whitelist?domain=xxx
 * El backend Java lee el dominio desde query param, no desde body.
 */
export const removeWhitelist = (domain: string): Promise<{ ok: string }> =>
  request<{ ok: string }>(`/whitelist?domain=${encodeURIComponent(domain)}`, {
    method: 'DELETE',
  })

// ── Device profiles ───────────────────────────────────────────────────────────

export const getProfiles = (): Promise<DeviceProfile[]> =>
  request<DeviceProfile[]>('/profiles')

// ── Summaries & Reports ───────────────────────────────────────────────────────

export const getSummaries = (limit = 10): Promise<Summary[]> =>
  request<Summary[]>(`/summaries?limit=${limit}`)

export const getReports = (limit = 10): Promise<Report[]> =>
  request<Report[]>(`/reports?limit=${limit}`)

// ── AI Rules ──────────────────────────────────────────────────────────────────
// Nota: el backend Java no implementa aún /api/rules.
// Las funciones devuelven arrays vacíos sin lanzar error para no romper la UI.

export interface Rule {
  key:        string
  value:      string
  updated_at: string
}

export const getRules = async (): Promise<Rule[]> => {
  try {
    return await request<Rule[]>('/rules')
  } catch {
    return []
  }
}

export const saveRule = async (
  key: string,
  value: string,
): Promise<{ ok: string }> => {
  try {
    return await request<{ ok: string }>('/rules', {
      method: 'POST',
      body:   JSON.stringify({ key, value }),
    })
  } catch {
    return { ok: 'no implementado' }
  }
}

export const deleteRule = async (key: string): Promise<{ ok: string }> => {
  try {
    return await request<{ ok: string }>(`/rules?key=${encodeURIComponent(key)}`, {
      method: 'DELETE',
    })
  } catch {
    return { ok: 'no implementado' }
  }
}
