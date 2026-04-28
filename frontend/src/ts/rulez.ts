/**
 * rulez.ts — Reglas, whitelist y políticas
 */
import '../scss/main.scss'
import { connectSse } from './sse'
import {
  getWhitelist, addWhitelist, removeWhitelist,
  getRules, saveRule, deleteRule,
  type WhitelistEntry, type Rule,
} from './api'

const el = <T extends HTMLElement>(id: string): T =>
  document.getElementById(id) as T

const qs = (sel: string, ctx: ParentNode = document): HTMLElement | null =>
  ctx.querySelector(sel)

function markActive(): void {
  qs('a[data-page="rulez"]')?.classList.add('active')
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

      // Cargar datos al cambiar de tab
      if (target === 'whitelist') void loadWhitelist()
      if (target === 'ai-rules')  void loadRules()
    })
  })
}

// ── Whitelist ─────────────────────────────────────────────────────────────────

function renderWhitelist(data: WhitelistEntry[]): void {
  const tbody = ensureTbody('whitelist-table')
  if (data.length === 0) {
    tbody.innerHTML = '<tr><td colspan="3" style="color:#8b949e">Lista vacía</td></tr>'
    return
  }
  tbody.innerHTML = data.map(e => `
    <tr>
      <td>${e.domain}</td>
      <td>${e.added_at}</td>
      <td>
        <button class="btn btn-sm"
                data-remove="${e.domain}"
                style="color:#f85149;border-color:#f85149">🗑</button>
      </td>
    </tr>`).join('')

  tbody.querySelectorAll<HTMLButtonElement>('[data-remove]').forEach(btn => {
    btn.addEventListener('click', async () => {
      const domain = btn.dataset['remove']!
      await removeWhitelist(domain)
      void loadWhitelist()
    })
  })
}

async function loadWhitelist(): Promise<void> {
  try {
    renderWhitelist(await getWhitelist())
  } catch (e) { console.error(e) }
}

// ── AI Rules ──────────────────────────────────────────────────────────────────

function renderRules(data: Rule[]): void {
  const tbody = ensureTbody('ai-rules-table')
  if (data.length === 0) {
    tbody.innerHTML = '<tr><td colspan="4" style="color:#8b949e">Sin reglas</td></tr>'
    return
  }
  tbody.innerHTML = data.map(r => `
    <tr>
      <td><code>${r.key}</code></td>
      <td>${r.value}</td>
      <td>${r.updated_at}</td>
      <td>
        <button class="btn btn-sm"
                data-del-rule="${r.key}"
                style="color:#f85149;border-color:#f85149">🗑</button>
      </td>
    </tr>`).join('')

  tbody.querySelectorAll<HTMLButtonElement>('[data-del-rule]').forEach(btn => {
    btn.addEventListener('click', async () => {
      await deleteRule(btn.dataset['delRule']!)
      void loadRules()
    })
  })
}

async function loadRules(): Promise<void> {
  try {
    renderRules(await getRules())
  } catch (e) { console.error(e) }
}

// ── Util ──────────────────────────────────────────────────────────────────────

function ensureTbody(tableId: string): HTMLTableSectionElement {
  const table = el<HTMLTableElement>(tableId)
  let tbody = table.querySelector('tbody')
  if (!tbody) {
    tbody = document.createElement('tbody')
    table.appendChild(tbody)
  }
  return tbody
}

// ── Init ──────────────────────────────────────────────────────────────────────

function init(): void {
  markActive()
  connectSse()
  initTabs()

  // Agregar whitelist
  el('btn-add-whitelist').addEventListener('click', async () => {
    const input = el<HTMLInputElement>('whitelist-input')
    const domain = input.value.trim()
    if (!domain) return
    await addWhitelist(domain)
    input.value = ''
    void loadWhitelist()
  })

  // Guardar regla
  el('btn-save-rule').addEventListener('click', async () => {
    const key   = el<HTMLInputElement>('rule-key').value.trim()
    const value = el<HTMLInputElement>('rule-value').value.trim()
    if (!key || !value) return
    await saveRule(key, value)
    void loadRules()
  })

  // Cargar datos iniciales de la tab activa (políticas)
  // La whitelist y reglas se cargan al hacer clic en su tab
}

document.addEventListener('DOMContentLoaded', init)
