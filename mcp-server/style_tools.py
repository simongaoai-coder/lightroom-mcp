"""Persistent native plugin styles and shared batch target schemas."""
from mcp import types

STYLE_COMMANDS = {'lr_save_style': 'save_style'}
TARGET_TOOLS = {'lr_apply_settings', 'lr_batch_apply_settings', 'lr_apply_preset',
                'lr_set_treatment', 'lr_set_white_balance', 'lr_rotate_photo'}


def target_properties(default='current'):
    ident = {'type': 'string', 'minLength': 1, 'pattern': r'\S'}
    return {'photoIds': {'type': 'array', 'items': ident, 'minItems': 1, 'maxItems': 200, 'uniqueItems': True},
            'scope': {'type': 'string', 'enum': ['current', 'selected'], 'default': default},
            'expectedPhotoId': ident, 'expectedCatalogPath': ident}


def style_tools():
    ident = {'type': 'string', 'minLength': 1, 'pattern': r'^(?=.*\S)[^\x00-\x1f\x7f]+$'}
    return [types.Tool(name='lr_save_style', description=
        'Save selected current/source-photo settings as a persistent hidden Lightroom plugin preset. '
        'Select parameters and/or groups explicitly; no implicit exposure/WB/crop/masks. '
        'Groups: colorGrading, pointCurve (RGB and channels), grain. Duplicate plugin names fail. '
        'Returns presetId and saved settings; later list/apply via lr_list_presets/lr_apply_preset. '
        'Applied values are absolute, not deltas. Saved styles require matching process version '
        'and compatible WB units. Presets are not visible in the ordinary Develop preset panel.',
        inputSchema={'type': 'object', 'properties': {
            'name': ident, 'sourcePhotoId': ident, 'expectedPhotoId': ident, 'expectedCatalogPath': ident,
            'parameters': {'type': 'array', 'items': ident, 'minItems': 1, 'maxItems': 150, 'uniqueItems': True},
            'groups': {'type': 'array', 'items': {'type': 'string', 'enum': ['colorGrading','pointCurve','grain']},
                       'minItems': 1, 'uniqueItems': True},
        }, 'required': ['name'], 'anyOf': [{'required':['parameters']}, {'required':['groups']}],
        'additionalProperties': False})]
