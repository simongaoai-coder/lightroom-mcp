"""Typed treatment, white balance and SDK-observed profile configurations."""
from mcp import types
APPEARANCE_COMMANDS={f'lr_{x}':x for x in ('get_appearance','set_treatment','set_white_balance','list_profiles','set_profile')}

def appearance_tools():
    ident={'type':'string','minLength':1,'pattern':r'\S'}
    guard={'expectedPhotoId':ident,'expectedCatalogPath':ident}
    specs=[
      ('get_appearance','Read current color/B&W treatment, white-balance mode and native profile configuration. Read-only; does not switch modules.',guard,[]),
      ('set_treatment','Set current photo treatment to color or grayscale via the native SDK and verify readback. Lightroom may also change the associated profile.',{**guard,'treatment':{'type':'string','enum':['color','grayscale']}},['treatment']),
      ('set_white_balance','Set white-balance mode and verify it. Lighting presets require RAW/DNG. As Shot uses catalog settings; other named modes use native Quick Develop. Use lr_apply_settings for Custom temperature/tint adjustments.',{**guard,'mode':{'type':'string','enum':['As Shot','Auto','Daylight','Cloudy','Shade','Tungsten','Fluorescent','Flash']}},['mode']),
      ('list_profiles','List profile configurations observed on specified photos (default current) and in SDK-visible develop presets. NOT a complete installed-profile browser; applying a candidate copies profile fields only, not the full preset. Return expectedProfile to guard later application.',{**guard,'sourcePhotoIds':{'type':'array','items':ident,'minItems':1,'maxItems':50,'uniqueItems':True},'includePresets':{'type':'boolean','default':True},'query':{'type':'string'},'offset':{'type':'integer','minimum':0,'default':0},'limit':{'type':'integer','minimum':1,'maximum':200,'default':50}},[]),
      ('set_profile','Apply a profile configuration from list_profiles using profileId and exact expectedProfile. Copies CameraProfile/digest/Look and associated treatment only; never applies the entire preset. Photo sources with RAW profiles must match camera model and RAW/rendered class. Verifies stored settings, not rendered pixels.',{**guard,'profileId':ident,'expectedProfile':{'type':'object','minProperties':1}},['profileId','expectedProfile']),
    ]
    return [types.Tool(name='lr_'+name,description=desc,inputSchema={'type':'object','properties':props,'required':required,'additionalProperties':False}) for name,desc,props,required in specs]
