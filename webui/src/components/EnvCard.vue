<script setup>
defineProps({
  envName: String,
  moduleVersion: String,
  containerRunning: Boolean,
})
</script>

<template>
  <div class="groupbox">
    <span class="groupbox-title">运行环境</span>
    <div class="status-row">
      <span class="status-label">环境类型</span>
      <span class="status-value">{{ envName }}</span>
    </div>
    <div class="status-row">
      <span class="status-label">模块版本</span>
      <span class="status-value">{{ moduleVersion }}</span>
    </div>
    <div class="status-row">
      <span class="status-label">面板状态</span>
      <span class="status-value">
        <span class="tag" :class="containerRunning ? 'running' : 'stopped'">
          {{ containerRunning ? '运行中' : '已停止' }}
        </span>
      </span>
    </div>
  </div>
</template>