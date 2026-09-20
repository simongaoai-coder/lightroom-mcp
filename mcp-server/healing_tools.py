"""Remove/heal controls and bounded AI maintenance jobs."""
from mcp import types

HEALING_COMMANDS={f'lr_{name}':name for name in (
 'open_remove','list_spots','get_selected_spot','select_spot','update_spot','set_spot_type',
 'move_spot','refresh_spot','delete_spot','cycle_spot_variation','get_remove_preferences',
 'set_remove_preferences','reset_healing','update_ai_settings','get_ai_update_status',
 'cancel_ai_update','cleanup_empty_masks',
)}


def healing_tools():
 ident={'type':'string','minLength':1,'pattern':r'\S'}
 guard={'expectedPhotoId':ident,'expectedCatalogPath':ident}
 kinds={'type':'string','enum':['heal_patchmatch','heal','clone']}
 expected={'description':'Exact spot value returned by list_spots/get_selected_spot. Rejects stale or shifted indices.',
           'oneOf':[{'type':'object','minProperties':1},{'type':'array','minItems':1},{'type':'string','minLength':1}]}
 target={**guard,'spotIndex':{'type':'integer','minimum':0,'description':'Use the native index returned by list_spots; do not guess the index base.'},'expectedSpot':expected}
 prefs={'newSpotType':kinds,'brushSize':{'type':'number','minimum':1,'maximum':100},
        'brushFeather':{'type':'number','minimum':0,'maximum':100},'useGenerativeAI':{'type':'boolean'},
        'detectObjects':{'type':'boolean'},'toolOverlay':{'type':'string','enum':['always','auto','selected','never']},
        'visualizeSpots':{'type':'boolean'},'visualizationThreshold':{'type':'number','minimum':0,'maximum':100}}
 paging={'offset':{'type':'integer','minimum':0,'default':0},'limit':{'type':'integer','minimum':1,'maximum':200,'default':50}}
 targets={**guard,'photoIds':{'type':'array','items':ident,'minItems':1,'maxItems':200,'uniqueItems':True},
          'scope':{'type':'string','enum':['current','selected'],'default':'current'}}
 specs=[
 ('open_remove','Open the native Remove tool, optionally choosing clone/heal/remove mode. Does not draw a new region. SDK 14.1+ APIs are checked at runtime.',{**guard,'spotType':kinds},[]),
 ('list_spots','List existing repair/removal spots with native indices and raw spot values. Returns count, revision and selection. Opens Develop/Remove as needed.',{**guard,**paging},[]),
 ('get_selected_spot','Read the selected spot type, generative flag and native parameter table. No selection is a valid result.',guard,[]),
 ('select_spot','Select an explicit existing spot after comparing expectedSpot. Returns native params for a subsequent edit.',target,['spotIndex','expectedSpot']),
 ('update_spot','Attempt to patch Opacity/Feather (0-1) and verify native readback. Lightroom 15.2 was observed to ignore this SDK setter; returns readback_failed when not retained. Other repair data is read-only.',
  {**target,'changes':{'type':'object','minProperties':1,'properties':{k:{'type':'number','minimum':0,'maximum':1} for k in ['Opacity','Feather']},'additionalProperties':False}},['spotIndex','expectedSpot','changes']),
 ('set_spot_type','Change one existing spot to clone/heal/remove. useGenerativeAI=true is only valid for heal_patchmatch and may initiate Adobe generative processing; completion is not inferred from the request.',
  {**target,'spotType':kinds,'useGenerativeAI':{'type':'boolean','default':False}},['spotIndex','expectedSpot','spotType']),
 ('move_spot','Move an existing region or its source area using native relative SDK units. Source-area movement is valid only for heal/clone. This does not create brush geometry.',
  {**target,'horizontal':{'type':'string','enum':['left','right']},'vertical':{'type':'string','enum':['up','down']},
   'horizontalUnits':{'type':'number','exclusiveMinimum':0,'maximum':1000},'verticalUnits':{'type':'number','exclusiveMinimum':0,'maximum':1000},'sourceArea':{'type':'boolean','default':False}},['spotIndex','expectedSpot']),
 ('refresh_spot','Request a new source/result for an existing spot. Refreshing a generative spot may invoke Adobe cloud processing and requires allowGenerativeRefresh=true. No automatic retry after uncertain completion.',
  {**target,'allowGenerativeRefresh':{'type':'boolean','default':False}},['spotIndex','expectedSpot']),
 ('delete_spot','Delete exactly one guarded existing spot and verify the remaining list/count. Never falls back to another selected spot.',target,['spotIndex','expectedSpot']),
 ('cycle_spot_variation','Go to the next/previous existing generative result on an explicit spot. Rejects non-generative spots. Reports SDK completion/observations; does not invent variation IDs.',
  {**target,'direction':{'type':'string','enum':['next','previous']}},['spotIndex','expectedSpot','direction']),
 ('get_remove_preferences','Read Remove panel defaults and overlay preferences, separate from the selected region\'s actual parameters.',guard,[]),
 ('set_remove_preferences','Patch documented Remove panel defaults and read them back. Enabling useGenerativeAI changes the drawing default; this does not draw a new spot.',
  {**guard,'changes':{'type':'object','properties':prefs,'additionalProperties':False,'minProperties':1}},['changes']),
 ('reset_healing','Clear all repair/removal regions on the current photo only after the full list revision matches. Save a snapshot first if these regions must be recoverable.',
  {**guard,'expectedRevision':ident},['expectedRevision']),
 ('update_ai_settings','Start a bounded AI-settings update job for current/selected/explicit photos (not AI Denoise/Enhance). Poll status. SDK-call completion does not independently prove GPU/cloud rendering completion.',targets,[]),
 ('get_ai_update_status','Read per-photo AI-update job outcomes. Jobs are local to this plugin session; sdk_completed means native calls returned, not independently verified pixels.',{'jobId':ident},['jobId']),
 ('cancel_ai_update','Request cancellation between photos; the in-flight native AI update may finish. Prior updates are retained.',{'jobId':ident},['jobId']),
 ('cleanup_empty_masks','Run the native empty-mask cleanup on explicit/current/selected photos, under catalog write access. Returns removed mask IDs observed in catalog settings; never defaults to the entire catalog.',targets,[]),
 ]
 return [types.Tool(name='lr_'+name,description=desc,inputSchema={'type':'object','properties':props,'required':required,'additionalProperties':False}) for name,desc,props,required in specs]
