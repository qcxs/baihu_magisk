// KernelSU bridge wrapper — single shared instance of ksu.exec
// Correct API: ksu.exec(cmd, optionsJSON, callbackName)
// callback is stored on window[callbackName] and called as:
//   callback(errno, stdout, stderr)

const ksu = window.ksu || (window.apatch ? { exec: window.apatch.exec } : null)

export function hasBridge() {
  return !!ksu
}

export function getEnvName() {
  if (window.apatch) return 'APatch'
  if (ksu) return ksu.apilevel ? 'KernelSU' : 'Magisk'
  return null
}

export function execCmd(cmd) {
  if (!ksu) return Promise.reject(new Error('No bridge'))
  return new Promise((resolve, reject) => {
    const cbName = 'ksu_cb_' + Date.now() + '_' + Math.random().toString(36).slice(2, 8)
    window[cbName] = (code, stdout, stderr) => {
      delete window[cbName]
      resolve({ errno: code, stdout: stdout || '', stderr: stderr || '' })
    }
    try {
      ksu.exec(cmd, '{}', cbName)
    } catch (e) {
      delete window[cbName]
      reject(e)
    }
  })
}

// --- Baihu API ---
const MODULE_ID = 'baihu_qcxs'
const MODULE_DIR = '/data/adb/modules/' + MODULE_ID

export const baihu = {
  exec(subcmd) {
    return execCmd('sh ' + MODULE_DIR + '/bin/baihu ' + subcmd + ' 2>/dev/null')
  },
  status()       { return this.exec('status') },
  password()     { return this.exec('password') },
  start()        { return this.exec('start') },
  stop()         { return this.exec('stop') },
  runLog(lines)  { return execCmd('tail -n ' + (lines || 50) + ' /data/baihu/run.log 2>/dev/null') },
  moduleProp()   { return execCmd('cat ' + MODULE_DIR + '/module.prop 2>/dev/null') },
  portCheck()    { return execCmd('ss -tlnp 2>/dev/null | grep :8052 || netstat -tlnp 2>/dev/null | grep :8052 || echo "not listening"') },
}