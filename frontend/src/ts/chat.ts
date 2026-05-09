/**
 * chat.ts — página de Chat con IA (Groq/Qwen)
 */
import '../scss/main.scss'
import { connectSse } from './sse'
import { sendChat, type ChatRequest } from './api'

// ── Tipos ─────────────────────────────────────────────────────────────────────

interface Message { role: 'user' | 'model'; text: string; ts: string }

// ── Estado ────────────────────────────────────────────────────────────────────

let currentSessionId = newSessionId()
const sessions: Map<string, Message[]> = new Map()

// ── Helpers DOM ───────────────────────────────────────────────────────────────

const el = <T extends HTMLElement>(id: string): T =>
  document.getElementById(id) as T

const qs = (sel: string, ctx: ParentNode = document): HTMLElement | null =>
  ctx.querySelector(sel)

function markActive(): void {
  qs('a[data-page="chat"]')?.classList.add('active')
}

function newSessionId(): string {
  return `s-${Date.now()}-${Math.random().toString(36).slice(2, 7)}`
}

function ts(): string {
  return new Date().toLocaleTimeString()
}

// ── Render mensajes ───────────────────────────────────────────────────────────

function renderMessages(msgs: Message[]): void {
  const box = el('chat-messages')
  if (msgs.length === 0) {
    box.innerHTML = `
      <div class="chat-empty-state">
        <span class="empty-icon">💬</span>
        <p>Escribe un mensaje para comenzar</p>
      </div>`
    return
  }
  box.innerHTML = msgs
    .map(m => `
      <div class="chat-bubble ${m.role} animate__animated animate__fadeInUp">
        <div class="bubble-content">${escHtml(m.text)}</div>
        <div class="bubble-ts">${m.ts}</div>
      </div>`)
    .join('')
  box.scrollTop = box.scrollHeight
}

function escHtml(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/\n/g, '<br>')
}

// ── Render sesiones ───────────────────────────────────────────────────────────

function renderSessionList(): void {
  const list = el('session-list')
  if (sessions.size === 0) {
    list.innerHTML = '<li style="color:var(--c-muted,#8b949e);font-size:.8rem">Sin sesiones</li>'
    return
  }
  list.innerHTML = [...sessions.entries()]
    .map(([id]) => `
      <li class="${id === currentSessionId ? 'active' : ''}"
          data-session="${id}">${id.slice(-8)}</li>`)
    .join('')

  list.querySelectorAll('li[data-session]').forEach(li => {
    li.addEventListener('click', () => {
      const sid = (li as HTMLElement).dataset['session']!
      switchSession(sid)
    })
  })
}

function switchSession(id: string): void {
  currentSessionId = id
  const msgs = sessions.get(id) ?? []
  renderMessages(msgs)
  renderSessionList()
}

// ── Enviar mensaje ────────────────────────────────────────────────────────────

async function sendMessage(): Promise<void> {
  const input = el<HTMLTextAreaElement>('chat-input')
  const text  = input.value.trim()
  if (!text) return

  input.value = ''
  setLoading(true)

  const msgs = sessions.get(currentSessionId) ?? []
  msgs.push({ role: 'user', text, ts: ts() })
  sessions.set(currentSessionId, msgs)
  renderMessages(msgs)
  renderSessionList()

  // Campo `question` — nombre que espera el backend Java en handleChat()
  const body: ChatRequest = { session_id: currentSessionId, question: text }

  try {
    const resp = await sendChat(body)
    // Campo `answer` — nombre que devuelve el backend Java
    msgs.push({ role: 'model', text: resp.answer, ts: ts() })
    sessions.set(currentSessionId, msgs)
    renderMessages(msgs)
  } catch (e) {
    msgs.push({ role: 'model', text: `⚠️ Error: ${String(e)}`, ts: ts() })
    sessions.set(currentSessionId, msgs)
    renderMessages(msgs)
  } finally {
    setLoading(false)
  }
}

function setLoading(on: boolean): void {
  const btn     = el('btn-send')
  const label   = el('btn-send-label')
  const spinner = el('btn-send-spinner')
  btn.toggleAttribute('disabled', on)
  label.hidden  = on
  spinner.hidden = !on
}

// ── Init ──────────────────────────────────────────────────────────────────────

function init(): void {
  markActive()
  connectSse()

  sessions.set(currentSessionId, [])
  renderSessionList()
  renderMessages([])

  el('btn-new-session').addEventListener('click', () => {
    currentSessionId = newSessionId()
    sessions.set(currentSessionId, [])
    renderSessionList()
    renderMessages([])
  })

  el('btn-send').addEventListener('click', () => { void sendMessage() })

  el('chat-input').addEventListener('keydown', (e: KeyboardEvent) => {
    if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) {
      void sendMessage()
    }
  })

  el('btn-clear-chat').addEventListener('click', () => {
    sessions.set(currentSessionId, [])
    renderMessages([])
  })
}

document.addEventListener('DOMContentLoaded', init)
