"""Temporary socket tests of the real helper; never contact provider runtimes."""
import base64, json, os, pathlib, socket, subprocess, tempfile, threading, unittest

HELPER = pathlib.Path(__file__).resolve().parents[2] / '.build/debug/refikHook'
PERMISSION = dict(session_id='fixture-session', turn_id='fixture-turn', hook_event_name='PermissionRequest', tool_name='Bash', tool_input={'command': 'printf fixture'})
QUESTION = dict(session_id='fixture-session', hook_event_name='PreToolUse', tool_name='AskUserQuestion', tool_use_id='fixture-tool', tool_input={'questions': [{'question': 'Choose?', 'header': 'Choice', 'options': [{'label': 'A', 'description': 'First'}, {'label': 'B', 'description': 'Second'}], 'multiSelect': False}]})

class HelperTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture_directory = tempfile.TemporaryDirectory(prefix='refik-provider-')
        cls.fixture = pathlib.Path(cls.fixture_directory.name)
        for provider in ('claude', 'codex'):
            subprocess.run(['/usr/bin/cc', str(pathlib.Path(__file__).with_name('provider_fixture.c')), '-o', str(cls.fixture/provider)], check=True)
    @classmethod
    def tearDownClass(cls): cls.fixture_directory.cleanup()

    def run_hook(self, payload=PERMISSION, mode='allow', provider='claude', token='secret', stdout=subprocess.PIPE, configured_version=None, proven_parent=True, actual_version=None):
        with tempfile.TemporaryDirectory(prefix='refik-wire-') as directory:
            path = pathlib.Path(directory)
            (path/'signal.token').write_text('secret'); os.chmod(path/'signal.token', 0o600)
            server = socket.socket(socket.AF_UNIX); server.bind(str(path/'events.sock')); os.chmod(path/'events.sock', 0o600); server.listen()
            observed = {}
            def serve():
                client, _ = server.accept(); client.settimeout(3)
                with client:
                    stream = client.makefile('rb'); hello = json.loads(stream.readline()); observed['hello'] = hello
                    if hello.get('type') != 'request': return
                    if mode == 'reject': return
                    identity = hello['identity']; epoch = 'fixture-epoch'
                    ready = dict(protocolVersion=1, type='ready', identity=identity, epoch=epoch, lease=0.15 if mode == 'timeout' else 2)
                    if mode == 'missing-wire': ready.pop('protocolVersion')
                    if mode == 'unknown-wire': ready['protocolVersion'] = 999
                    if mode == 'wrong-ready': ready['identity'] = dict(identity, requestToken='wrong')
                    client.sendall(json.dumps(ready).encode()+b'\n')
                    if mode in ('timeout', 'wrong-ready', 'missing-wire', 'unknown-wire'):
                        try: observed['tail'] = stream.readline()
                        except (TimeoutError, OSError): pass
                        return
                    event = json.loads(base64.b64decode(hello['payload'])); response = dict(identity=event['requestSnapshot']['identity'])
                    if payload.get('tool_name') == 'AskUserQuestion': response['answers'] = [dict(questionID='q0', optionIDs=['o1'])]
                    else: response['permissionDecision'] = mode if mode in ('allow', 'deny') else 'allow'
                    decision = dict(protocolVersion=1, type='decision', identity=identity, epoch=epoch, actionID='4ae43f49-33a4-42fa-87db-a50b0a7dd833', payload=base64.b64encode(json.dumps(response).encode()).decode())
                    if mode == 'wrong-identity': decision['identity'] = dict(identity, sessionID='different')
                    if mode == 'wrong-epoch': decision['epoch'] = 'old'
                    encoded = json.dumps(decision).encode()+b'\n'
                    if mode == 'fragment':
                        for i in range(0,len(encoded),7): client.sendall(encoded[i:i+7])
                    elif mode == 'eof': client.sendall(encoded[:-1]); return
                    else: client.sendall(encoded)
                    try:
                        ack = stream.readline(); observed['ack'] = json.loads(ack) if ack else None
                    except (TimeoutError, OSError): pass
            thread = threading.Thread(target=serve); thread.start()
            if actual_version is not None:
                variant_parent = path/provider
                macro = 'CLAUDE_VERSION' if provider == 'claude' else 'CODEX_VERSION'
                subprocess.run(['/usr/bin/cc', str(pathlib.Path(__file__).with_name('provider_fixture.c')), '-D' + macro + '=' + json.dumps(actual_version), '-o', str(variant_parent)], check=True)
            else: variant_parent = self.fixture/provider
            command = ([str(variant_parent)] if proven_parent else []) + [str(HELPER), provider, payload['hook_event_name'], '--interactive', '--runtime-version=' + (configured_version if configured_version is not None else ('2.1.287' if provider == 'claude' else '0.159.2'))]
            process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=stdout, stderr=subprocess.PIPE, env=dict(os.environ, REFIK_DATA_DIR=directory))
            out, err = process.communicate(json.dumps(payload).encode(),timeout=5)
            thread.join(timeout=4); server.close()
            self.assertFalse(thread.is_alive()); self.assertEqual(process.returncode,0); self.assertEqual(err,b'')
            return out, observed
    def test_unsupported_or_unproven_runtime_is_passive(self):
        for version in ('', '9.99.99', 'hook-wire-1'):
            out, observed = self.run_hook(configured_version=version)
            self.assertEqual(out,b''); self.assertNotEqual(observed['hello'].get('type'),'request')
            self.assertNotIn('capabilities',observed['hello']); self.assertNotIn('version',observed['hello']['runtime'])
        out, observed = self.run_hook(proven_parent=False)
        self.assertEqual(out,b''); self.assertNotEqual(observed['hello'].get('type'),'request')
        self.assertNotIn('version',observed['hello']['runtime'])
    def test_actual_prerelease_and_junk_versions_are_passive(self):
        for provider, actual in [('claude','2.1.287-beta.1'), ('claude','2.1.287+custom'), ('claude','2.1.287a'), ('codex','0.159.2-custom'), ('codex','junk0.159.2')]:
            out, observed = self.run_hook(provider=provider, actual_version=actual)
            self.assertEqual(out,b'',actual); self.assertNotEqual(observed['hello'].get('type'),'request',actual)
            self.assertNotIn('capabilities',observed['hello']); self.assertNotIn('version',observed['hello']['runtime'])
    def test_permission_allow_and_deny(self):
        for provider in ('claude','codex'):
            for decision in ('allow','deny'):
                out, observed = self.run_hook(mode=decision, provider=provider)
                self.assertEqual(json.loads(out)['hookSpecificOutput']['decision'], {'behavior':decision})
                self.assertEqual(observed['ack']['type'],'consumed')
    def test_question_exact_native_schema(self):
        out, observed = self.run_hook(QUESTION,mode='fragment')
        specific = json.loads(out)['hookSpecificOutput']
        self.assertEqual(specific['permissionDecision'],'allow'); self.assertEqual(specific['updatedInput']['answers'],{'Choose?':'B'})
        event=json.loads(base64.b64decode(observed['hello']['payload']))
        self.assertEqual(event['requestTurnScope'],'hookInvocation'); self.assertTrue(event['turnID'].startswith('hook:'))
    def test_fallback_no_decision(self):
        for mode in ('reject','wrong-ready','wrong-identity','wrong-epoch','eof','timeout','missing-wire','unknown-wire'):
            out, observed = self.run_hook(mode=mode)
            self.assertEqual(out,b'',mode); self.assertIsNone(observed.get('ack'),mode)
    def test_stdout_failure_has_no_consumed_ack(self):
        readfd, writefd = os.pipe(); os.close(readfd)
        try:
            out, observed = self.run_hook(stdout=writefd)
            self.assertIsNone(observed.get('ack'))
        finally: os.close(writefd)
    def test_passive_provider(self):
        payload=dict(session_id='fixture',turn_id='turn',hook_event_name='PostToolUse',tool_name='Bash',tool_input={})
        out, observed=self.run_hook(payload)
        self.assertEqual(out,b''); self.assertEqual(observed['hello']['kind'],'requestResolved'); self.assertNotIn('requestSnapshot',observed['hello'])

if __name__ == '__main__': unittest.main()
