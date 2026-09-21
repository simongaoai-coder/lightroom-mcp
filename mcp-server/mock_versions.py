"""Development-only version/preset simulator; production Lua has separate SDK tests."""
from copy import deepcopy


class MockVersions:
    def __init__(self, backend):
        self.backend = backend
        self.photo_id = 'mock-photo-1'
        self.snapshots = {}
        self.next_snapshot = 1
        self.copies = []
        self.presets = [
            {'presetId': 'preset-warm', 'name': '暖色', 'folder': 'User Presets', 'pluginOwned': False},
            {'presetId': 'preset-cool', 'name': 'Cool', 'folder': 'User Presets', 'pluginOwned': False},
        ]

    def error(self, code):
        return {'success': False, 'code': code, 'error': code.replace('_', ' ')}

    def handle(self, req):
        cmd = req['command']
        if cmd != 'list_presets' and req.get('expectedPhotoId', self.photo_id) != self.photo_id:
            return self.error('photo_changed')
        data = {'photoId': self.photo_id}
        if cmd == 'list_presets':
            query = req.get('query', '').lower()
            items = [p for p in self.presets if query in (p['name']+' '+p['folder']).lower()]
            items.sort(key=lambda p: (p['folder'], p['name'], p['presetId']))
            offset, limit = req.get('offset', 0), req.get('limit', 50)
            page = items[offset:offset+limit]
            return {'success': True, 'data': {'presets': page, 'total': len(items), 'offset': offset,
                                             'hasMore': offset+len(page) < len(items)}}
        if cmd == 'save_style':
            if any(p['name'].lower() == req['name'].lower() and p['pluginOwned'] for p in self.presets):
                return self.error('style_exists')
            entry = {'presetId': f'style-{len(self.presets)}', 'name': req['name'], 'folder': 'Lightroom MCP', 'pluginOwned': True}
            self.presets.append(entry)
            return {'success': True, 'data': {**entry, 'persistent': True}}
        if cmd == 'create_snapshot':
            entries = self.snapshots.setdefault(self.photo_id, {})
            existing = next((s for s in entries.values() if s['name'] == req['name']), None)
            if existing and not req.get('updateExisting'):
                return self.error('snapshot_exists')
            snapshot_id = f'snapshot-{self.next_snapshot}'
            self.next_snapshot += 1
            global_id = existing['globalId'] if existing else 'global-'+snapshot_id
            if existing:
                del entries[existing['snapshotId']]
            item = {'snapshotId': snapshot_id, 'globalId': global_id,
                    'name': req['name'], 'settings': deepcopy(self.backend.settings)}
            entries[snapshot_id] = item
            data.update({k: v for k, v in item.items() if k != 'settings'})
            data['status'] = 'updated' if existing else 'created'
        elif cmd == 'list_snapshots':
            data['snapshots'] = [{k: v for k, v in item.items() if k != 'settings'}
                                 for item in self.snapshots.get(self.photo_id, {}).values()]
        elif cmd in {'apply_snapshot', 'delete_snapshot'}:
            entries = self.snapshots.get(self.photo_id, {})
            item = entries.get(req['snapshotId'])
            if not item:
                return self.error('snapshot_not_found')
            if cmd == 'apply_snapshot':
                self.backend.settings = deepcopy(item['settings'])
                data['status'] = 'applied'
            else:
                del entries[req['snapshotId']]
                data['status'] = 'deleted'
            data['snapshotId'] = req['snapshotId']
        elif cmd == 'apply_preset':
            if not any(p['presetId'] == req['presetId'] for p in self.presets):
                return self.error('preset_not_found')
            self.backend.settings['Temperature'] = 7200 if req['presetId'] == 'preset-warm' else 4800
            count = len(self.backend.photos) if req.get('scope') == 'selected' else 1
            return {'success': True, 'applied': count, 'failed': 0, 'notAttempted': 0,
                    'data': {'presetId': req['presetId'], 'aiUpdateRequested': req.get('updateAISettings', False),
                             'results': [{'photoId': self.photo_id, 'success': True,
                                          'changedKeys': ['Temperature'], 'verification': 'sdk_completed_and_observed'}]}}
        elif cmd == 'create_virtual_copies':
            copy = {'photoId': 'copy-'+str(len(self.copies)+1), 'masterPhotoId': 'mock-photo-1',
                    'isVirtualCopy': True, 'copyName': req.get('copyName', 'Copy')}
            self.copies.append(copy)
            self.photo_id = copy['photoId']
            data.update(created=[copy], count=1, selectedPhotoId=self.photo_id, status='created')
        elif cmd == 'list_virtual_copies':
            data['versions'] = [{'photoId': 'mock-photo-1', 'masterPhotoId': 'mock-photo-1', 'isVirtualCopy': False, 'copyName': ''}, *self.copies]
        elif cmd == 'select_virtual_copy':
            if req['photoId'] not in {'mock-photo-1', *(c['photoId'] for c in self.copies)}:
                return self.error('copy_not_found')
            self.photo_id = req['photoId']
            data['photoId'] = self.photo_id
        return {'success': True, 'data': deepcopy(data)}
