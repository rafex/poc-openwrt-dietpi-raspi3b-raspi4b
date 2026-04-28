/**
 * api.ts — cliente REST para el backend Java (:5000 → proxied at /api/)
 */

const BASE = '/api'

export interface Analysis {
  id: number
  batch_id: number
  timestamp: string
  risk_level: string
  summary: string
  meta?: string
}

export interface Alert {
  id: number
  timestamp: string
  severity: string
  message: string
  device_ip?: string
  meta?: string
}

export interface HealthStatus {
  status: string
  groq_enabled: boolean
  llama_url: string
  mqtt_connected: boolean
  db_ok: boolean
  uptime_s: number
}

export interface Stats {
  batches_today: number
  alerts_active: number
  devices_seen: number
  groq_enabled: boolean
}

export interface ChatRequest {
  session_id: string
  message: string
}

export interface ChatResponse {
  reply: string
  session_id: string
}

export interface WhitelistEntry {
  domain: string
  added_at: string
}

export interface Rule {
  key: string
  value: string
  updated_at: string
}

export interface Summary {
  id: number
  timestamp: string
  summary: string
  meta?: string
}

export interface Report {
  id: number
  timestamp: string
  report: string
  meta?: string
}

async function request<T>(
  path: string,
  options?: RequestInit,
): Promise<T> {
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

export const getHealth = (): Promise<HealthStatus> =>
  fetch('/health').then(r => r.json())

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

// ── Whitelist ─────────────────────────────────────────────────────────────────

export const getWhitelist = (): Promise<WhitelistEntry[]> =>
  request<WhitelistEntry[]>('/whitelist')

export const addWhitelist = (domain: string): Promise<{ ok: boolean }> =>
  request<{ ok: boolean }>('/whitelist', {
    method: 'POST',
    body: JSON.stringify({ domain }),
  })

export const removeWhitelist = (domain: string): Promise<{ ok: boolean }> =>
  request<{ ok: boolean }>('/whitelist', {
    method: 'DELETE',
    body: JSON.stringify({ domain }),
  })

// ── Rules ─────────────────────────────────────────────────────────────────────

export const getRules = (): Promise<Rule[]> =>
  request<Rule[]>('/rules')

export const saveRule = (key: string, value: string): Promise<{ ok: boolean }> =>
  request<{ ok: boolean }>('/rules', {
    method: 'POST',
    body: JSON.stringify({ key, value }),
  })

export const deleteRule = (key: string): Promise<{ ok: boolean }> =>
  request<{ ok: boolean }>('/rules', {
    method: 'DELETE',
    body: JSON.stringify({ key }),
  })

// ── Summaries & Reports ───────────────────────────────────────────────────────

export const getSummaries = (limit = 10): Promise<Summary[]> =>
  request<Summary[]>(`/summaries?limit=${limit}`)

export const getReports = (limit = 10): Promise<Report[]> =>
  request<Report[]>(`/reports?limit=${limit}`)
