/**
 * reports.ts — Resúmenes y reportes generados por IA
 */
import '../scss/main.scss'
import { connectSse } from './sse'
import { getSummaries, getReports, type Summary, type Report } from './api'

const el = <T extends HTMLElement>(id: string): T =>
  document.getElementById(id) as T

const qs = (sel: string, ctx: ParentNode = document): HTMLElement | null =>
  ctx.querySelector(sel)

function markActive(): void {
  qs('a[data-page="reports"]')?.classList.add('active')
}

// ── Tabs ──────────────────────────────────────────────────────────────────────

function initTabs(): void {
  document.querySelectorAll<HTMLButtonElement>('.tab').forEach(tab => {
    tab.addEventListener('click', () => {
      const target = tab.dataset['tab']!
      document.querySelectorAll('.tab').forEach(t => t.classList.remove('tab-active'))
      tab.classList.add('tab-active')
      document.querySelectorAll<HTMLElement>('.tab-content').forEach(c => {
        c.classList.toggle('hidden', c.id !== `tab-${target}`)
      })
      if (target === 'reports') void loadReports()
    })
  })
}

// ── Render ────────────────────────────────────────────────────────────────────

function cardHtml(ts: string, text: string): string {
  return `
    <div class="card animate__animated animate__fadeIn">
      <div class="card-header">
        <span class="card-ts">${ts}</span>
      </div>
      <div class="card-body">${escHtml(text)}</div>
    </div>`
}

function escHtml(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}

function renderSummaries(data: Summary[]): void {
  const list = el('summaries-list')
  list.innerHTML = data.length
    ? data.map(s => cardHtml(s.timestamp, s.summary)).join('')
    : '<p style="color:#8b949e">Sin resúmenes disponibles</p>'
}

function renderReports(data: Report[]): void {
  const list = el('reports-list')
  list.innerHTML = data.length
    ? data.map(r => cardHtml(r.timestamp, r.report)).join('')
    : '<p style="color:#8b949e">Sin reportes disponibles</p>'
}

async function loadSummaries(): Promise<void> {
  try {
    renderSummaries(await getSummaries(20))
  } catch (e) { console.error(e) }
}

async function loadReports(): Promise<void> {
  try {
    renderReports(await getReports(20))
  } catch (e) { console.error(e) }
}

// ── Init ──────────────────────────────────────────────────────────────────────

function init(): void {
  markActive()
  connectSse()
  initTabs()

  void loadSummaries()

  el('btn-refresh-summaries').addEventListener('click', () => void loadSummaries())
  el('btn-refresh-reports').addEventListener('click', () => void loadReports())
}

document.addEventListener('DOMContentLoaded', init)
