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

export function execCmd(cmd, timeout = 20000) {
  if (!ksu) return Promise.reject(new Error('No bridge'))
  return new Promise((resolve, reject) => {
    const cbName = 'ksu_cb_' + Date.now() + '_' + Math.random().toString(36).slice(2, 8)
    let done = false
    window[cbName] = (code, stdout, stderr) => {
      if (done) return
      done = true
      clearTimeout(timer)
      delete window[cbName]
      resolve({ errno: code, stdout: stdout || '', stderr: stderr || '' })
    }
    // Safety net: if the bridge never calls back (e.g. `baihu start` blocks on
    // network), reject so the UI can show feedback instead of hanging forever.
    const timer = setTimeout(() => {
      if (done) return
      done = true
      delete window[cbName]
      reject(new Error('命令执行超时'))
    }, timeout)
    try {
      ksu.exec(cmd, '{}', cbName)
    } catch (e) {
      clearTimeout(timer)
      if (done) return
      done = true
      delete window[cbName]
      reject(e)
    }
  })
}

// --- Baihu API ---
const MODULE_ID = 'baihu_qcxs'
const MODULE_DIR = '/data/adb/modules/' + MODULE_ID

export const baihu = {
  exec(subcmd, timeout) {
    return execCmd('sh ' + MODULE_DIR + '/bin/baihu ' + subcmd + ' 2>/dev/null', timeout)
  },
  status()       { return this.exec('status') },
  password()     { return this.exec('password') },
  // start has an internal network-wait (up to ~60s), so allow it a long budget
  start()        { return this.exec('start', 90000) },
  stop()         { return this.exec('stop', 90000) },
  runLog(lines)  { return execCmd('tail -n ' + (lines || 50) + ' /data/baihu/run.log 2>/dev/null') },
  moduleProp()   { return execCmd('cat ' + MODULE_DIR + '/module.prop 2>/dev/null') },
}