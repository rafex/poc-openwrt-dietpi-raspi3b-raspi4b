/**
 * actions.ts — lógica de la página de acciones en tiempo real
 *
 * Muestra:
 * - Acciones ejecutadas por el AI (bloqueos, restricciones)
 * - Anomalías detectadas
 * - Dominios bloqueados
 * - Estadísticas de ejecución
 */

import '../scss/main.scss'
import { connectSse, onSseMessage } from './sse'

// ── Helpers DOM ───────────────────────────────────────────────────────────────

const el = <T extends HTMLElement>(id: string): T =>
  document.getElementById(id) as T

const qs = (sel: string, ctx: ParentNode = document): HTMLElement | null =>
  ctx.querySelector(sel)

interface Action {
  id: number
  batch_id: number
  timestamp: string
  action: string
  domain?: string
  reason?: string
  details?: Record<string, any>
  ssh_return_code?: number
}

interface Anomaly {
  id: number
  batch_id: number
  device_ip: string
  timestamp: string
  bytes_per_sec: number
  typical_bytes_per_sec: number
  stddev: number
  z_score: number
  description?: string
}

// ── Inicialización ────────────────────────────────────────────────────────────

function markActive(): void {
  qs(`a[data-page="actions"]`)?.classList.add('active')
}

export async function init(): Promise<void> {
  markActive()
  connectSse()

  // Cargar datos iniciales
  await Promise.all([
    loadActions(),
    loadAnomalies(),
    loadBlockedDomains(),
  ])

  // Conectar SSE para actualizaciones en vivo
  onSseMessage((event: any) => {
    if (event.event === 'action_executed') {
      handleNewAction(event)
      updateStats()
    }
    if (event.event === 'anomaly_detected') {
      handleNewAnomaly(event)
      updateStats()
    }
    logSseEvent(event)
  })

  // Refrescar cada 60 segundos
  setInterval(() => {
    loadActions()
    loadAnomalies()
  }, 60_000)

  // Button listeners
  el('btn-refresh-actions')?.addEventListener('click', loadActions)
  el('toggle-anomalies')?.addEventListener('change', (e) => {
    const section = el('anomalies-section')
    section.style.display = (e.target as HTMLInputElement).checked ? 'block' : 'none'
  })
}

// ── Estadísticas ──────────────────────────────────────────────────────────────

async function updateStats(): Promise<void> {
  try {
    const resp = await fetch('/api/actions?limit=100')
    const actions = await resp.json() as Action[]

    const blocks = actions.filter(a => a.action?.includes('block')).length
    const successes = actions.filter(a => a.ssh_return_code === 0).length
    const successRate = actions.length > 0 ? Math.round((successes / actions.length) * 100) : 0

    el('stat-blocks').textContent = String(blocks)
    el('stat-success-rate').textContent = String(successRate)
  } catch (e) {
    console.error('updateStats:', e)
  }
}

// ── Cargar acciones ───────────────────────────────────────────────────────────

async function loadActions(): Promise<void> {
  try {
    const resp = await fetch('/api/actions?limit=50')
    const data = await resp.json() as Action[]
    renderActions(data)
  } catch (e) {
    console.error('loadActions:', e)
  }
}

function renderActions(data: Action[]): void {
  const tbody = qs('#actions-table tbody')
  if (!tbody) return

  if (data.length === 0) {
    tbody.innerHTML = '<tr><td colspan="5" class="text-muted">— Sin acciones aún —</td></tr>'
    return
  }

  tbody.innerHTML = data.map(a => {
    const ts = new Date(a.timestamp).toLocaleString('es-MX', {
      year: '2-digit',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
    })

    const device = a.details?.target_ips?.[0] ?? a.details?.device_ip ?? a.domain ?? '—'
    const statusIcon = a.ssh_return_code === 0 ? '✅' : '❌'
    const actionBadge = `<span class="badge action-${sanitizeCss(a.action)}">${a.action}</span>`

    return `
      <tr>
        <td>${ts}</td>
        <td>${actionBadge}</td>
        <td><code style="font-size:0.85em">${device}</code></td>
        <td>${a.reason ?? '—'}</td>
        <td title="SSH code: ${a.ssh_return_code}">${statusIcon} ${a.ssh_return_code ?? '?'}</td>
      </tr>
    `
  }).join('')
}

function handleNewAction(event: any): void {
  const action: Action = {
    id: 0,
    batch_id: event.batch_id,
    timestamp: event.timestamp,
    action: event.action,
    details: event.details,
    ssh_return_code: event.details?.ssh_return_code,
  }

  // Insertar en la tabla (prepend)
  const tbody = qs('#actions-table tbody') as HTMLTableSectionElement | null
  if (tbody && tbody.children[0]?.textContent?.includes('Sin acciones')) {
    renderActions([action])
  } else if (tbody) {
    const row = tbody.insertRow(0)
    row.innerHTML = `
      <td>${new Date(event.timestamp).toLocaleTimeString('es-MX')}</td>
      <td><span class="badge action-${sanitizeCss(event.action)}">${event.action}</span></td>
      <td><code>${event.details?.target_ips?.[0] ?? event.details?.device_ip ?? '—'}</code></td>
      <td>${event.details?.reason ?? '—'}</td>
      <td>${event.details?.ssh_return_code === 0 ? '✅' : '❌'} ${event.details?.ssh_return_code ?? '?'}</td>
    `
  }
}

// ── Cargar anomalías ──────────────────────────────────────────────────────────

async function loadAnomalies(): Promise<void> {
  try {
    const resp = await fetch('/api/anomalies?limit=20')
    const data = await resp.json() as Anomaly[]
    renderAnomalies(data)
    updateAnomaliesCount(data.length)
  } catch (e) {
    console.error('loadAnomalies:', e)
  }
}

function renderAnomalies(data: Anomaly[]): void {
  const tbody = qs('#anomalies-table tbody')
  if (!tbody) return

  if (data.length === 0) {
    tbody.innerHTML = '<tr><td colspan="6" class="text-muted">— Sin anomalías aún —</td></tr>'
    return
  }

  tbody.innerHTML = data.map(a => {
    const ts = new Date(a.timestamp).toLocaleTimeString('es-MX')
    const typical = (a.typical_bytes_per_sec / 1e6).toFixed(1)
    const current = (a.bytes_per_sec / 1e6).toFixed(1)
    const zScore = a.z_score.toFixed(2)

    return `
      <tr>
        <td><code>${a.device_ip}</code></td>
        <td>${ts}</td>
        <td>${typical} MB/s</td>
        <td>${current} MB/s</td>
        <td>${zScore}σ</td>
        <td>${a.description ?? '—'}</td>
      </tr>
    `
  }).join('')
}

function handleNewAnomaly(event: any): void {
  const tbody = qs('#anomalies-table tbody') as HTMLTableSectionElement | null
  if (!tbody) return

  if (tbody.children[0]?.textContent?.includes('Sin anomalías')) {
    renderAnomalies([{
      id: 0,
      batch_id: event.batch_id,
      device_ip: event.device_ip,
      timestamp: event.timestamp,
      bytes_per_sec: event.bytes_per_sec,
      typical_bytes_per_sec: event.typical_bytes_per_sec,
      stddev: 0,
      z_score: event.z_score,
      description: event.description,
    }])
  } else {
    const row = tbody.insertRow(0)
    const typical = (event.typical_bytes_per_sec / 1e6).toFixed(1)
    const current = (event.bytes_per_sec / 1e6).toFixed(1)
    row.innerHTML = `
      <td><code>${event.device_ip}</code></td>
      <td>${new Date(event.timestamp).toLocaleTimeString('es-MX')}</td>
      <td>${typical} MB/s</td>
      <td>${current} MB/s</td>
      <td>${event.z_score.toFixed(2)}σ</td>
      <td>${event.description ?? '—'}</td>
    `
  }
}

function updateAnomaliesCount(count: number): void {
  el('stat-anomalies').textContent = String(count)
}

// ── Dominios bloqueados ───────────────────────────────────────────────────────

interface DomainCount {
  domain: string
  count: number
}

async function loadBlockedDomains(): Promise<void> {
  try {
    const resp = await fetch('/api/actions?limit=200')
    const actions = await resp.json() as Action[]

    const domains = new Map<string, number>()
    actions.forEach(a => {
      if (a.action?.includes('block') && a.domain) {
        domains.set(a.domain, (domains.get(a.domain) ?? 0) + 1)
      }
    })

    const sorted = Array.from(domains.entries())
      .map(([domain, count]) => ({ domain, count }))
      .sort((a, b) => b.count - a.count)
      .slice(0, 12)

    renderBlockedDomains(sorted)
    el('blocked-domains-count').textContent = String(domains.size)
  } catch (e) {
    console.error('loadBlockedDomains:', e)
  }
}

function renderBlockedDomains(data: DomainCount[]): void {
  const container = el('blocked-domains-chart')
  if (!container) return

  if (data.length === 0) {
    container.innerHTML = '<p class="text-muted">Sin dominios bloqueados en las últimas 24h</p>'
    return
  }

  container.innerHTML = data.map(d => `
    <div class="domain-block">
      <div class="domain-name">${d.domain}</div>
      <div class="domain-count">${d.count}</div>
    </div>
  `).join('')
}

// ── SSE logging ───────────────────────────────────────────────────────────────

function logSseEvent(event: any): void {
  const log = el('sse-log')
  if (!log) return

  const time = new Date().toLocaleTimeString('es-MX')
  const eventType = event.event ?? 'unknown'
  const line = document.createElement('div')
  line.className = `log-line log-${sanitizeCss(eventType)}`
  line.innerHTML = `<span class="log-time">[${time}]</span> <strong>${eventType}:</strong> ${JSON.stringify(event).substring(0, 100)}`

  log.insertBefore(line, log.firstChild)

  // Limitar a últimas 50 líneas
  while (log.children.length > 50) {
    log.removeChild(log.lastChild!)
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

function sanitizeCss(str: string): string {
  return str.toLowerCase().replace(/[^a-z0-9-]/g, '-')
}

// Iniciar cuando el DOM está listo
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', init)
} else {
  init()
}
