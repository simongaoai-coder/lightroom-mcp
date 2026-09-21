"""Read-only numeric edit preflight; batch reading extends lr_get_settings."""
from mcp import types
from style_tools import target_properties
from workflow_tools import RELATIVE_PARAMETERS


def preflight_tools():
    absolute={'type':'object','minProperties':1,'additionalProperties':{'type':'number'}}
    relative={'type':'object','minProperties':1,'properties':{n:{'type':'number'} for n in RELATIVE_PARAMETERS},'additionalProperties':False}
    return [types.Tool(name='lr_preflight_settings',description=
        'Read-only preflight of numeric absolute settings or relative deltas for current/selected/explicit photos. '
        'Returns per-photo before/target/mappings/catalogChanges/errors and batch canApply. No writes, selection changes or UI calls. '
        'Shares execution planners; known numeric bounds/crop/boolean constraints checked; uncheckedRanges identifies controls without range validation. '
        'success means inspection completed; inspect data.canApply. Not a reservation: execute separately and state is rechecked.',
        inputSchema={'type':'object','properties':{**target_properties(),'mode':{'enum':['absolute','relative'],'default':'absolute'},'settings':absolute,'deltas':relative},
        'additionalProperties':False,'not':{'required':['photoIds','scope']},
        'oneOf':[{'required':['settings'],'properties':{'mode':{'const':'absolute'}},'not':{'required':['deltas']}},
                 {'required':['mode','deltas'],'properties':{'mode':{'const':'relative'}},'not':{'required':['settings']}}]})]
