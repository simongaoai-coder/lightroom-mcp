"""Schemas for fine develop controls and explicit mask operations."""
from mcp import types

FINE_COMMANDS = {f'lr_{name}': name for name in (
    'auto_white_balance', 'get_curve', 'set_curve', 'list_point_colors',
    'add_point_color', 'update_point_color', 'delete_point_color',
)}
MASK_FINE_COMMANDS = {f'lr_{name}': name for name in (
    'combine_mask', 'set_mask_visibility', 'invert_mask',
    'duplicate_inverted_mask', 'set_mask_tool_inverted',
)}


def fine_tools():
    from mask_tools import MASK_TYPES
    ident={'type':'string','minLength':1,'pattern':r'\S'}
    guard={'expectedPhotoId':ident}
    target={**guard,'maskId':ident}
    channel={'type':'string','enum':['rgb','red','green','blue'],'default':'rgb'}
    point={'type':'array','items':{'type':'number','minimum':0,'maximum':255},'minItems':2,'maxItems':2}
    unit={'type':'number','minimum':0,'maximum':1}
    span={'type':'object','properties':{k:unit for k in ['LowerNone','LowerFull','UpperFull','UpperNone']},
          'required':['LowerNone','LowerFull','UpperFull','UpperNone'],'additionalProperties':False}
    fields={**{k:unit for k in ['SrcSat','SrcLum','RangeAmount']},
            'SrcHue':{'type':'number','minimum':0,'maximum':6},
            **{k:{'type':'number','minimum':-1,'maximum':1} for k in ['HueShift','SatScale','LumScale']},
            **{k:span for k in ['HueRange','SatRange','LumRange']}}
    swatch={'type':'object','properties':fields,'additionalProperties':False}
    existing={**target,'index':{'type':'integer','minimum':1},
              'expectedSwatch':{'type':'object','minProperties':1,'description':'Exact swatch object from lr_list_point_colors; rejects stale/shifted indices.'}}
    specs=[
        ('auto_white_balance','Run native Auto White Balance on the current photo and read back its mode and temperature/tint.',guard,[]),
        ('get_curve','Read the RGB or channel point curve. Optional maskId targets a specific mask; omitted means global. Points use 0-255 coordinates.',{**target,'channel':channel},[]),
        ('set_curve','Replace a point curve and verify readback. Use 2-32 [x,y] pairs in 0-255; x strictly increases, starting at 0 and ending at 255. Optional maskId targets only that mask.',
         {**target,'channel':channel,'points':{'type':'array','items':point,'minItems':2,'maxItems':32}},['points']),
        ('list_point_colors','Read global point colors or a specific mask\'s point colors, with 1-based indices and raw swatch objects for stale-index guards.',target,[]),
        ('add_point_color','Add a point-color swatch. Source hue uses 0-6, saturation/luminance 0-1, shifts -1 to 1. An existing source color may only be selected by Lightroom; inspect status.',
         {**target,'swatch':{**swatch,'required':['SrcHue','SrcSat','SrcLum']}},['swatch']),
        ('update_point_color','Update an explicit swatch index after checking expectedSwatch. Unspecified fields are preserved. Use optional maskId for local point color.',
         {**existing,'changes':{**swatch,'minProperties':1}},['index','expectedSwatch','changes']),
        ('delete_point_color','Delete one explicit swatch after checking expectedSwatch and verify the remaining list. No delete-all fallback.',existing,['index','expectedSwatch']),
        ('combine_mask','Add, subtract or intersect a NEW component with an explicit existing mask. Automatic subject/sky/background components are polled; drawing/sampling types return awaiting_user_input. This does not merge two existing masks by ID.',
         {**target,'operation':{'type':'string','enum':['add','subtract','intersect']},'maskType':{'type':'string','enum':sorted(MASK_TYPES)}},['maskId','operation','maskType']),
        ('set_mask_visibility','Set hidden state of a mask or an explicit child tool. Idempotent, with readback; unknown state fails instead of guessing.',
         {**target,'toolId':ident,'hidden':{'type':'boolean'}},['maskId','hidden']),
        ('invert_mask','Invert an explicit whole mask once. This is not idempotent; inspect the result before retrying after a timeout.',target,['maskId']),
        ('duplicate_inverted_mask','Duplicate and invert an explicit mask, returning a newly identified mask ID. Do not blindly retry uncertain creation.',target,['maskId']),
        ('set_mask_tool_inverted','Set an explicit child tool\'s inversion state, verify its parent and read back the result.',
         {**target,'toolId':ident,'inverted':{'type':'boolean'}},['maskId','toolId','inverted']),
    ]
    return [types.Tool(name='lr_'+name,description=desc,inputSchema={
        'type':'object','properties':props,'required':required,'additionalProperties':False
    }) for name,desc,props,required in specs]
