<script setup>
defineProps({ logs: String, logInfo: String })
defineEmits(['loadLog'])
</script>

<template>
  <div class="groupbox">
    <span class="groupbox-title">运行日志</span>
    <div class="btn-row" style="margin-bottom:4px;">
      <button class="btn outline" style="flex:none;min-width:auto;padding:4px 12px;font-size:12px;" @click="$emit('loadLog')">加载日志</button>
      <span style="font-size:11px;color:#999;align-self:center;" v-if="logInfo">{{ logInfo }}</span>
    </div>
    <div class="log-box">{{ logs || '# 点击"加载日志"查看' }}</div>
  </div>
</template>