"""Transport simulator, not an independent model of Lightroom's history stack."""
from copy import deepcopy
class MockHistory:
 def __init__(self,backend):self.backend=backend;self.copies={};self.token=None;self.undo=[];self.redo=[]
 def handle(self,r):
  cmd=r['command']
  def ok(d):return {'success':True,'data':deepcopy(d)}
  def error(c):return {'success':False,'code':c,'error':c}
  if cmd=='copy_settings':
   self.copies[r['copyId']]=deepcopy(self.backend.settings);return ok({'copyId':r['copyId'],'mode':r.get('mode','native_ui')})
  if cmd=='paste_settings':
   if r['copyId']not in self.copies:return error('copy_not_found')
   self.undo.append(deepcopy(self.backend.settings));self.backend.settings.update(self.copies[r['copyId']]);return ok({'copyId':r['copyId']})
  if cmd=='get_history_state':
   self.token=r['historyToken'];return ok({'historyToken':self.token,'canUndo':bool(self.undo),'canRedo':bool(self.redo),'scope':'application_global'})
  if self.token!=r['historyToken']:return error('history_token_invalid')
  self.token=None;src,dst=(self.undo,self.redo)if cmd=='undo'else(self.redo,self.undo)
  if not src:return error('history_unavailable')
  dst.append(deepcopy(self.backend.settings));self.backend.settings=src.pop();return ok({'scope':'application_global','action':cmd})
