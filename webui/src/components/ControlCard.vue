<script setup>
import { ref } from 'vue'
import { baihu } from '../kernelsu.js'

const props = defineProps({ containerRunning: Boolean, panelPort: { type: String, default: '18052' } })
const emit = defineEmits(['refresh'])

const ctrlMsg = ref('')
const ctrlMsgType = ref('')
const starting = ref(false)
const stopping = ref(false)

async function doStart() {
  starting.value = true
  ctrlMsg.value = '正在启动面板...'
  ctrlMsgType.value = 'info'
  try {
    const r = await baihu.start()
    const out = r.stdout || ''
    if (r.errno === 0 && (out.includes('容器已启动') || out.includes('已在运行'))) {
      ctrlMsg.value = out.includes('已在运行') ? '面板已在运行中' : '面板已启动'
      ctrlMsgType.value = 'success'
    } else {
      ctrlMsg.value = (out.replace(/\n+/g, ' ').trim().substring(0, 300) || '启动失败')
      ctrlMsgType.value = 'error'
    }
  } catch (e) {
    ctrlMsg.value = '启动失败: ' + (e.message || '未知错误'); ctrlMsgType.value = 'error'
  } finally {
    starting.value = false
    emit('refresh')
  }
}

async function doStop() {
  stopping.value = true
  ctrlMsg.value = '正在停止面板...'
  ctrlMsgType.value = 'info'
  try {
    const r = await baihu.stop()
    const out = (r.stdout || '').trim()
    if (r.errno === 0 && !out.includes('!')) {
      ctrlMsg.value = '面板已停止'; ctrlMsgType.value = 'success'
    } else {
      ctrlMsg.value = (out.substring(0, 300) || '停止失败'); ctrlMsgType.value = 'error'
    }
  } catch (e) {
    ctrlMsg.value = '停止失败: ' + (e.message || '未知错误'); ctrlMsgType.value = 'error'
  } finally {
    stopping.value = false
    emit('refresh')
  }
}

function openPanel() {
  const url = 'http://127.0.0.1:' + (props.panelPort || '18052') + '/'
  const w = window.open(url)
  if (!w || w.closed) { ctrlMsg.value = '请手动访问: ' + url; ctrlMsgType.value = 'info' }
}
</script>

<template>
  <div class="groupbox">
    <span class="groupbox-title">面板控制</span>
    <div class="btn-row">
      <button class="btn primary"   :disabled="starting" @click="doStart">启动</button>
      <button class="btn danger"    :disabled="stopping" @click="doStop">停止</button>
      <button class="btn secondary" @click="openPanel">打开面板</button>
      <button class="btn outline"   @click="$emit('refresh')">刷新</button>
    </div>
    <div v-if="ctrlMsg" class="msg" :class="ctrlMsgType">{{ ctrlMsg }}</div>
  </div>
</template>