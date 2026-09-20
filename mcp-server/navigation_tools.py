"""Geometry, scoped reset, and catalog navigation schemas."""
from mcp import types
GEOMETRY_COMMANDS={f'lr_{n}':n for n in ('get_geometry','rotate_photo','set_crop_aspect','reset_adjustments')}
NAVIGATION_COMMANDS={f'lr_{n}':n for n in ('get_navigation','list_folders','list_folder_photos','set_sources','show_view','navigate_photos','set_view_filter')}

def navigation_tools():
 ident={'type':'string','minLength':1,'pattern':r'\S'}
 guard={'expectedPhotoId':ident,'expectedCatalogPath':ident}
 paging={'offset':{'type':'integer','minimum':0,'default':0},'limit':{'type':'integer','minimum':1,'maximum':200,'default':50}}
 filter_fields={k:{'type':'boolean'} for k in ['columnBrowserActive','filtersActive','searchStringActive','label1','label2','label3','label4','label5','customLabel','noLabel']}
 filter_fields.update(minRating={'type':'integer','minimum':0,'maximum':5},ratingOp={'type':'string','enum':['>=','<=','==']},searchString={'type':'string'},searchOp={'type':'string','enum':['all','words','noneof','beginwith','endswith']},searchTarget={'type':'string','enum':['all','filename','copyname','title','caption','keyword','metadata','iptc','exif','allPluginMetadata']})
 specs=[
 ('get_geometry','Read current photo orientation, pixel dimensions and crop settings. Does not change view.',guard,[]),
 ('rotate_photo','Rotate the current photo 90 degrees left/right and verify orientation. Does not rewrite the original image file. Non-idempotent: do not retry after uncertain completion.',{**guard,'direction':{'type':'string','enum':['left','right']}},['direction']),
 ('set_crop_aspect','Set native crop proportions: original, asshot, or positive width/height. Custom proportions are checked against pixel dimensions; Lightroom controls crop position and portrait/landscape orientation. Returns effective ratio. Save a snapshot first.',{**guard,'preset':{'type':'string','enum':['original','asshot']},'width':{'type':'number','exclusiveMinimum':0,'maximum':10000},'height':{'type':'number','exclusiveMinimum':0,'maximum':10000}},[]),
 ('reset_adjustments','Reset ONE global numeric parameter OR one group: crop/transforms/masking/redeye. Masking clears all local masks on this photo. Never resets the whole photo. Parameter defaults are native Lightroom defaults, not assumed zero; returns observed values. Save a snapshot first.',{**guard,'parameter':ident,'group':{'type':'string','enum':['crop','transforms','masking','redeye']}},[]),
 ('get_navigation','Read module, active sources, selection and view filter, plus filter presets. No reliable main-view/zoom getter is exposed; these are not inferred.',{**guard,**paging},[]),
 ('list_folders','List catalog folder hierarchy by exact path, with pagination; does not scan or move disk files.',{**guard,**paging,'query':{'type':'string'}},[]),
 ('list_folder_photos','List catalog photos in an explicit folder path, optionally including children. Does not alter active sources or selection.',{**guard,**paging,'folderPath':ident,'includeChildren':{'type':'boolean','default':False}},['folderPath']),
 ('set_sources','Set exactly one source category: allPhotos=true, folderPaths, or collectionIds. Reads back active sources. Selection and remembered per-source filters can change; returned state shows the result.',{**guard,'allPhotos':{'type':'boolean','enum':[True]},'folderPaths':{'type':'array','items':ident,'minItems':1,'maxItems':50,'uniqueItems':True},'collectionIds':{'type':'array','items':{'type':'integer','minimum':1},'minItems':1,'maxItems':50,'uniqueItems':True}},[]),
 ('show_view','Request a Library or Develop view. Confirms module only: SDK provides no reliable current main-view getter. Preserves source/filter settings.',{**guard,'view':{'type':'string','enum':['grid','loupe','compare','survey','people','develop_loupe','develop_before','develop_before_after_horiz','develop_before_after_vert','develop_reference_horiz','develop_reference_vert']}},['view']),
 ('navigate_photos','Navigate current filmstrip order, or select all/inverse within it. Does not explicitly change sources or filters. Unchanged selection may mean boundary or no native effect; it is not automatically retried.',{**guard,'action':{'type':'string','enum':['next','previous','first','last','all','inverse']},**paging},['action']),
 ('set_view_filter','Patch documented view-filter fields OR apply an exact presetId from get_navigation. Preserves unspecified fields. Can hide current photos and change selection; reads back filter. Optional expectedFilter rejects stale state.',{**guard,'changes':{'type':'object','properties':filter_fields,'additionalProperties':False,'minProperties':1},'presetId':ident,'expectedFilter':{'type':'object'}},[]),
 ]
 return [types.Tool(name='lr_'+n,description=d,inputSchema={'type':'object','properties':p,'required':r,'additionalProperties':False})for n,d,p,r in specs]
