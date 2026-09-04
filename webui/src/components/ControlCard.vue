<script setup>
import { ref } from 'vue'
import { baihu } from '../kernelsu.js'

const props = defineProps({ containerRunning: Boolean })
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
    const stdout = r.stdout || ''
    if (stdout.includes('成功') || stdout.includes('PID')) {
      ctrlMsg.value = '面板已启动'; ctrlMsgType.value = 'success'
      emit('refresh')
    } else if (stdout.includes('已在运行')) {
      ctrlMsg.value = '面板已在运行中'; ctrlMsgType.value = 'info'
    } else {
      ctrlMsg.value = stdout.substring(0, 300); ctrlMsgType.value = 'info'
    }
  } catch (e) {
    ctrlMsg.value = '启动失败: ' + (e.message || '未知错误'); ctrlMsgType.value = 'error'
  } finally { starting.value = false }
}

async function doStop() {
  stopping.value = true
  ctrlMsg.value = '正在停止面板...'
  ctrlMsgType.value = 'info'
  try {
    const r = await baihu.stop()
    ctrlMsg.value = '面板已停止'; ctrlMsgType.value = 'success'
    emit('refresh')
  } catch (e) {
    ctrlMsg.value = '停止失败: ' + (e.message || '未知错误'); ctrlMsgType.value = 'error'
  } finally { stopping.value = false }
}

function openPanel() {
  const url = 'http://127.0.0.1:8052/'
  const w = window.open(url)
  if (!w || w.closed) ctrlMsg.value = '请手动访问: ' + url
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