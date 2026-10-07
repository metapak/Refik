'use strict';
const crypto = require('crypto');
const os = require('os');
const path = require('path');
const childProcess = require('child_process');
function create(vscode, spawn = childProcess.spawn, timers = globalThis) {
  const windowID = crypto.randomUUID(), generation = crypto.randomUUID();
  let sequence = 0, child, timer, disposed = false, retry;
  const helper = path.join(os.homedir(), 'Library', 'Application Support', 'refik', 'refikHook');
  function observation() {
    const folders = vscode.workspace.workspaceFolders;
    const local = !vscode.env.remoteName && vscode.env.uiKind === vscode.UIKind.Desktop &&
      folders?.length === 1 && folders[0].uri.scheme === 'file' && !folders[0].uri.authority;
    const root = local ? folders[0].uri.fsPath : undefined;
    const focused = Boolean(vscode.window.state.focused && root && path.isAbsolute(root) && root !== path.parse(root).root);
    return {windowID, generation, sequence: ++sequence, focused, projectPath: focused ? root : null};
  }
  function write(message) {if (!disposed && child?.stdin.writable) child.stdin.write(JSON.stringify(message) + '\n');}
  function poll() {write({type: 'poll'});}
  function changed() {
    const state = observation();
    if (!state.focused) write({type: 'blur', observation: state});
    else poll();
  }
  function workspaceChanged() {
    const state = observation();
    // Root changes revoke the previous project even when both roots are valid.
    write({type: 'blur', observation: {...state, focused: false, projectPath: null}});
    if (state.focused) poll();
  }
  function connect() {
    if (disposed) return;
    child = spawn(helper, ['--editor-focus-stream'], {stdio: ['pipe', 'pipe', 'ignore'], env: {HOME: os.homedir(), PATH: '/usr/bin:/bin'}});
    child.stdin.on('error', () => {});
    const current = child; let ended = false, buffer = '';
    const close = () => {
      if (ended || disposed || current !== child) return;
      ended = true; child = undefined; retry = timers.setTimeout(connect, 3000);
    };
    child.on('error', close); child.on('exit', close);
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', bytes => {
      if (disposed || current !== child) return;
      buffer += bytes;
      if (buffer.length > 4096) {current.kill(); return;}
      let newline;
      while ((newline = buffer.indexOf('\n')) !== -1) {
        const line = buffer.slice(0, newline); buffer = buffer.slice(newline + 1);
        let challenge; try {challenge = JSON.parse(line);} catch {current.kill(); return;}
        if (challenge.type !== 'challenge' || typeof challenge.epoch !== 'string' || typeof challenge.nonce !== 'string') {current.kill(); return;}
        // Snapshot only after the authenticated server's fresh challenge.
        write({type: 'response', epoch: challenge.epoch, nonce: challenge.nonce, observation: observation()});
      }
    });
    poll();
  }
  const listeners = [vscode.window.onDidChangeWindowState(changed), vscode.workspace.onDidChangeWorkspaceFolders(workspaceChanged)];
  timer = timers.setInterval(poll, 2000); connect();
  return {dispose() {disposed = true; timers.clearInterval(timer); timers.clearTimeout(retry); for (const x of listeners) x.dispose(); child?.stdin.end(); child?.kill();}, observation};
}
function activate(context) {context.subscriptions.push(create(require('vscode')));}
module.exports = {activate, create};
