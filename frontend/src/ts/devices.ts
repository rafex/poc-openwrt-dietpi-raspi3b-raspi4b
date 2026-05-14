/**
 * devices.ts — Página de perfiles de dispositivos
 *
 * Muestra:
 * - Perfiles heurísticos de dispositivos (iOS, Android, Smart TV, IoT, Laptop)
 * - Confianza de clasificación con barra visual
 * - Indicadores clave (dominios) que determinaron la clasificación
 * - Distribución por tipo en gráfico de tarjetas
 * - Estadísticas de conteo por tipo
 */

import '../scss/main.scss'
import { connectSse, onSseMessage } from './sse'

// ── Helpers DOM ───────────────────────────────────────────────────────────────

const el = <T extends HTMLElement>(id: string): T =>
  document.getElementById(id) as T

const qs = (sel: string, ctx: ParentNode = document): HTMLElement | null =>
  ctx.querySelector(sel)

// ── Tipos ─────────────────────────────────────────────────────────────────────

interface DeviceProfile {
  ip: string
  device_type: string
  confidence: number
  reasons: string   // JSON array como texto
  updated_at: string
}

// ── Configuración de tipos ─────────────────────────────────────────────────────

const TYPE_META: Record<string, { icon: string; label: string }> = {
  ios:      { icon: '📱', label: 'iPhone / iPad' },
  android:  { icon: '🤖', label: 'Android' },
  smart_tv: { icon: '📺', label: 'Smart TV' },
  iot:      { icon: '🔌', label: 'Dispositivo IoT' },
  laptop:   { icon: '💻', label: 'Laptop / Desktop' },
  unknown:  { icon: '❓', label: 'Desconocido' },
}

// ── Inicialización ────────────────────────────────────────────────────────────

function markActive(): void {
  qs(`a[data-page="devices"]`)?.classList.add('active')
}

export async function init(): Promise<void> {
  markActive()
  connectSse()

  await loadDevices()

  // SSE: refrescar cuando hay nueva clasificación de dispositivo
  onSseMessage((event: any) => {
    if (event.event === 'batch_received' || event.event === 'analysis_done') {
      // Pequeño delay para que el backend actualice el perfil
      setTimeout(loadDevices, 2000)
    }
    logSseEvent(event)
  })

  // Refrescar cada 60s
  setInterval(loadDevices, 60_000)

  // Filtro de búsqueda en tiempo real
  el('filter-type')?.addEventListener('input', (e) => {
    const term = (e.target as HTMLInputElement).value.toLowerCase()
    filterTable(term)
  })

  el('btn-refresh-devices')?.addEventListener('click', loadDevices)
}

// ── Carga de datos ────────────────────────────────────────────────────────────

async function loadDevices(): Promise<void> {
  try {
    const resp = await fetch('/api/profiles')
    const data = await resp.json() as DeviceProfile[]
    renderDevices(data)
    renderChart(data)
    updateStats(data)
  } catch (e) {
    console.error('loadDevices:', e)
    const tbody = qs('#devices-table tbody')
    if (tbody) {
      tbody.innerHTML = '<tr><td colspan="5" class="text-muted">Error cargando perfiles</td></tr>'
    }
  }
}

// ── Renderizado de tabla ───────────────────────────────────────────────────────

function renderDevices(data: DeviceProfile[]): void {
  const tbody = qs('#devices-table tbody')
  if (!tbody) return

  if (!data || data.length === 0) {
    tbody.innerHTML = '<tr><td colspan="5" class="text-muted">— Sin dispositivos perfilados aún —</td></tr>'
    return
  }

  // Ordenar: mayor confianza primero
  const sorted = [...data].sort((a, b) => b.confidence - a.confidence)

  tbody.innerHTML = sorted.map(d => {
    const meta = TYPE_META[d.device_type] ?? TYPE_META.unknown
    const conf = Math.round(d.confidence * 100)
    const barWidth = Math.max(4, conf)

    const ts = new Date(d.updated_at).toLocaleString('es-MX', {
      month: '2-digit', day: '2-digit',
      hour: '2-digit', minute: '2-digit',
    })

    // Parsear reasons (JSON array)
    let reasons: string[] = []
    try {
      reasons = JSON.parse(d.reasons ?? '[]')
    } catch {
      reasons = []
    }

    const reasonsHtml = reasons.length > 0
      ? `<div class="reasons-list">${reasons.slice(0, 4).map(r =>
          `<span class="reason-tag">${escapeHtml(r)}</span>`).join('')}</div>`
      : '<span class="text-muted">—</span>'

    return `
      <tr data-ip="${escapeHtml(d.ip)}" data-type="${d.device_type}">
        <td><code style="font-size:0.9em">${escapeHtml(d.ip)}</code></td>
        <td>
          <span class="device-type-badge badge-${d.device_type}">
            ${meta.icon} ${meta.label}
          </span>
        </td>
        <td>
          <div class="confidence-bar">
            <div class="confidence-fill" style="width:${barWidth}px; max-width:80px"></div>
            <span class="confidence-label">${conf}%</span>
          </div>
        </td>
        <td>${reasonsHtml}</td>
        <td>${ts}</td>
      </tr>
    `
  }).join('')
}

// ── Filtro ────────────────────────────────────────────────────────────────────

function filterTable(term: string): void {
  const rows = document.querySelectorAll('#devices-table tbody tr[data-ip]')
  rows.forEach(row => {
    const ip   = row.getAttribute('data-ip')?.toLowerCase() ?? ''
    const type = row.getAttribute('data-type')?.toLowerCase() ?? ''
    const text = (row as HTMLElement).innerText.toLowerCase()
    const visible = !term || ip.includes(term) || type.includes(term) || text.includes(term)
    ;(row as HTMLElement).style.display = visible ? '' : 'none'
  })
}

// ── Gráfico de distribución ───────────────────────────────────────────────────

function renderChart(data: DeviceProfile[]): void {
  const container = el('device-type-chart')
  if (!container) return

  if (!data || data.length === 0) {
    container.innerHTML = '<p class="text-muted">Sin datos de perfiles disponibles</p>'
    return
  }

  // Contar por tipo
  const counts: Record<string, number> = {}
  data.forEach(d => {
    counts[d.device_type] = (counts[d.device_type] ?? 0) + 1
  })

  const order = ['ios', 'android', 'smart_tv', 'iot', 'laptop', 'unknown']
  container.innerHTML = order
    .filter(type => counts[type])
    .map(type => {
      const meta = TYPE_META[type] ?? TYPE_META.unknown
      const count = counts[type]
      return `
        <div class="chart-card card-${type}">
          <div class="chart-icon">${meta.icon}</div>
          <div class="chart-count">${count}</div>
          <div class="chart-label">${meta.label}</div>
        </div>
      `
    }).join('')
}

// ── Estadísticas ──────────────────────────────────────────────────────────────

function updateStats(data: DeviceProfile[]): void {
  const counts: Record<string, number> = {}
  data.forEach(d => {
    counts[d.device_type] = (counts[d.device_type] ?? 0) + 1
  })

  el('stat-ios').textContent    = String(counts.ios      ?? 0)
  el('stat-android').textContent = String(counts.android  ?? 0)
  el('stat-smart-tv').textContent = String(counts.smart_tv ?? 0)
  el('stat-laptop').textContent  = String(counts.laptop   ?? 0)
}

// ── SSE logging ───────────────────────────────────────────────────────────────

function logSseEvent(event: any): void {
  const log = el('sse-log')
  if (!log) return

  const time = new Date().toLocaleTimeString('es-MX')
  const eventType = event.event ?? 'unknown'
  const line = document.createElement('div')
  line.className = 'log-line'
  line.innerHTML = `<span style="color:#999">[${time}]</span> <strong>${eventType}</strong>`

  log.insertBefore(line, log.firstChild)
  while (log.children.length > 30) {
    log.removeChild(log.lastChild!)
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

function escapeHtml(str: string): string {
  return str
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
}

// Iniciar cuando el DOM está listo
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', init)
} else {
  init()
}
