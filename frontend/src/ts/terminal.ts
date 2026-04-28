/**
 * terminal.ts — Terminal web de diagnóstico
 */
import '../scss/main.scss'
import { connectSse } from './sse'

const el = <T extends HTMLElement>(id: string): T =>
  document.getElementById(id) as T

const qs = (sel: string, ctx: ParentNode = document): HTMLElement | null =>
  ctx.querySelector(sel)

function markActive(): void {
  qs('a[data-page="terminal"]')?.classList.add('active')
}

// ── Terminal output ───────────────────────────────────────────────────────────

function appendLine(text: string, cls = ''): void {
  const out  = el('terminal-output')
  const line = document.createElement('div')
  line.className = `out-line ${cls}`
  line.textContent = text
  out.appendChild(line)
  out.scrollTop = out.scrollHeight
}

function clearOutput(): void {
  el('terminal-output').innerHTML = ''
}

// ── Ejecutar comando ──────────────────────────────────────────────────────────

async function runCommand(cmd: string): Promise<void> {
  if (!cmd.trim()) return

  appendLine(`$ ${cmd}`, 'prompt-echo')

  try {
    const res = await fetch('/api/terminal', {
      method:  'POST',
      headers: { 'Content-Type': 'application/json' },
      body:    JSON.stringify({ cmd }),
    })

    if (!res.ok) {
      appendLine(`Error HTTP ${res.status}`, 'err-line')
      return
    }

    const data = await res.json() as { stdout?: string; stderr?: string; exit_code?: number }

    if (data.stdout) {
      data.stdout.split('\n').forEach(l => appendLine(l))
    }
    if (data.stderr) {
      data.stderr.split('\n').forEach(l => appendLine(l, 'err-line'))
    }
  } catch (e) {
    appendLine(`Error: ${String(e)}`, 'err-line')
  }
}

// ── Init ──────────────────────────────────────────────────────────────────────

function init(): void {
  markActive()
  connectSse()

  const input = el<HTMLInputElement>('terminal-input')

  el('btn-run').addEventListener('click', () => {
    void runCommand(input.value)
    input.value = ''
    input.focus()
  })

  input.addEventListener('keydown', (e: KeyboardEvent) => {
    if (e.key === 'Enter') {
      void runCommand(input.value)
      input.value = ''
    }
  })

  el('btn-clear-terminal').addEventListener('click', clearOutput)

  // Comandos rápidos
  document.querySelectorAll<HTMLButtonElement>('.quick-cmd').forEach(btn => {
    btn.addEventListener('click', () => {
      const cmd = btn.dataset['cmd'] ?? ''
      void runCommand(cmd)
    })
  })
}

document.addEventListener('DOMContentLoaded', init)
