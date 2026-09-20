"""Copy/paste and application-global history operations."""
from mcp import types
HISTORY_COMMANDS={f'lr_{n}':n for n in ('copy_settings','paste_settings','get_history_state','undo','redo')}

def history_tools():
 ident={'type':'string','minLength':1,'pattern':r'\S'}
 guard={'expectedPhotoId':ident,'expectedCatalogPath':ident}
 specs=[
 ('copy_settings','Copy current photo settings and return a session copyId. native_ui (default) calls Lightroom copySettings using the UI\'s last selected copy categories; the SDK cannot enumerate that selection. explicit mode freezes only the named numeric parameters and does not touch the native clipboard.',{**guard,'mode':{'type':'string','enum':['native_ui','explicit'],'default':'native_ui'},'parameters':{'type':'array','items':ident,'minItems':1,'maxItems':150,'uniqueItems':True}},[]),
 ('paste_settings','Paste a prior copyId onto the guarded CURRENT photo only. Explicit mode uses frozen numeric values with readback. Native mode checks the source has not changed, re-copies that source immediately, then pastes using the current UI copy categories; clipboard identity/categories cannot be independently verified. No automatic AI-update request. Returns observed changed keys, not proof of every native pasted field.',{**guard,'copyId':ident},['copyId','expectedPhotoId']),
 ('get_history_state','Read native canUndo/canRedo and issue a one-use historyToken valid for 60 seconds in this plugin session. Guards current photo/settings/selection and intervening MCP mutations, but cannot identify the actual global history entry or detect all manual edits elsewhere.',guard,[]),
 ('undo','Undo ONE application-global Lightroom history entry using a fresh historyToken. May undo manual actions or affect another photo; this is NOT rollback of a specific MCP request. Token consumed before the native call; never automatically retry. Returns current-photo observations and native availability afterward.',{**guard,'historyToken':ident},['historyToken']),
 ('redo','Redo ONE application-global Lightroom history entry using a fresh historyToken. Same limitations as undo; read history state again before every operation. No automatic retry after failure/timeout.',{**guard,'historyToken':ident},['historyToken']),
 ]
 return [types.Tool(name='lr_'+n,description=d,inputSchema={'type':'object','properties':p,'required':r,'additionalProperties':False})for n,d,p,r in specs]
