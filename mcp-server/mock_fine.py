"""Small transport simulator; native semantics are covered by production Lua tests."""
from copy import deepcopy


class MockFine:
    def __init__(self, backend):
        self.backend=backend
        self.appearance={"treatment":"color","whiteBalance":"Custom","profile":{"CameraProfile":"Adobe Standard","Look":{"Name":"Adobe Color"},"ConvertToGrayscale":False}}
        self.process_version='Version 5'
        self.curves={}
        self.swatches={}

    def handle(self, req):
        cmd=req['command'];mask_id=req.get('maskId')
        def error(code):return {'success':False,'code':code,'error':code}
        if req.get('expectedPhotoId','mock-photo-1')!='mock-photo-1':return error('photo_changed')
        if cmd in {'get_process_version','set_process_version'}:
            if req.get('expectedVersion',self.process_version)!=self.process_version:return error('process_version_changed')
            previous=self.process_version
            if cmd=='set_process_version':self.process_version=req['version']
            return {'success':True,'data':{'photoId':'mock-photo-1','version':self.process_version,'rawVersion':{'Version 1':'5.0','Version 2':'5.7','Version 3':'6.7','Version 4':'10.0','Version 5':'11.0','Version 6':'15.4'}[self.process_version],'previousVersion':previous}}
        if cmd in {'get_appearance','set_treatment','set_white_balance','list_profiles','set_profile'}:
            if cmd=='set_treatment':self.appearance['treatment']=req['treatment']
            if cmd=='set_white_balance':self.appearance['whiteBalance']=req['mode']
            if cmd=='list_profiles':return {'success':True,'data':{'profiles':[{'profileId':'photo:mock-photo-1','name':'Adobe Color','expectedProfile':deepcopy(self.appearance['profile'])}],'completeInstalledList':False,'total':1}}
            if cmd=='set_profile':
                if req['profileId']!='photo:mock-photo-1':return error('profile_not_found')
                if req['expectedProfile']!=self.appearance['profile']:return error('profile_changed')
            return {'success':True,'data':{'photoId':'mock-photo-1',**deepcopy(self.appearance)}}
        mask=None
        if mask_id:
            mask=next((m for m in self.backend.mask_state.masks if m['id']==mask_id),None)
            if not mask:return error('mask_not_found')
        data={'photoId':'mock-photo-1'}
        if mask_id:data['maskId']=mask_id
        if cmd=='auto_white_balance':
            self.backend.settings.update(Temperature=6100,Tint=7)
            data.update(whiteBalance='Auto',temperature=6100,tint=7)
        elif cmd in {'get_curve','set_curve'}:
            key=(mask_id,req.get('channel','rgb'))
            if cmd=='set_curve':self.curves[key]=deepcopy(req['points'])
            data.update(channel=key[1],points=self.curves.get(key,[[0,0],[255,255]]),nativeScale=255)
        elif 'point_color' in cmd:
            swatches=self.swatches.setdefault(mask_id,[])
            if cmd=='add_point_color':
                item=deepcopy(req['swatch']);swatches.append(item)
                data.update(index=len(swatches),swatch=item,status='created')
            elif cmd in {'update_point_color','delete_point_color'}:
                index=req['index']-1
                if index<0 or index>=len(swatches):return error('swatch_not_found')
                if swatches[index]!=req['expectedSwatch']:return error('swatch_changed')
                if cmd=='update_point_color':swatches[index].update(deepcopy(req['changes']));data['status']='updated'
                else:swatches.pop(index);data['status']='deleted'
            data['swatches']=deepcopy(swatches)
        elif cmd=='combine_mask':
            automatic=req['maskType'] in {'subject','sky','background'}
            data.update(status='component_created' if automatic else 'awaiting_user_input',newToolIds=[])
            if automatic:
                tool_id=f"component-{len(mask['tools'])}"
                mask['tools'].append({'id':tool_id,'type':'aiSelection','subtype':req['maskType']})
                data['newToolIds']=[tool_id]
        elif cmd in {'set_mask_visibility','set_mask_tool_inverted'}:
            target=mask
            if req.get('toolId'):
                target=next((t for t in mask['tools'] if t['id']==req['toolId']),None)
                if not target:return error('tool_not_found')
            field='hidden' if cmd=='set_mask_visibility' else 'inverted'
            previous=target.get(field,False);target[field]=req[field]
            data.update({field:req[field],'changed':previous!=req[field]})
        elif cmd=='invert_mask':data.update(status='inverted',verification='sdk_completed')
        elif cmd=='duplicate_inverted_mask':
            copied=deepcopy(mask);copied['id']=f"mask-{self.backend.mask_state.next_id}"
            self.backend.mask_state.next_id+=1
            self.backend.mask_state.masks.append(copied)
            data.update(maskId=copied['id'],sourceMaskId=mask_id,status='created')
        return {'success':True,'data':deepcopy(data)}
