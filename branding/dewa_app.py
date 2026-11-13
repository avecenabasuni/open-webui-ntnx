"""ASGI entry point for the licensed, small internal DEWA deployment."""

import os
from html import escape

import open_webui.env as upstream_env

if upstream_env.VERSION != "0.13.3":
    raise RuntimeError("DEWA branding requires Open WebUI 0.13.3; review before upgrading.")
if os.environ.get("CUSTOM_NAME"):
    raise RuntimeError("Unset legacy CUSTOM_NAME; this deployment uses local DEWA assets.")

# Set identity before config/main import it. No upstream source or bundle rewriting.
upstream_env.WEBUI_NAME = os.environ.get("DEWA_APP_NAME", "DEWA").strip() or "DEWA"
upstream_env.WEBUI_FAVICON_URL = (
    os.environ.get("WEBUI_URL", "").rstrip("/") + "/static/favicon.png"
)

from open_webui.main import app as upstream_app  # noqa: E402

upstream_app.title = upstream_env.WEBUI_NAME
upstream_app.state.WEBUI_NAME = upstream_env.WEBUI_NAME


class BrandedShell:
    """Render the initial HTML title consistently with the runtime API identity."""

    def __init__(self, application, name):
        self.application = application
        self.title_tag = f"<title>{escape(name)}</title>".encode()

    def __getattr__(self, name):
        return getattr(self.application, name)

    async def __call__(self, scope, receive, send):
        headers = scope.get("headers", [])
        accepts_html = any(k.lower() == b"accept" and b"text/html" in v for k, v in headers)
        shell = scope.get("path") in ("/", "/auth") or accepts_html
        if scope["type"] != "http" or scope.get("method") != "GET" or not shell:
            return await self.application(scope, receive, send)

        # Only shell requests need identity encoding for the small HTML response.
        scope = dict(scope)
        scope["headers"] = [(k, v) for k, v in headers if k.lower() != b"accept-encoding"]
        scope["headers"].append((b"accept-encoding", b"identity"))
        pending = None
        chunks = []

        async def branded_send(message):
            nonlocal pending
            if message["type"] == "http.response.start":
                response_headers = dict(message.get("headers", []))
                if (b"text/html" in response_headers.get(b"content-type", b"")
                        and response_headers.get(b"content-encoding", b"identity") == b"identity"):
                    pending = message
                    return
            if pending is not None and message["type"] == "http.response.body":
                chunks.append(message.get("body", b""))
                if not message.get("more_body", False):
                    body = b"".join(chunks).replace(b"<title>Open WebUI</title>", self.title_tag)
                    new_headers = [(k, v) for k, v in pending.get("headers", [])
                                   if k.lower() not in (b"content-length", b"etag")]
                    new_headers.append((b"content-length", str(len(body)).encode()))
                    await send({**pending, "headers": new_headers})
                    await send({"type": "http.response.body", "body": body})
                    pending = None
                return
            await send(message)

        await self.application(scope, receive, branded_send)


app = BrandedShell(upstream_app, upstream_env.WEBUI_NAME)
