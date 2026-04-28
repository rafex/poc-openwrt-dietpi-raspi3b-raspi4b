/**
 * dashboard.ts — lógica de la página principal
 */
import '../scss/main.scss'
import { connectSse, onSseMessage } from './sse'
import {
  getHealth, getStats, getAnalyses, getAlerts,
  type Analysis, type Alert,
} from './api'

// ── Helpers DOM ───────────────────────────────────────────────────────────────

const el = <T extends HTMLElement>(id: string): T =>
  document.getElementById(id) as T

const qs = (sel: string, ctx: ParentNode = document): HTMLElement | null =>
  ctx.querySelector(sel)

function markActive(): void {
  qs(`a[data-page="dashboard"]`)?.classList.add('active')
}

// ── Stats ─────────────────────────────────────────────────────────────────────

async function loadStats(): Promise<void> {
  try {
    const h = await getHealth()
    el('stat-groq').textContent = h.groq_enabled ? '✅ Sí' : '❌ No'

    const s = await getStats()
    el('stat-batches').textContent  = String(s.batches_today)
    el('stat-alerts').textContent   = String(s.alerts_active)
    el('stat-devices').textContent  = String(s.devices_seen)
  } catch (e) {
    console.error('loadStats:', e)
  }
}

// ── Analyses table ────────────────────────────────────────────────────────────

function riskBadge(risk: string): string {
  const r = risk.toLowerCase()
  return `<span class="badge ${r}">${risk}</span>`
}

function renderAnalyses(data: Analysis[]): void {
  const tbody = document.querySelector<HTMLTableSectionElement>('#analyses-table tbody')
    ?? (() => {
      const t = document.createElement('tbody')
      el('analyses-table').appendChild(t)
      return t
    })()

  if (data.length === 0) {
    tbody.innerHTML = '<tr><td colspan="4" style="color:var(--c-muted,#8b949e)">Sin datos</td></tr>'
    return
  }

  tbody.innerHTML = data.map(a => `
    <tr>
      <td>${a.batch_id}</td>
      <td>${a.timestamp}</td>
      <td>${riskBadge(a.risk_level)}</td>
      <td>${a.summary ?? '—'}</td>
    </tr>
  `).join('')
}

async function loadAnalyses(): Promise<void> {
  try {
    const data = await getAnalyses(15)
    renderAnalyses(data)
  } catch (e) {
    console.error('loadAnalyses:', e)
  }
}

// ── Alerts table ──────────────────────────────────────────────────────────────

function renderAlerts(data: Alert[]): void {
  const tbody = document.querySelector<HTMLTableSectionElement>('#alerts-table tbody')
    ?? (() => {
      const t = document.createElement('tbody')
      el('alerts-table').appendChild(t)
      return t
    })()

  if (data.length === 0) {
    tbody.innerHTML = '<tr><td colspan="4" style="color:var(--c-muted,#8b949e)">Sin alertas</td></tr>'
    return
  }

  tbody.innerHTML = data.map(a => `
    <tr>
      <td>${riskBadge(a.severity)}</td>
      <td>${a.timestamp}</td>
      <td>${a.message}</td>
      <td>${a.device_ip ?? '—'}</td>
    </tr>
  `).join('')
}

async function loadAlerts(): Promise<void> {
  try {
    const data = await getAlerts(15)
    renderAlerts(data)
  } catch (e) {
    console.error('loadAlerts:', e)
  }
}

// ── SSE log ───────────────────────────────────────────────────────────────────

function appendSseLine(text: string): void {
  const box = el('sse-log')
  const line = document.createElement('div')
  line.className = 'log-line'
  line.textContent = `[${new Date().toLocaleTimeString()}] ${text}`
  box.appendChild(line)
  box.scrollTop = box.scrollHeight
  // Mantener máx. 200 líneas
  while (box.children.length > 200) {
    box.removeChild(box.firstChild!)
  }
}

// ── Init ──────────────────────────────────────────────────────────────────────

function init(): void {
  markActive()

  void loadStats()
  void loadAnalyses()
  void loadAlerts()

  el('btn-refresh-analyses').addEventListener('click', () => {
    void loadAnalyses()
    void loadAlerts()
  })

  connectSse()
  onSseMessage(data => appendSseLine(data))

  // Refresco automático cada 30s
  setInterval(() => {
    void loadStats()
    void loadAnalyses()
    void loadAlerts()
  }, 30_000)
}

document.addEventListener('DOMContentLoaded', init)
