"""Transport-only healing simulation; not evidence of Adobe SDK behavior."""
from copy import deepcopy
from hashlib import md5
import json

class MockHealing:
    def __init__(self):
        self.spots=[{'id':'mock-spot-1','x':.4}]
        self.params={'size':.03,'Opacity':1.,'Feather':.5}
        self.kind='heal';self.gen=False;self.selected=1;self.jobs={}
        self.prefs={'newSpotType':'heal','brushSize':10,'brushFeather':50,'useGenerativeAI':False,'detectObjects':False,'toolOverlay':'auto','visualizeSpots':False,'visualizationThreshold':50}

    def handle(self,r):
        cmd=r['command'];pid='mock-photo-1'
        def ok(d):return {'success':True,'data':deepcopy(d)}
        def err(code):return {'success':False,'code':code,'error':code}
        if r.get('expectedPhotoId',pid)!=pid:return err('photo_changed')
        if cmd=='update_ai_settings':
            ids=r.get('photoIds',[pid]);j={'jobId':r['jobId'],'status':'sdk_completed','total':len(ids),'completed':len(ids),'failed':0,'notStarted':0,'results':[{'photoId':i,'status':'sdk_completed','success':True} for i in ids],'verification':'mock_only'}
            self.jobs[j['jobId']]=j;return ok(j)
        if cmd in ('get_ai_update_status','cancel_ai_update'):
            return ok(self.jobs[r['jobId']]) if r['jobId'] in self.jobs else err('job_not_found')
        if cmd=='cleanup_empty_masks':return ok({'results':[{'photoId':p,'success':True,'removedMaskIds':[]} for p in r.get('photoIds',[pid])]})
        if cmd=='set_remove_preferences':self.prefs.update(r['changes'])
        if cmd in ('open_remove','get_remove_preferences','set_remove_preferences'):return ok({'photoId':pid,'preferences':self.prefs})
        def state():
            d={'photoId':pid,'count':len(self.spots),'revision':md5(json.dumps(self.spots,sort_keys=True).encode()).hexdigest(),'hasSelection':self.selected is not None}
            if self.selected is not None:d.update(spotIndex=self.selected,spot=self.spots[self.selected-1],params=self.params,spotType=self.kind,useGenerativeAI=self.gen)
            return d
        if cmd=='list_spots':
            d=state();offset=r.get('offset',0);limit=r.get('limit',50)
            d.update(spots=[{'spotIndex':i+1,'spot':s} for i,s in enumerate(self.spots)][offset:offset+limit],offset=offset,hasMore=offset+limit<len(self.spots));return ok(d)
        if cmd=='get_selected_spot':return ok(state())
        if cmd=='reset_healing':
            if r['expectedRevision']!=state()['revision']:return err('spots_changed')
            n=len(self.spots);self.spots=[];self.selected=None;return ok({'removedCount':n,'status':'reset'})
        i=r['spotIndex']
        if i<1 or i>len(self.spots):return err('spot_not_found')
        if self.spots[i-1]!=r['expectedSpot']:return err('spot_changed')
        self.selected=i
        if cmd=='update_spot':
            if not set(r['changes'])<=self.params.keys():return err('unsupported_parameter')
            self.params.update(r['changes'])
        elif cmd=='set_spot_type':self.kind=r['spotType'];self.gen=r.get('useGenerativeAI',False)
        elif cmd=='cycle_spot_variation' and not self.gen:return err('not_generative_spot')
        elif cmd=='refresh_spot' and self.gen and not r.get('allowGenerativeRefresh'):return err('generative_refresh_not_authorized')
        elif cmd=='delete_spot':self.spots.pop(i-1);self.selected=None;return ok({'deletedSpotIndex':i,'remainingCount':len(self.spots),'status':'deleted'})
        return ok(state())
