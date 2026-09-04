<script setup>
import { ref, onMounted, onUnmounted } from 'vue'
import { hasBridge, getEnvName, baihu } from './kernelsu.js'
import EnvCard from './components/EnvCard.vue'
import ContainerCard from './components/ContainerCard.vue'
import PasswordCard from './components/PasswordCard.vue'
import ControlCard from './components/ControlCard.vue'
import LogCard from './components/LogCard.vue'

const envName = ref('检测中...')
const showFallback = ref(false)
const moduleVersion = ref('--')
const footerVersion = ref('v1.0.0')

// Reactive state shared across components
const containerRunning = ref(false)
const pid = ref('--')
const uptime = ref('--')
const mem = ref('--')
const rootfsSize = ref('--')
const dataSize = ref('--')
const portListening = ref(false)
const password = ref('--')
const logs = ref('')
const logInfo = ref('')

let pollTimer = null

async function refreshAll() {
  if (!hasBridge()) return

  // status
  try {
    const r = await baihu.status()
    const stdout = r.stdout || ''
    containerRunning.value = stdout.includes('运行中') || stdout.includes('PID')
    const m = s => { const x = stdout.match(s); return x ? x[1] : '--' }
    pid.value     = m(/PID:\s*(\d+)/)
    uptime.value  = m(/运行时间:\s*([\d\shmd]+)/)
    mem.value     = m(/内存占用:\s*([\d.]+MB)/)
    rootfsSize.value = m(/rootfs:\s*([\d.]+[KMG]?)/)
    dataSize.value    = m(/数据目录:\s*([\d.]+[KMG]?)/)
  } catch { containerRunning.value = false }

  // port
  try {
    const r = await baihu.portCheck()
    const out = (r.stdout || '').trim()
    portListening.value = out && !out.includes('not listening') && out.length > 0
  } catch { portListening.value = false }

  // password
  try {
    const r = await baihu.password()
    const stdout = (r.stdout || '').trim()
    const lines = stdout.split('\n')
    let found = false
    for (const line of lines) {
      const m = line.match(/[a-zA-Z0-9!@#$%^&*()_+]{10,}/)
      if (m) { password.value = m[0]; found = true; break }
    }
    if (!found) password.value = stdout.substring(0, 24) || '--'
  } catch { /* ignore */ }
}

async function loadModuleVersion() {
  try {
    const r = await baihu.moduleProp()
    const text = r.stdout || ''
    const m = text.match(/version=(.+)/)
    if (m) { moduleVersion.value = m[1].trim(); footerVersion.value = m[1].trim() }
  } catch { /* ignore */ }
}

async function loadLog() {
  try {
    const r = await baihu.runLog(50)
    const text = (r.stdout || '').trim()
    if (text) {
      logs.value = text
      logInfo.value = '共 ' + text.split('\n').length + ' 行'
    } else {
      logs.value = '# 日志文件为空或不存在\n# 路径: /data/baihu/run.log'
      logInfo.value = '空'
    }
  } catch {
    logs.value = '# 读取日志失败'
    logInfo.value = '失败'
  }
}

function startPoll() {
  stopPoll()
  pollTimer = setInterval(refreshAll, 30000)
}

function stopPoll() {
  if (pollTimer) { clearInterval(pollTimer); pollTimer = null }
}

onMounted(() => {
  if (!hasBridge()) {
    envName.value = '未知 (WebView)'
    showFallback.value = true
    return
  }
  envName.value = getEnvName()
  loadModuleVersion()
  setTimeout(refreshAll, 300)
  startPoll()
})

onUnmounted(stopPoll)
</script>

<template>
  <div class="container">
    <!-- Toast -->
    <div class="toast-container" id="toastContainer"></div>

    <!-- Modal -->
    <div class="modal" id="confirmModal" v-show="false">
      <div class="modal-content">
        <div class="modal-header"><h2>确认操作</h2></div>
        <div class="modal-body" id="modalBody">确定要执行此操作吗？</div>
        <div class="modal-footer">
          <button class="btn-cancel" id="modalCancel">取消</button>
          <button class="btn-confirm" id="modalConfirm">确认</button>
        </div>
      </div>
    </div>

    <EnvCard :env-name="envName" :module-version="moduleVersion" :container-running="containerRunning" />

    <ContainerCard
      :container-running="containerRunning"
      :pid="pid"
      :uptime="uptime"
      :mem="mem"
      :port-listening="portListening"
      :rootfs-size="rootfsSize"
      :data-size="dataSize"
    />

    <PasswordCard :password="password" />

    <ControlCard :container-running="containerRunning" @refresh="refreshAll" />

    <LogCard :logs="logs" :log-info="logInfo" @load-log="loadLog" />

    <!-- Fallback -->
    <div class="groupbox" v-if="showFallback">
      <span class="groupbox-title">终端命令</span>
      <p style="font-size:13px;color:#666;margin-bottom:8px;">当前环境不支持 WebUI 控制，请使用终端执行：</p>
      <div class="cli-hint">
        <code>su -c "baihu password"</code>
      </div>
    </div>

    <div class="footer">白虎面板 Magisk 模块 <span>{{ footerVersion }}</span></div>
  </div>
</template>

<style>
/* Reset & theme */
*, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
body {
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
  background: #f5f5f5; color: #333; font-size: 14px; line-height: 1.5;
  -webkit-font-smoothing: antialiased;
}
.container { max-width: 480px; margin: 0 auto; padding: 12px; }

/* Group box */
.groupbox {
  background: #fff; border-radius: 12px; padding: 16px; margin-bottom: 12px;
  box-shadow: 0 1px 3px rgba(0,0,0,.08);
}
.groupbox-title {
  display: block; font-size: 13px; font-weight: 600; color: #999;
  text-transform: uppercase; letter-spacing: .5px; margin-bottom: 12px;
}

/* Status row */
.status-row {
  display: flex; justify-content: space-between; align-items: center;
  padding: 6px 0; border-bottom: 1px solid #f0f0f0;
}
.status-row:last-child { border-bottom: none; }
.status-label { font-size: 14px; color: #666; }
.status-value { font-size: 14px; color: #333; font-weight: 500; }

/* Status dot */
.status-dot {
  display: inline-block; width: 8px; height: 8px; border-radius: 50%;
  margin-right: 6px; vertical-align: middle;
}
.status-dot.green { background: #4caf50; }
.status-dot.gray  { background: #bbb; }

/* Tag */
.tag {
  display: inline-block; padding: 2px 10px; border-radius: 10px;
  font-size: 12px; font-weight: 500;
}
.tag.running { background: #e8f5e9; color: #2e7d32; }
.tag.stopped { background: #fce4ec; color: #c62828; }
.tag.loading { background: #fff3e0; color: #e65100; }

/* Buttons */
.btn-row { display: flex; gap: 8px; flex-wrap: wrap; }
.btn {
  flex: 1; min-width: 72px; padding: 10px 16px; border: none; border-radius: 8px;
  font-size: 14px; font-weight: 500; cursor: pointer; transition: opacity .2s;
  text-align: center;
}
.btn:disabled { opacity: .5; cursor: not-allowed; }
.btn.primary   { background: #1976d2; color: #fff; }
.btn.danger    { background: #d32f2f; color: #fff; }
.btn.secondary { background: #388e3c; color: #fff; }
.btn.outline   { background: transparent; color: #1976d2; border: 1px solid #1976d2; }

/* Password box */
.password-box {
  background: #f5f5f5; border-radius: 8px; padding: 12px; text-align: center;
  font-size: 18px; font-family: "Courier New", monospace; letter-spacing: 2px;
  color: #1976d2; margin-bottom: 8px;
}

/* Msg */
.msg { margin-top: 8px; padding: 8px; border-radius: 6px; font-size: 13px; display: none; }
.msg.info    { background: #e3f2fd; color: #1565c0; display: block; }
.msg.success { background: #e8f5e9; color: #2e7d32; display: block; }
.msg.error   { background: #fce4ec; color: #c62828; display: block; }

/* Log box */
.log-box {
  background: #1e1e1e; color: #d4d4d4; font-family: "Courier New", monospace;
  font-size: 12px; padding: 12px; border-radius: 8px; max-height: 300px;
  overflow-y: auto; white-space: pre-wrap; word-break: break-all;
  line-height: 1.6;
}

/* Toast */
.toast-container {
  position: fixed; top: 12px; left: 50%; transform: translateX(-50%);
  z-index: 9999; display: flex; flex-direction: column; gap: 6px;
  pointer-events: none;
}
.toast {
  padding: 10px 20px; border-radius: 8px; font-size: 14px; font-weight: 500;
  box-shadow: 0 2px 8px rgba(0,0,0,.15); text-align: center;
  white-space: nowrap; pointer-events: auto;
}
.toast.success { background: #2e7d32; color: #fff; }
.toast.error   { background: #c62828; color: #fff; }
.toast.info    { background: #1976d2; color: #fff; }

/* Modal */
.modal {
  display: none; position: fixed; z-index: 1000; left: 0; top: 0;
  width: 100%; height: 100%; background: rgba(0,0,0,.5);
}
.modal-content {
  background: #fff; margin: 40% auto; padding: 24px; border-radius: 12px;
  max-width: 320px; text-align: center;
}
.modal-header h2 { font-size: 18px; margin-bottom: 12px; }
.modal-body { font-size: 14px; color: #666; margin-bottom: 20px; }
.modal-footer { display: flex; gap: 12px; justify-content: center; }
.btn-cancel, .btn-confirm {
  padding: 8px 24px; border: none; border-radius: 8px; font-size: 14px; cursor: pointer;
}
.btn-cancel { background: #e0e0e0; color: #333; }
.btn-confirm { background: #1976d2; color: #fff; }

/* CLI hint */
.cli-hint {
  background: #1e1e1e; border-radius: 8px; padding: 12px; overflow-x: auto;
}
.cli-hint code {
  color: #d4d4d4; font-family: "Courier New", monospace; font-size: 13px;
  white-space: pre-wrap; word-break: break-all;
}

/* Footer */
.footer {
  text-align: center; font-size: 12px; color: #999; padding: 16px 0 32px;
}
</style>