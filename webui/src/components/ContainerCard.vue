<script setup>
defineProps({
  containerRunning: Boolean,
  pid: String,
  uptime: String,
  mem: String,
  portListening: Boolean,
  panelPort: { type: String, default: '18052' },
  rootfsSize: String,
  dataSize: String,
})
</script>

<template>
  <div class="groupbox">
    <span class="groupbox-title">容器状态</span>
    <div class="status-row">
      <span class="status-label">
        <span class="status-dot" :class="containerRunning ? 'green' : 'gray'"></span>容器
      </span>
      <span class="status-value">{{ containerRunning ? '运行中' : '已停止' }}</span>
    </div>
    <div class="status-row">
      <span class="status-label">PID</span>
      <span class="status-value">{{ pid }}</span>
    </div>
    <div class="status-row">
      <span class="status-label">运行时间</span>
      <span class="status-value">{{ uptime }}</span>
    </div>
    <div class="status-row">
      <span class="status-label">内存占用</span>
      <span class="status-value">{{ mem }}</span>
    </div>
    <div class="status-row">
      <span class="status-label">端口 {{ panelPort }}</span>
      <span class="status-value">{{ portListening ? '监听中' : '未监听' }}</span>
    </div>
    <div class="status-row">
      <span class="status-label">rootfs</span>
      <span class="status-value">{{ rootfsSize }}</span>
    </div>
    <div class="status-row">
      <span class="status-label">数据目录</span>
      <span class="status-value">{{ dataSize }}</span>
    </div>
  </div>
</template>