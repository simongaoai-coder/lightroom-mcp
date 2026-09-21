"""Extended export option schemas. Lightroom remains the native renderer/namer."""
PIXELS={'type':'integer','minimum':1,'maximum':65000}
NAMING={'type':'object','additionalProperties':False,'properties':{
    'mode':{'type':'string','enum':['original','original_sequence','custom_sequence']},
    'customText':{'type':'string','minLength':1,'maxLength':200,'description':'Literal text, at most 200 UTF-8 bytes; no paths or template tokens.','pattern':r'^(?=.*\S)[^/\\:*?"<>|{}\x00-\x1f\x7f]+(?<![ .])$(?![\s\S])'},
    'sequenceStart':{'type':'integer','minimum':1,'maximum':999999999},
    'sequenceDigits':{'type':'integer','minimum':1,'maximum':5},
    'extensionCase':{'type':'string','enum':['lowercase','uppercase']},
},'allOf':[
    {'if':{'required':['mode'],'properties':{'mode':{'const':'custom_sequence'}}},'then':{'required':['customText']}},
    {'if':{'required':['customText']},'then':{'required':['mode'],'properties':{'mode':{'const':'custom_sequence'}}}},
    {'if':{'required':['mode'],'properties':{'mode':{'const':'original'}}},
     'then':{'not':{'anyOf':[{'required':['sequenceStart']},{'required':['sequenceDigits']}]}}},
]}


def extend_export_schema(schema):
    schema['properties'].update({
        'shortEdge':{**PIXELS,'description':'Short-edge pixel limit, exclusive with other resize modes.'},
        'width':{**PIXELS,'description':'Bounding-box width in pixels; requires height, preserves aspect ratio.'},
        'height':{**PIXELS,'description':'Bounding-box height in pixels; requires width.'},
        'megapixels':{'type':'number','minimum':0.01,'maximum':1000},
        'maxFileSizeKB':{'type':'integer','minimum':1,'maximum':1048576,
                         'description':'JPEG only; 1 KB = 1024 bytes. Exclusive with quality. Actual output size is checked; oversized files are retained but reported failed.'},
        'naming':NAMING,
    })
    schema['properties']['bitDepth'].pop('default',None)
    schema['properties']['quality'].pop('default',None)
    schema['properties']['quality']['description']='JPEG fixed quality 1-100; defaults to 90 only when maxFileSizeKB is omitted.'
    schema['allOf']=[
        {'not':{'required':pair}} for pair in [
            ['longEdge','shortEdge'],['longEdge','width'],['longEdge','height'],['longEdge','megapixels'],
            ['shortEdge','width'],['shortEdge','height'],['shortEdge','megapixels'],['width','megapixels'],['height','megapixels'],
            ['quality','maxFileSizeKB'],['photoIds','scope'],
        ]
    ]+[
        {'if':{'required':['width']},'then':{'required':['height']}},
        {'if':{'required':['height']},'then':{'required':['width']}},
        {'if':{'required':['maxFileSizeKB']},'then':{'properties':{'format':{'const':'JPEG'}}}},
        {'if':{'required':['quality']},'then':{'properties':{'format':{'const':'JPEG'}}}},
        {'if':{'required':['bitDepth']},'then':{'required':['format'],'properties':{'format':{'const':'TIFF'}}}},
    ]


def validate_export_call(args):
    text=args.get('naming',{}).get('customText')
    if text is not None:
        try:
            if len(text.encode('utf-8'))>200:
                return 'customText must fit within 200 UTF-8 bytes'
        except UnicodeEncodeError:
            return 'customText must be valid Unicode'
    return None
