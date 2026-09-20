"""Typed library and delivery tool contracts."""
from mcp import types

LIBRARY_COMMANDS={f'lr_{n}':n for n in (
 'get_selection','search_photos','select_photos','get_metadata','set_metadata',
 'list_keywords','create_keyword','update_keyword','update_photo_keywords',
 'list_collections','create_collection','update_collection','update_collection_photos','delete_collection',
)}
DELIVERY_COMMANDS={f'lr_{n}':n for n in ('export_photos','get_export_status','cancel_export')}
TEXT_FIELDS='title caption creator copyright rightsUsageTerms headline location city stateProvince country isoCountryCode label'.split()
READ_FIELDS=TEXT_FIELDS+['rating','pickStatus','colorNameForLabel','gps','gpsAltitude','fileFormat','cameraMake','cameraModel','lens','dateTimeOriginal','isVirtualCopy','copyName']


def library_tools():
 ident={'type':'string','minLength':1,'pattern':r'\S'}
 name={'type':'string','minLength':1,'pattern':r'^(?=.*\S)[^\x00-\x1f\x7f]+$'}
 ids={'type':'array','items':ident,'minItems':1,'maxItems':200,'uniqueItems':True}
 local_id={'type':'integer','minimum':1}
 local_ids={'type':'array','items':local_id,'minItems':1,'maxItems':200,'uniqueItems':True}
 guard={'expectedPhotoId':ident,'expectedCatalogPath':ident}
 targets={**guard,'photoIds':ids,'scope':{'type':'string','enum':['current','selected'],'default':'current'}}
 paging={'offset':{'type':'integer','minimum':0,'default':0},'limit':{'type':'integer','minimum':1,'maximum':200,'default':50}}
 labels=['red','yellow','green','blue','purple','none']
 filters={'type':'object','additionalProperties':False,'properties':{
  **{k:{'type':'string'} for k in ['query','filename','keyword']},
  **{k:{'type':'integer','minimum':0,'maximum':5} for k in ['minRating','maxRating']},
  'pickStatus':{'type':'integer','enum':[-1,0,1]},'colorLabel':{'type':'string','enum':labels},
  'fileFormat':{'type':'string','enum':['RAW','DNG','JPG','TIFF','PSD']},
  **{k:{'type':'string','pattern':r'^\d{4}-\d{2}-\d{2}$'} for k in ['captureAfter','captureBefore']},
 }}
 metadata={**{k:{'type':'string'} for k in TEXT_FIELDS},
  'rating':{'type':'integer','minimum':0,'maximum':5},'pickStatus':{'type':'integer','enum':[-1,0,1]},
  'colorNameForLabel':{'type':'string','enum':labels},'gpsAltitude':{'type':'number'},
  'gps':{'type':'object','properties':{'latitude':{'type':'number','minimum':-90,'maximum':90},'longitude':{'type':'number','minimum':-180,'maximum':180}},'required':['latitude','longitude'],'additionalProperties':False}}
 specs=[
 ('get_selection','Read active photo UUID and paginated selected-photo summaries, including catalog path.',{**guard,**paging},[]),
 ('search_photos','Search the catalog using native metadata filters, optionally restricted to collectionId. Returns stable UUID-sorted pages without changing selection. Date bounds are exclusive.',{**guard,**paging,'filters':filters,'collectionId':local_id},[]),
 ('select_photos','Select explicit photo UUIDs and verify selection. activePhotoId defaults to the first. reveal=true (default) opens Library and All Photographs; existing view filters may still hide photos.',{**guard,'photoIds':ids,'activePhotoId':ident,'reveal':{'type':'boolean','default':True}},['photoIds']),
 ('get_metadata','Read specified metadata fields and keyword IDs for current, selected or explicit photos. Missing fields are listed separately.',{**targets,'fields':{'type':'array','items':{'type':'string','enum':READ_FIELDS},'minItems':1,'uniqueItems':True}},[]),
 ('set_metadata','Set whitelisted catalog metadata and verify each photo. clearFields explicitly clears values (needed for GPS). This does not force XMP writes. Explicit photoIds and scope cannot be combined.',{**targets,'values':{'type':'object','properties':metadata,'additionalProperties':False},'clearFields':{'type':'array','items':{'type':'string','enum':list(metadata)},'uniqueItems':True}},[]),
 ('list_keywords','List keyword hierarchy with numeric IDs and synonyms; query is literal name/path text.',{**guard,**paging,'query':{'type':'string'}},[]),
 ('create_keyword','Create a keyword, optionally under parentId. A same-name sibling is returned without changing its attributes.',{**guard,'name':name,'parentId':local_id,'synonyms':{'type':'array','items':name,'uniqueItems':True},'includeOnExport':{'type':'boolean','default':True}},['name']),
 ('update_keyword','Update an explicit keyword name/synonyms/export flag and read them back. Parent changes and keyword deletion are outside this tool.',{**guard,'keywordId':local_id,'name':name,'synonyms':{'type':'array','items':name,'uniqueItems':True},'includeOnExport':{'type':'boolean'}},['keywordId']),
 ('update_photo_keywords','Add or remove explicit keyword IDs on current, selected or explicit photos. Verifies direct keyword assignments; does not delete keyword definitions.',{**targets,'keywordIds':local_ids,'operation':{'type':'string','enum':['add','remove']}},['keywordIds','operation']),
 ('list_collections','List standard/smart collections and collection sets with hierarchy IDs. includeCounts optionally evaluates member counts.',{**guard,**paging,'query':{'type':'string'},'includeCounts':{'type':'boolean','default':False}},[]),
 ('create_collection','Create a collection, collection set or smart collection. Smart collections require filters; duplicate sibling names fail. Does not import or move image files.',{**guard,'name':name,'kind':{'type':'string','enum':['collection','set','smart'],'default':'collection'},'parentId':local_id,'filters':filters},['name']),
 ('update_collection','Rename a collection/set, or replace a smart collection\'s filters. Membership is managed separately.',{**guard,'collectionId':local_id,'name':name,'filters':filters},['collectionId']),
 ('update_collection_photos','Add/remove target photos in an explicit standard collection and verify membership. Smart collections and sets reject manual membership edits.',{**targets,'collectionId':local_id,'operation':{'type':'string','enum':['add','remove']}},['collectionId','operation']),
 ('delete_collection','Delete an explicit collection definition, leaving photos and image files intact. requireEmpty defaults true; nonempty sets are always rejected.',{**guard,'collectionId':local_id,'requireEmpty':{'type':'boolean','default':True}},['collectionId']),
 ('export_photos','Start a native JPEG/TIFF file export job for current, selected or explicit photos. destination must be an existing absolute directory. Each job creates a unique batch subfolder and returns jobId; poll get_export_status until completion. No thumbnail export or automatic reimport.',{**targets,
  'destination':ident,'format':{'type':'string','enum':['JPEG','TIFF'],'default':'JPEG'},
  'quality':{'type':'integer','minimum':1,'maximum':100,'default':90},
  'colorSpace':{'type':'string','enum':['sRGB','AdobeRGB','ProPhotoRGB'],'default':'sRGB'},
  'bitDepth':{'type':'integer','enum':[8,16],'default':16},
  'longEdge':{'type':'integer','minimum':1,'maximum':65000},'doNotEnlarge':{'type':'boolean','default':True},
  'resolution':{'type':'integer','minimum':1,'maximum':1200,'default':240},
  'sharpenFor':{'type':'string','enum':['none','screen','matte','glossy'],'default':'none'},'sharpenAmount':{'type':'integer','enum':[1,2,3],'default':2},
  'metadata':{'type':'string','enum':['all','allExceptCameraInfo','copyrightOnly','copyrightAndContactOnly'],'default':'all'},
  'removeLocation':{'type':'boolean','default':False},'watermarkId':ident,
 },['destination']),
 ('get_export_status','Read export job status and paginated per-photo output paths/errors. Jobs belong to this plugin session; unknown IDs do not prove that no files were written.',{**paging,'jobId':ident},['jobId']),
 ('cancel_export','Request cooperative cancellation between photos. An in-flight rendition can finish; completed files remain.',{'jobId':ident},['jobId']),
 ]
 return [types.Tool(name='lr_'+n,description=d,inputSchema={'type':'object','properties':p,'required':r,'additionalProperties':False}) for n,d,p,r in specs]
