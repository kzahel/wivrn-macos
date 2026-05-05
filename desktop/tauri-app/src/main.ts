import { invoke } from '@tauri-apps/api/core'
import { relaunch } from '@tauri-apps/plugin-process'
import { check } from '@tauri-apps/plugin-updater'
import './style.css'

type HostStatus = {
  running: boolean
  pid: number | null
  configPath: string
  sidecarPath: string | null
  startedAt: string | null
  lastExit: string | null
  logs: string[]
}

const app = document.querySelector<HTMLDivElement>('#app')

if (!app) {
  throw new Error('missing app root')
}

app.innerHTML = `
  <section class="shell">
    <header class="topbar">
      <div>
        <h1>WiVRn Mac Host</h1>
        <p>Headless WiVRn server controller for macOS.</p>
      </div>
      <span id="status-pill" class="pill">Checking</span>
    </header>

    <section class="controls" aria-label="Server controls">
      <label class="toggle">
        <input id="enable-audio" type="checkbox" />
        <span>Audio</span>
      </label>
      <label class="toggle">
        <input id="no-encrypt" type="checkbox" />
        <span>No encryption</span>
      </label>
      <button id="start-server" type="button">Start</button>
      <button id="stop-server" type="button">Stop</button>
      <button id="restart-server" type="button">Restart</button>
      <button id="check-update" type="button">Check Update</button>
    </section>

    <section class="status-grid" aria-label="Server status">
      <div>
        <span class="label">Process</span>
        <strong id="process-state">Unknown</strong>
      </div>
      <div>
        <span class="label">PID</span>
        <strong id="pid">-</strong>
      </div>
      <div>
        <span class="label">Started</span>
        <strong id="started-at">-</strong>
      </div>
      <div>
        <span class="label">Last exit</span>
        <strong id="last-exit">-</strong>
      </div>
    </section>

    <section class="paths" aria-label="Paths">
      <div>
        <span class="label">Config</span>
        <code id="config-path">-</code>
      </div>
      <div>
        <span class="label">Sidecar</span>
        <code id="sidecar-path">-</code>
      </div>
    </section>

    <section class="log-panel" aria-label="Server logs">
      <div class="panel-title">
        <h2>Log</h2>
        <button id="refresh" type="button">Refresh</button>
      </div>
      <pre id="logs"></pre>
    </section>
  </section>
`

const statusPill = document.querySelector<HTMLSpanElement>('#status-pill')!
const processState = document.querySelector<HTMLElement>('#process-state')!
const pid = document.querySelector<HTMLElement>('#pid')!
const startedAt = document.querySelector<HTMLElement>('#started-at')!
const lastExit = document.querySelector<HTMLElement>('#last-exit')!
const configPath = document.querySelector<HTMLElement>('#config-path')!
const sidecarPath = document.querySelector<HTMLElement>('#sidecar-path')!
const logs = document.querySelector<HTMLPreElement>('#logs')!
const enableAudio = document.querySelector<HTMLInputElement>('#enable-audio')!
const noEncrypt = document.querySelector<HTMLInputElement>('#no-encrypt')!

async function refreshStatus() {
  const status = await invoke<HostStatus>('get_status')
  statusPill.textContent = status.running ? 'Running' : 'Stopped'
  statusPill.dataset.state = status.running ? 'running' : 'stopped'
  processState.textContent = status.running ? 'Running' : 'Stopped'
  pid.textContent = status.pid === null ? '-' : String(status.pid)
  startedAt.textContent = status.startedAt ?? '-'
  lastExit.textContent = status.lastExit ?? '-'
  configPath.textContent = status.configPath
  sidecarPath.textContent = status.sidecarPath ?? '-'
  logs.textContent = status.logs.join('\n')
  logs.scrollTop = logs.scrollHeight
}

async function startServer() {
  await invoke('start_server', {
    options: {
      enableAudio: enableAudio.checked,
      noEncrypt: noEncrypt.checked,
    },
  })
  await refreshStatus()
}

async function stopServer() {
  await invoke('stop_server')
  await refreshStatus()
}

async function restartServer() {
  await invoke('restart_server', {
    options: {
      enableAudio: enableAudio.checked,
      noEncrypt: noEncrypt.checked,
    },
  })
  await refreshStatus()
}

async function checkForUpdates() {
  statusPill.textContent = 'Checking'
  const update = await check()
  if (!update) {
    await refreshStatus()
    return
  }

  statusPill.textContent = `Updating to ${update.version}`
  await update.downloadAndInstall()
  await relaunch()
}

document.querySelector<HTMLButtonElement>('#start-server')!.addEventListener('click', () => {
  startServer().catch(showError)
})

document.querySelector<HTMLButtonElement>('#stop-server')!.addEventListener('click', () => {
  stopServer().catch(showError)
})

document.querySelector<HTMLButtonElement>('#restart-server')!.addEventListener('click', () => {
  restartServer().catch(showError)
})

document.querySelector<HTMLButtonElement>('#refresh')!.addEventListener('click', () => {
  refreshStatus().catch(showError)
})

document.querySelector<HTMLButtonElement>('#check-update')!.addEventListener('click', () => {
  checkForUpdates().catch(showError)
})

function showError(error: unknown) {
  const message = error instanceof Error ? error.message : String(error)
  statusPill.textContent = 'Error'
  statusPill.dataset.state = 'error'
  logs.textContent = `${logs.textContent}\n${message}`.trim()
}

refreshStatus().catch(showError)
window.setInterval(() => {
  refreshStatus().catch(showError)
}, 2000)
