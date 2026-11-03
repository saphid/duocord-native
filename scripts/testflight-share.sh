#!/bin/zsh
# Finish an uploaded build on the existing internal TestFlight channel.
# BUILD=<number> [NOTES_FILE=<path>] scripts/testflight-share.sh
# Reuses existing internal groups only; does not create invitations/public links.
set -euo pipefail
cd "${0:A:h}/.."
export BUILD="${BUILD:?build number}"
python3 - <<'PYTHON'
import json, os, pathlib, subprocess, time
from urllib.parse import urlsplit

build_number = os.environ['BUILD']
if not build_number.isdigit():
    raise SystemExit('BUILD must contain only digits')
out = pathlib.Path('build/testflight') / build_number
out.mkdir(parents=True, exist_ok=True)

def api(method, path, body=None):
    args = ['node', 'scripts/asc.mjs', method, path]
    if body is not None:
        args.append(json.dumps(body))
    result = subprocess.run(args, capture_output=True, text=True, timeout=45)
    status, _, payload = result.stdout.partition('\n')
    try:
        data = json.loads(payload) if payload.strip() else {}
    except ValueError:
        raise SystemExit('App Store Connect returned an unreadable response')
    if result.returncode != 0:
        codes = ', '.join(str(e.get('code', 'unknown')) for e in data.get('errors', []))
        raise SystemExit('App Store Connect request failed: HTTP ' + status + ' ' + codes)
    return data

def collection(path):
    rows, visited = [], set()
    while path:
        link = urlsplit(path)
        if link.scheme not in ('', 'https') or link.netloc not in ('', 'api.appstoreconnect.apple.com') or not link.path.startswith('/v1/') or link.fragment:
            raise SystemExit('Unexpected App Store Connect pagination link')
        path = link.path + ('?' + link.query if link.query else '')
        if path in visited or len(visited) >= 1000:
            raise SystemExit('App Store Connect pagination did not terminate')
        visited.add(path)
        page = api('GET', path)
        data = page.get('data', [])
        if not isinstance(data, list):
            raise SystemExit('Expected an App Store Connect collection')
        rows.extend(data)
        path = page.get('links', {}).get('next')
    return rows

apps = api('GET', '/v1/apps?filter%5BbundleId%5D=com.saphid.duocord').get('data', [])
if len(apps) != 1:
    raise SystemExit('Expected exactly one existing Duocord app record')
app_id = apps[0]['id']
deadline = time.monotonic() + 600
while True:
    rows = api('GET', '/v1/builds?filter%5Bapp%5D=' + app_id + '&filter%5Bversion%5D=' + build_number).get('data', [])
    if len(rows) > 1:
        raise SystemExit('Multiple builds matched; refusing ambiguous delivery')
    build = rows[0] if rows else None
    state = build['attributes']['processingState'] if build else 'MISSING'
    print('Build ' + build_number + ': ' + state, flush=True)
    if state == 'VALID':
        break
    if state in ('FAILED', 'INVALID'):
        raise SystemExit('Apple rejected build processing')
    if time.monotonic() >= deadline:
        (out / 'delivery.json').write_text(json.dumps({'build': build_number, 'app_id': app_id, 'processing_state': state, 'status': 'processing_pending'}, indent=2) + '\n')
        raise SystemExit(75)
    time.sleep(20)

build_id = build['id']
notes_file = os.environ.get('NOTES_FILE')
if notes_file:
    notes = pathlib.Path(notes_file).read_text().strip()
    if not notes or len(notes) > 4000:
        raise SystemExit('Release notes must contain 1 to 4000 characters')
    localizations = collection('/v1/builds/' + build_id + '/betaBuildLocalizations')
    existing = next((x for x in localizations if x['attributes'].get('locale') == 'en-US'), None)
    if existing:
        api('PATCH', '/v1/betaBuildLocalizations/' + existing['id'], {'data': {'type': 'betaBuildLocalizations', 'id': existing['id'], 'attributes': {'whatsNew': notes}}})
    else:
        api('POST', '/v1/betaBuildLocalizations', {'data': {'type': 'betaBuildLocalizations', 'attributes': {'locale': 'en-US', 'whatsNew': notes}, 'relationships': {'build': {'data': {'type': 'builds', 'id': build_id}}}}})

groups = collection('/v1/apps/' + app_id + '/betaGroups')
internal = [g for g in groups if g['attributes'].get('isInternalGroup')]
if not internal:
    raise SystemExit('No existing internal TestFlight group; no audience was created')
verified = []
for group in internal:
    path = '/v1/betaGroups/' + group['id'] + '/relationships/builds'
    linked = collection(path)
    if not any(x['id'] == build_id for x in linked):
        api('POST', path, {'data': [{'type': 'builds', 'id': build_id}]})
    linked = collection(path)
    if not any(x['id'] == build_id for x in linked):
        raise SystemExit('TestFlight group assignment did not persist')
    verified.append({'id': group['id'], 'name': group['attributes']['name']})
detail = api('GET', '/v1/builds/' + build_id + '/buildBetaDetail')['data']
internal_state = detail['attributes'].get('internalBuildState')
receipt = {'app_id': app_id, 'bundle_id': 'com.saphid.duocord', 'build': build_number, 'build_id': build_id, 'processing_state': state, 'internal_state': internal_state, 'groups': verified}
(out / 'delivery.json').write_text(json.dumps(receipt, indent=2) + '\n')
print(json.dumps(receipt), flush=True)
if internal_state != 'IN_BETA_TESTING':
    raise SystemExit(75)
PYTHON
