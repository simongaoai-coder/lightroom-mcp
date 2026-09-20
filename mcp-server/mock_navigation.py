"""Transport-only geometry/navigation simulation."""
from copy import deepcopy
class MockNavigation:
 def __init__(self):
  self.orientation='AB';self.ratio=1.5;self.module='library';self.pid='mock-photo-1';self.filter={'filtersActive':False,'minRating':0};self.sources=[{'kind':'catalog','id':'all'}]
 def handle(self,r):
  cmd=r['command']
  def ok(d):return {'success':True,'data':deepcopy(d)}
  def err(code):return {'success':False,'code':code,'error':code}
  if r.get('expectedPhotoId',self.pid)!=self.pid:return err('photo_changed')
  if cmd in ['get_geometry','rotate_photo','set_crop_aspect','reset_adjustments']:
   if cmd=='rotate_photo':
    m=dict(zip('ABCD','BCDA' if r['direction']=='right' else 'DABC'));self.orientation=''.join(m[x] for x in self.orientation)
   if cmd=='set_crop_aspect':
    if ('preset'in r)==('width'in r or 'height'in r):return err('invalid_arguments')
    self.ratio=r['width']/r['height']if 'width'in r else 1.5
   if cmd=='reset_adjustments' and ('parameter'in r)==('group'in r):return err('invalid_arguments')
   return ok({'photoId':self.pid,'orientation':self.orientation,'effectiveRatio':self.ratio,'verification':'mock_only'})
  if cmd=='list_folders':return ok({'folders':[{'path':'/photos','name':'photos'}],'total':1})
  if cmd=='list_folder_photos':return ok({'photos':[{'photoId':self.pid}],'total':1})
  if cmd=='show_view':self.module='develop'if r['view'].startswith('develop')else 'library'
  if cmd=='navigate_photos':self.pid='mock-photo-2'if r['action']=='next'else 'mock-photo-1'
  if cmd=='set_sources':self.sources=[{'kind':'folder','path':r['folderPaths'][0]}]if 'folderPaths'in r else [{'kind':'catalog','id':'all'}]
  if cmd=='set_view_filter':
   if 'changes'in r:self.filter.update(r['changes'])
   else:self.filter['filtersActive']=False
  return ok({'activePhotoId':self.pid,'module':self.module,'sources':self.sources,'viewFilter':self.filter,'filterPresets':[{'presetId':'off','name':'Filters Off'}]})
