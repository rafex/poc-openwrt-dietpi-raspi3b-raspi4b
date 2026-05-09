/**
 * sse.ts — conexión SSE al endpoint /events del backend
 */

export type SseHandler = (data: string) => void

let source: EventSource | null = null
let handlers: SseHandler[] = []

export function connectSse(): void {
  if (source) return

  source = new EventSource('/events')

  source.onopen = () => {
    setStatus('online', 'En línea')
  }

  source.onmessage = (event: MessageEvent) => {
    handlers.forEach(h => h(event.data as string))
  }

  source.onerror = () => {
    setStatus('offline', 'Sin conexión')
    source?.close()
    source = null
    // Reconectar en 5s
    setTimeout(connectSse, 5000)
  }
}

export function onSseMessage(handler: SseHandler): void {
  handlers.push(handler)
}

export function offSseMessage(handler: SseHandler): void {
  handlers = handlers.filter(h => h !== handler)
}

function setStatus(cls: 'online' | 'offline', text: string): void {
  const dot  = document.getElementById('status-dot')
  const label = document.getElementById('status-text')
  if (dot) {
    dot.className = `status-dot ${cls}`
  }
  if (label) {
    label.textContent = text
  }
}
