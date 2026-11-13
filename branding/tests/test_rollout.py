"""Run without Docker or cluster access: python3 -m unittest discover -s branding/tests."""

import importlib.util
import asyncio
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import types
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]


class IdentityTests(unittest.TestCase):
    def load_app(self, version="0.13.3", **environment):
        package = types.ModuleType("open_webui")
        package.__path__ = []
        env = types.ModuleType("open_webui.env")
        env.VERSION = version
        env.WEBUI_NAME = "Open WebUI"
        main = types.ModuleType("open_webui.main")
        main.app = types.SimpleNamespace(state=types.SimpleNamespace())
        modules = {"open_webui": package, "open_webui.env": env, "open_webui.main": main}
        spec = importlib.util.spec_from_file_location("dewa_app", ROOT / "branding/dewa_app.py")
        module = importlib.util.module_from_spec(spec)
        with patch.dict(sys.modules, modules), patch.dict(os.environ, environment, clear=True):
            spec.loader.exec_module(module)
        return env, module.app

    def test_runtime_identity_and_public_favicon(self):
        env, app = self.load_app(WEBUI_URL="https://openwebui.bercalab.my.id/")
        self.assertEqual(app.state.WEBUI_NAME, "DEWA")
        self.assertEqual(app.title, "DEWA")
        self.assertEqual(env.WEBUI_NAME, "DEWA")
        self.assertEqual(env.WEBUI_FAVICON_URL, "https://openwebui.bercalab.my.id/static/favicon.png")

    def test_other_upstream_versions_require_review(self):
        with self.assertRaisesRegex(RuntimeError, "requires Open WebUI 0.13.3"):
            self.load_app(version="0.14.0")

    def test_legacy_remote_branding_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, "CUSTOM_NAME"):
            self.load_app(CUSTOM_NAME="remote-brand")

    def test_initial_html_title_across_streamed_chunks(self):
        _, app = self.load_app()
        messages = []
        observed = []

        async def upstream(scope, receive, send):
            observed.append(scope)
            await send({'type': 'http.response.start', 'status': 200, 'headers': [
                (b'content-type', b'text/html; charset=utf-8'), (b'etag', b'old'),
                (b'content-length', b'999'),
            ]})
            await send({'type': 'http.response.body', 'body': b'<title>Open ', 'more_body': True})
            await send({'type': 'http.response.body', 'body': b'WebUI</title><main>Login</main>'})

        async def send(message):
            messages.append(message)

        app.application = upstream
        asyncio.run(app({'type': 'http', 'method': 'GET', 'path': '/auth', 'headers': [
            (b'accept-encoding', b'gzip'),
        ]}, None, send))
        self.assertEqual(len(messages), 2)
        self.assertEqual(messages[1]['body'], b'<title>DEWA</title><main>Login</main>')
        headers = dict(messages[0]['headers'])
        self.assertEqual(int(headers[b'content-length']), len(messages[1]['body']))
        self.assertNotIn(b'etag', headers)
        self.assertEqual(dict(observed[0]['headers'])[b'accept-encoding'], b'identity')

    def test_chat_sse_is_forwarded_without_buffering_or_header_changes(self):
        _, app = self.load_app()
        scope = {'type': 'http', 'method': 'POST', 'path': '/api/chat/completions',
                 'headers': [(b'accept-encoding', b'gzip')]}
        events = [{'type': 'http.response.start', 'status': 200,
                   'headers': [(b'content-type', b'text/event-stream')]},
                  {'type': 'http.response.body', 'body': b'data: first\n\n', 'more_body': True},
                  {'type': 'http.response.body', 'body': b'data: [DONE]\n\n'}]
        sent = []

        async def upstream(received_scope, receive, send):
            self.assertIs(received_scope, scope)
            for event in events:
                await send(event)

        async def send(message):
            sent.append(message)

        app.application = upstream
        asyncio.run(app(scope, None, send))
        self.assertEqual(sent, events)

    def test_websocket_scope_is_forwarded_intact(self):
        _, app = self.load_app()
        scope = {'type': 'websocket', 'path': '/ws/socket.io'}
        observed = []

        async def upstream(received_scope, receive, send):
            observed.append(received_scope)

        app.application = upstream
        asyncio.run(app(scope, None, None))
        self.assertIs(observed[0], scope)


class RolloutTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.bash = os.environ.get("BASH_TEST_BIN") or shutil.which("bash")
        if not cls.bash:
            raise unittest.SkipTest("Bash is required for rollout simulations.")

    def run_rollout(self, failure="", bad_mount=False):
        with tempfile.TemporaryDirectory(prefix="dewa-rollout-test-") as temp:
            root = Path(temp)
            (root / "kubectl").write_text(
                '#!/usr/bin/env bash\nexec "$DEWA_TEST_PYTHON" "$DEWA_TEST_DRIVER" "$@"\n',
                encoding="utf-8",
            )
            (root / "python3").write_text(
                '#!/usr/bin/env bash\nexec "$DEWA_TEST_PYTHON" "$@"\n', encoding="utf-8"
            )
            for name in ("kubectl", "python3"):
                (root / name).chmod(0o755)
            driver = root / "fake_kubectl.py"
            driver.write_text(FAKE_KUBECTL, encoding="utf-8")
            environment = dict(os.environ)
            environment.update(
                PATH=str(root) + os.pathsep + environment["PATH"],
                DEWA_TEST_PYTHON=Path(sys.executable).as_posix(),
                DEWA_TEST_DRIVER=driver.as_posix(),
                DEWA_TEST_LOG=(root / "calls.jsonl").as_posix(),
                DEWA_TEST_FAILURE=failure,
                DEWA_TEST_BAD_MOUNT="yes" if bad_mount else "",
                BACKUP_ROOT=(root / "backups").as_posix(),
                DEWA_IMAGE="registry.bercalab.my.id/chatbot/open-webui:v0.13.3-dewa1",
            )
            result = subprocess.run(
                [self.bash, (ROOT / "branding/rollout.sh").as_posix()],
                env=environment, capture_output=True, text=True, timeout=60,
            )
            calls = [json.loads(line) for line in (root / "calls.jsonl").read_text().splitlines()]
            backups = list((root / "backups").glob("*/data.tar.gz"))
            if backups:
                with tarfile.open(backups[0]) as archive:
                    self.assertEqual(archive.extractfile("data/webui.db").read(), b"existing-data")
            return result, [" ".join(call) for call in calls], bool(backups)

    def test_backup_finishes_before_image_change(self):
        result, calls, backed_up = self.run_rollout()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(backed_up)
        stop = next(i for i, call in enumerate(calls) if "scale deployment/open-webui --replicas=0" in call)
        backup = next(i for i, call in enumerate(calls) if " exec " in call)
        delete = next(i for i, call in enumerate(calls) if "delete pod dewa-backup-" in call)
        image = next(i for i, call in enumerate(calls) if "set image deployment/open-webui" in call)
        start = next(i for i, call in enumerate(calls) if "scale deployment/open-webui --replicas=1" in call)
        self.assertTrue(stop < backup < delete < image < start)
        self.assertFalse(any("delete pvc" in c or "apply " in c or "chatbot-prod" in c for c in calls))

    def test_failed_backup_restores_old_image_without_deploying_new_one(self):
        result, calls, backed_up = self.run_rollout(failure="backup")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(backed_up)
        image_changes = [c for c in calls if "set image" in c]
        self.assertEqual(len(image_changes), 1)
        self.assertIn("open-webui=old-image:v0.13.3", image_changes[0])
        self.assertTrue(any("--replicas=1" in c for c in calls))

    def test_failed_new_rollout_restores_original_image(self):
        result, calls, backed_up = self.run_rollout(failure="rollout")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(backed_up)
        changes = [c for c in calls if "set image" in c]
        self.assertEqual(len(changes), 2)
        self.assertIn("dewa1", changes[0])
        self.assertIn("old-image:v0.13.3", changes[1])

    def test_wrong_data_mount_stops_before_mutating_cluster(self):
        result, calls, _ = self.run_rollout(bad_mount=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(" scale " in c or " set image " in c or " create " in c for c in calls))


FAKE_KUBECTL = r'''
import io, json, os, sys, tarfile
args = sys.argv[1:]
with open(os.environ['DEWA_TEST_LOG'], 'a') as log:
    log.write(json.dumps(args) + '\n')
call = ' '.join(args)
if call == 'config current-context':
    print('mock-nutanix')
elif 'get deployment open-webui -o json' in call:
    print(json.dumps({'spec': {'replicas': 1, 'strategy': {'type': 'Recreate'}, 'template': {'spec': {
        'containers': [{'name': 'open-webui', 'image': 'old-image:v0.13.3', 'volumeMounts': [
            {'name': 'data', 'mountPath': '/wrong' if os.environ['DEWA_TEST_BAD_MOUNT'] else '/app/backend/data'}]}],
        'volumes': [{'name': 'data', 'persistentVolumeClaim': {'claimName': 'open-webui-data'}}],
        'imagePullSecrets': [{'name': 'harbor-secret'}],
    }}}}))
elif 'get pods ' in call:
    print(json.dumps({'items': [{'metadata': {}, 'spec': {'nodeName': 'worker-1'}, 'status': {
        'phase': 'Running', 'containerStatuses': [{'name': 'open-webui', 'ready': True}],
    }}]}))
elif ' exec ' in call:
    if os.environ['DEWA_TEST_FAILURE'] == 'backup':
        sys.exit(3)
    with tarfile.open(fileobj=sys.stdout.buffer, mode='w|gz') as archive:
        content = b'existing-data'
        member = tarfile.TarInfo('data/webui.db')
        member.size = len(content)
        archive.addfile(member, io.BytesIO(content))
elif 'rollout status ' in call and os.environ['DEWA_TEST_FAILURE'] == 'rollout':
    sys.exit(4)
else:
    print('ok')
'''


if __name__ == "__main__":
    unittest.main()
