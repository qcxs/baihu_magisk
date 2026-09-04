<script setup>
defineProps({ password: String })
</script>

<template>
  <div class="groupbox">
    <span class="groupbox-title">管理员密码</span>
    <div class="password-box">{{ password }}</div>
    <div style="font-size:12px;color:#999;text-align:center;">首次启动后约1分钟生成</div>
  </div>
</template>