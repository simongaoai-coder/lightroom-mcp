"""Smart-preview jobs and explicit per-photo relative develop deltas."""
from mcp import types

PREVIEW_COMMANDS = {f'lr_{n}': n for n in (
    'get_smart_previews', 'build_smart_previews', 'delete_smart_previews',
    'get_smart_preview_job', 'cancel_smart_preview_job',
)}
RELATIVE_COMMANDS = {'lr_batch_adjust_relative': 'batch_adjust_relative'}
RELATIVE_PARAMETERS = ('Exposure Contrast Highlights Shadows Whites Blacks Clarity '
                       'Texture Dehaze Vibrance Saturation Temperature Tint').split()


def workflow_tools():
    ident = {'type': 'string', 'minLength': 1, 'pattern': r'\S'}
    targets = {
        'expectedPhotoId': ident, 'expectedCatalogPath': ident,
        'photoIds': {'type': 'array', 'items': ident, 'minItems': 1, 'maxItems': 200, 'uniqueItems': True},
        'scope': {'type': 'string', 'enum': ['current', 'selected'], 'default': 'current'},
    }
    job = {'jobId': {'type': 'string', 'pattern': '^[a-f0-9]{32}$'}}
    paging = {'offset': {'type': 'integer', 'minimum': 0},
              'limit': {'type': 'integer', 'minimum': 1, 'maximum': 200}}
    specs = [
        ('get_smart_previews', 'Read SDK smart-preview presence/path/bytes and original availability for current, selected or explicit photos. Unknown preview metadata is an error, not absence.', targets, []),
        ('build_smart_previews', 'Start a session job creating native smart previews; existing previews are unchanged. All targets are preflighted; videos and missing originals without previews are rejected. Poll get_smart_preview_job. Selection may change after start without redirecting the captured targets.', targets, []),
        ('delete_smart_previews', 'Start a session job deleting only SDK smart previews, never original files. Missing previews are unchanged. Offline originals with previews require allowOffline=true. Poll get_smart_preview_job; cancellation occurs between photos.', {**targets, 'allowOffline': {'type': 'boolean', 'default': False}}, []),
        ('get_smart_preview_job', 'Read a smart-preview job and paginated results. Session-only, latest 20 retained. Unknown jobs do not prove no work occurred.', {**job, **paging}, ['jobId']),
        ('cancel_smart_preview_job', 'Request cancellation between photos. An in-flight native preview operation can finish; completed work is retained.', job, ['jobId']),
        ('batch_adjust_relative', 'Apply exact per-photo deltas to modern process-version numeric settings: target=each photo current value+delta. Default current; use scope=selected or explicit photoIds for a batch. Exposure in EV; RAW Temperature in kelvin, rendered Temperature in incremental units (mixed units rejected); Tint in catalog units. No clamping or wraparound. Preflights all photos and stops on first failure, reporting before/target/actual. Never automatically retry: repeated calls apply the delta again. Does not use Quick Develop button steps.',
         {**targets, 'deltas': {'type': 'object', 'properties': {p: {'type': 'number'} for p in RELATIVE_PARAMETERS}, 'additionalProperties': False, 'minProperties': 1}}, ['deltas']),
    ]
    return [types.Tool(name='lr_' + n, description=d, inputSchema={
        'type': 'object', 'properties': p, 'required': r, 'additionalProperties': False,
        **({'not': {'required': ['scope', 'photoIds']}} if 'scope' in p else {}),
    }) for n, d, p, r in specs]
