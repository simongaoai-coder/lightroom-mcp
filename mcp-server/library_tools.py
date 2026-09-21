"""Typed library and delivery tool contracts."""
from mcp import types

LIBRARY_COMMANDS={f'lr_{n}':n for n in (
 'get_selection','search_photos','select_photos','get_metadata','set_metadata',
 'list_keywords','create_keyword','update_keyword','update_photo_keywords',
 'list_collections','create_collection','update_collection','update_collection_photos','delete_collection',
 'move_keyword','list_keyword_photos','move_collection','show_target_collection','toggle_target_collection',
 'rename_virtual_copy','remove_virtual_copy','list_metadata_presets','apply_metadata_preset',
)}
DELIVERY_COMMANDS={f'lr_{n}':n for n in ('export_photos','get_export_status','cancel_export')}
TEXT_FIELDS='title caption creator copyright rightsUsageTerms headline location city stateProvince country isoCountryCode label'.split()
BASIC_FIELDS='rating pickStatus colorNameForLabel title caption creator copyright'.split()
# Documented LrPhoto shooting metadata; raw numbers/structures stay unformatted.
CAPTURE_FIELDS=('cameraMake cameraModel cameraSerialNumber lens shutterSpeed aperture '
 'isoSpeedRating focalLength focalLength35mm exposureBias flash exposure brightnessValue '
 'exposureProgram meteringMode subjectDistance artist software dateTimeOriginal '
 'dateTimeDigitized dateTime dateTimeOriginalISO8601 dateTimeDigitizedISO8601 dateTimeISO8601 '
 'gps gpsAltitude gpsImgDirection fileFormat fileSize dimensions croppedDimensions '
 'width height aspectRatio isCropped bitDepth').split()
READ_FIELDS=list(dict.fromkeys(TEXT_FIELDS+['rating','pickStatus','colorNameForLabel',
 'isVirtualCopy','copyName']+CAPTURE_FIELDS))


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
  'fileFormat':{'type':'string','enum':['RAW','DNG','JPG','TIFF','PSD','PNG','PSB','AVIF','JXL','VIDEO']},
  **{k:{'type':'string','pattern':r'^\d{4}-\d{2}-\d{2}$'} for k in ['captureAfter','captureBefore']},
 }}
 filters['properties'].update({
  **{k:{'type':'string','minLength':1} for k in ['cameraModel','cameraSerialNumber','lens','folder','collection','title','caption','copyName','country','city','creator']},
  **{k:{'type':'number','minimum':1,'maximum':10000000} for k in ['minISO','maxISO']},
  **{k:{'type':'boolean'} for k in ['hasAdjustments','hasGPS','cropped']},
  'treatment':{'type':'string','enum':['color','grayscale']},
  'orientation':{'type':'string','enum':['portrait','landscape','square']},
  'captureInLastDays':{'type':'integer','minimum':1,'maximum':365000},
  **{k:{'type':'array','items':{'$ref':'#/definitions/searchFilter'},'minItems':1,'maxItems':50} for k in ['all','any','none']},
 })
 filter_definition=filters
 filters={'$ref':'#/definitions/searchFilter'}
 metadata={**{k:{'type':'string'} for k in TEXT_FIELDS},
  'rating':{'type':'integer','minimum':0,'maximum':5},'pickStatus':{'type':'integer','enum':[-1,0,1]},
  'colorNameForLabel':{'type':'string','enum':labels},'gpsAltitude':{'type':'number'},
  'gps':{'type':'object','properties':{'latitude':{'type':'number','minimum':-90,'maximum':90},'longitude':{'type':'number','minimum':-180,'maximum':180}},'required':['latitude','longitude'],'additionalProperties':False}}
 specs=[
 ('get_selection','Read active photo UUID and paginated selected-photo summaries, including catalog path.',{**guard,**paging},[]),
 ('search_photos','Search using bounded nested all/any/none (AND/OR/NOR) filters and camera/lens/ISO/edit-state criteria, optionally restricted to collectionId. Returns stable UUID-sorted pages without changing selection. Date bounds are exclusive.',{**guard,**paging,'filters':filters,'collectionId':local_id},[]),
 ('select_photos','Select explicit photo UUIDs and verify selection. activePhotoId defaults to the first. reveal=true (default) opens Library and All Photographs; existing view filters may still hide photos.',{**guard,'photoIds':ids,'activePhotoId':ident,'reveal':{'type':'boolean','default':True}},['photoIds']),
 ('get_metadata','Read metadata and keywords for current, selected or explicit photos. Use fieldGroup=capture for SDK shooting metadata, all for all supported fields, or explicit fields (exclusive with fieldGroup). Default is basic. Numeric values retain SDK units: shutter seconds, focal length mm, exposure bias EV, timestamps seconds since 2001-01-01 UTC. Display-only text is localized. Absent values are missingFields; getter failures are fieldErrors, never invented values.',{**targets,'fieldGroup':{'type':'string','enum':['basic','capture','all']},'fields':{'type':'array','items':{'type':'string','enum':READ_FIELDS},'minItems':1,'uniqueItems':True}},[]),
 ('set_metadata','Set whitelisted catalog metadata and verify each photo. clearFields explicitly clears values (needed for GPS). This does not force XMP writes. Explicit photoIds and scope cannot be combined.',{**targets,'values':{'type':'object','properties':metadata,'additionalProperties':False},'clearFields':{'type':'array','items':{'type':'string','enum':list(metadata)},'uniqueItems':True}},[]),
 ('list_keywords','List keyword hierarchy with numeric IDs and synonyms; query is literal name/path text.',{**guard,**paging,'query':{'type':'string'}},[]),
 ('create_keyword','Create a keyword, optionally under parentId. A same-name sibling is returned without changing its attributes.',{**guard,'name':name,'parentId':local_id,'synonyms':{'type':'array','items':name,'uniqueItems':True},'includeOnExport':{'type':'boolean','default':True}},['name']),
 ('update_keyword','Update an explicit keyword name/synonyms/export flag and read them back. ignoreCase is passed to the SDK; use move_keyword for parent changes. Keyword deletion is unavailable.',{**guard,'keywordId':local_id,'name':name,'synonyms':{'type':'array','items':name,'uniqueItems':True},'includeOnExport':{'type':'boolean'},'ignoreCase':{'type':'boolean'}},['keywordId']),
 ('update_photo_keywords','Add or remove explicit keyword IDs on current, selected or explicit photos. Verifies direct keyword assignments; does not delete keyword definitions.',{**targets,'keywordIds':local_ids,'operation':{'type':'string','enum':['add','remove']}},['keywordIds','operation']),
 ('list_collections','List standard/smart collections and collection sets with hierarchy IDs. includeCounts optionally evaluates member counts.',{**guard,**paging,'query':{'type':'string'},'includeCounts':{'type':'boolean','default':False}},[]),
 ('create_collection','Create a collection, collection set or smart collection. Smart collections require filters; duplicate sibling names fail. Does not import or move image files.',{**guard,'name':name,'kind':{'type':'string','enum':['collection','set','smart'],'default':'collection'},'parentId':local_id,'filters':filters},['name']),
 ('update_collection','Rename a collection/set, or replace a smart collection\'s filters. Membership is managed separately.',{**guard,'collectionId':local_id,'name':name,'filters':filters},['collectionId']),
 ('update_collection_photos','Add/remove target photos in an explicit standard collection and verify membership. Smart collections and sets reject manual membership edits.',{**targets,'collectionId':local_id,'operation':{'type':'string','enum':['add','remove']}},['collectionId','operation']),
 ('delete_collection','Delete an explicit collection definition, leaving photos and image files intact. requireEmpty defaults true; nonempty sets are always rejected.',{**guard,'collectionId':local_id,'requireEmpty':{'type':'boolean','default':True}},['collectionId']),
 ('move_keyword','Move an explicit keyword under another keyword; parentId=0 makes it top-level. Rejects cycles and sibling name collisions; verifies parent readback.',{**guard,'keywordId':local_id,'parentId':{'type':'integer','minimum':0}},['keywordId','parentId']),
 ('list_keyword_photos','List UUID-sorted photos returned by the native keyword:getPhotos method. Optionally union descendants; no text-based keyword ambiguity.',{**guard,**paging,'keywordId':local_id,'includeDescendants':{'type':'boolean','default':False}},['keywordId']),
 ('move_collection','Move a collection or collection set under an explicit collection set; parentId=0 makes it top-level. Rejects cycles and sibling collisions.',{**guard,'collectionId':local_id,'parentId':{'type':'integer','minimum':0}},['collectionId','parentId']),
 ('show_target_collection','Open the current Lightroom target collection using the documented catalog source. Does not change which collection is designated as target.',guard,[]),
 ('toggle_target_collection','Toggle the single active photo in the current native target collection. Relative operation; never automatically retry. Reports observed ordinary-collection membership changes, which may not expose Quick Collection membership.',guard,['expectedPhotoId']),
 ('rename_virtual_copy','Rename one explicit virtual copy and verify copyName; rejects originals. Empty copyName clears its name. Optional expectedCopyName rejects stale names.',{**guard,'photoId':ident,'copyName':{'type':'string'},'expectedCopyName':{'type':'string'}},['photoId','copyName']),
 ('remove_virtual_copy','Remove exactly one virtual copy from the catalog, never its original file. Requires its UUID and expected master UUID; selects it alone in Library/All Photographs and verifies selection and deletion. May change selection/sources. No automatic retry after uncertainty.',{**guard,'photoId':ident,'expectedMasterPhotoId':ident,'expectedCopyName':{'type':'string'}},['photoId','expectedMasterPhotoId']),
 ('list_metadata_presets','Enumerate native metadata presets with exact IDs, name filtering and pagination. Does not create/import presets.',{**guard,**paging,'query':{'type':'string'}},[]),
 ('apply_metadata_preset','Apply an exact enumerated metadata preset to current/selected/explicit photos under catalog write access. Reports observed known-field differences; preset content is not enumerable and may affect additional fields. Save required metadata before applying; no automatic rollback.',{**targets,'presetId':ident,'readbackFields':{'type':'array','items':{'type':'string','enum':READ_FIELDS},'minItems':1,'uniqueItems':True}},['presetId']),
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
 return [types.Tool(name='lr_'+n,description=d,inputSchema={'type':'object','properties':p,'required':r,'additionalProperties':False,'definitions':{'searchFilter':filter_definition},**({'not':{'required':['fields','fieldGroup']}} if n=='get_metadata' else {})}) for n,d,p,r in specs]
