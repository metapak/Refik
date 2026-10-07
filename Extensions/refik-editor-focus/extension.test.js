'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const {EventEmitter} = require('node:events');
const {create} = require('./extension');
function setup() {
  const callbacks = {}, sent = []; let killed = false, interval, retry, disposed = 0, spawned = 0;
  const vscode = {UIKind: {Desktop: 1}, env: {uiKind: 1}, window: {state: {focused: true}, onDidChangeWindowState(cb) {callbacks.focus = cb; return {dispose() {disposed++;}};}}, workspace: {workspaceFolders: [{uri: {scheme: 'file', authority: '', fsPath: '/tmp/refik-isolated'}}], onDidChangeWorkspaceFolders(cb) {callbacks.root = cb; return {dispose() {disposed++;}};}}};
  const children = [];
  function spawn(executable, args, options) {
    assert(executable.endsWith('/Library/Application Support/refik/refikHook'));
    assert.deepEqual(args, ['--editor-focus-stream']); assert(!options.shell); assert(!JSON.stringify(options).includes('/tmp/refik-isolated'));
    spawned++; const child = new EventEmitter(); child.stdin = new EventEmitter(); child.stdin.writable = true;
    child.stdin.write = bytes => sent.push(JSON.parse(bytes)); child.stdin.end = () => {};
    child.stdout = new EventEmitter(); child.stdout.setEncoding = () => {};
    child.kill = () => {killed = true;}; children.push(child); return child;
  }
  const timers = {setInterval(cb, ms) {assert.equal(ms, 2000); interval = cb; return 1;}, clearInterval() {interval = undefined;}, setTimeout(cb) {retry = cb; return 2;}, clearTimeout() {retry = undefined;}};
  const extension = create(vscode, spawn, timers);
  return {vscode, callbacks, sent, children, extension, pulse() {interval();}, reconnect() {retry();}, challenge() {children.at(-1).stdout.emit('data',JSON.stringify({type:'challenge',epoch:'epoch',nonce:'nonce'})+'\n');}, stats() {return {killed, disposed, spawned, interval, retry};}};
}
test('activation sends no positive snapshot before challenge; samples latest focus/root after challenge', () => {
  const x = setup(); assert.deepEqual(x.sent, [{type:'poll'}]);
  x.vscode.workspace.workspaceFolders[0].uri.fsPath = '/tmp/new-current'; x.challenge();
  const response = x.sent.at(-1); assert.equal(response.type,'response'); assert.equal(response.observation.projectPath,'/tmp/new-current'); assert.equal(response.epoch,'epoch'); assert.equal(response.nonce,'nonce');
  x.pulse(); x.vscode.window.state.focused = false; x.challenge(); assert.equal(x.sent.at(-1).observation.focused,false);
  x.extension.dispose();
});
test('blur immediately revokes; heartbeat sequence/generation remain increasing; deactivation closes helper', () => {
  const x = setup(); x.challenge(); const first = x.sent.at(-1).observation;
  x.pulse(); x.challenge(); const second = x.sent.at(-1).observation;
  x.vscode.window.state.focused = false; x.callbacks.focus(); const blur = x.sent.at(-1);
  assert.equal(blur.type,'blur'); assert.equal(blur.observation.focused,false); assert.equal(blur.observation.projectPath,null);
  assert(second.sequence > first.sequence); assert(blur.observation.sequence > second.sequence); assert.equal(second.generation, first.generation);
  x.extension.dispose(); assert.equal(x.stats().killed,true); assert.equal(x.stats().disposed,2); assert.equal(x.stats().interval,undefined);
});
test('remote, virtual, multiroot, empty, authority, and relative roots immediately invalidate', () => {
  const x = setup(); const original = x.vscode.workspace.workspaceFolders;
  for (const change of [() => x.vscode.env.remoteName='ssh', () => x.vscode.env.uiKind=2, () => x.vscode.workspace.workspaceFolders=[], () => x.vscode.workspace.workspaceFolders=[...original,...original], () => original[0].uri.scheme='vscode-remote', () => original[0].uri.authority='server', () => original[0].uri.fsPath='relative']) {
    x.vscode.env={uiKind:1}; x.vscode.workspace.workspaceFolders=original; original[0].uri={scheme:'file',authority:'',fsPath:'/tmp/refik-isolated'};
    change(); x.callbacks.root(); assert.equal(x.sent.at(-1).type,'blur'); assert.equal(x.sent.at(-1).observation.focused,false); assert.equal(x.sent.at(-1).observation.projectPath,null);
  }
  x.extension.dispose();
});
test('helper exit reconnects with same window/generation and increasing sequence; stale child challenge ignored', () => {
  const x = setup(); x.challenge(); const first=x.sent.at(-1).observation;
  x.children[0].emit('exit'); x.reconnect(); const count=x.sent.length;
  x.children[0].stdout.emit('data',JSON.stringify({type:'challenge',epoch:'old',nonce:'old'})+'\n'); assert.equal(x.sent.length,count);
  x.challenge(); const second=x.sent.at(-1).observation;
  assert.equal(second.windowID,first.windowID); assert.equal(second.generation,first.generation); assert(second.sequence>first.sequence); assert.equal(x.stats().spawned,2);
  x.extension.dispose(); x.children[1].emit('exit'); assert.equal(x.stats().retry,undefined);
});

test('valid root A to B revokes A immediately while the next challenge is delayed', () => {
  const x = setup(); x.challenge();
  const first = x.sent.at(-1).observation;
  assert.equal(first.projectPath, '/tmp/refik-isolated');
  const before = x.sent.length;
  x.vscode.workspace.workspaceFolders[0].uri.fsPath = '/tmp/project-B'; x.callbacks.root();
  const transition = x.sent.slice(before);
  assert.equal(transition.length, 2); assert.equal(transition[0].type, 'blur');
  assert.equal(transition[0].observation.focused, false); assert.equal(transition[0].observation.projectPath, null);
  assert(transition[0].observation.sequence > first.sequence); assert.deepEqual(transition[1], {type:'poll'});
  // Before a delayed fresh challenge, the wire contains no positive A or B proof.
  assert(!transition.some(x => x.type === 'response'));
  x.challenge(); const fresh = x.sent.at(-1).observation;
  assert.equal(fresh.projectPath, '/tmp/project-B'); assert(fresh.sequence > transition[0].observation.sequence);
  x.extension.dispose();
});
