"""Development-only library/export transport simulator; native Lua is tested separately."""
from copy import deepcopy
from pathlib import Path


class MockLibrary:
    def __init__(self,backend):
        self.backend=backend;self.current='mock-photo-1';self.selected=[self.current]
        self.photos={f'mock-photo-{i}':{'photoId':f'mock-photo-{i}','filename':name,'path':'/photos/'+name,
          'metadata':{'rating':0,'pickStatus':0,'title':'','caption':'','colorNameForLabel':'none'},'keywords':[]}
          for i,name in enumerate(backend.photos,1)}
        self.keywords={};self.collections={};self.jobs={}

    def error(self,code):return {'success':False,'code':code,'error':code.replace('_',' ')}
    def targets(self,req):return req.get('photoIds') or (self.selected if req.get('scope')=='selected' else [self.current])
    def paginate(self,items,req,key):
        off,lim=req.get('offset',0),req.get('limit',50)
        return {key:items[off:off+lim],'total':len(items),'offset':off,'hasMore':off+lim<len(items)}
    def search(self,filters):
        result=[]
        for row in self.photos.values():
            m=row['metadata']
            if filters.get('filename','').lower() not in row['filename'].lower():continue
            if m['rating']<filters.get('minRating',0) or m['rating']>filters.get('maxRating',5):continue
            if 'pickStatus' in filters and m['pickStatus']!=filters['pickStatus']:continue
            result.append(row)
        return sorted(result,key=lambda r:r['photoId'])

    def handle(self,req):
        cmd=req['command']
        if req.get('expectedCatalogPath','/mock/catalog.lrcat')!='/mock/catalog.lrcat':return self.error('catalog_changed')
        if req.get('expectedPhotoId',self.current)!=self.current:return self.error('photo_changed')
        target_ids=self.targets(req)
        if any(i not in self.photos for i in target_ids):return self.error('photo_not_found')
        data={}
        if cmd=='get_selection':
            data=self.paginate([self.photos[i] for i in self.selected],req,'photos');data['activePhotoId']=self.current
        elif cmd=='search_photos':
            rows=self.search(req.get('filters',{}))
            if req.get('collectionId'):
                col=self.collections.get(req['collectionId'])
                if not col:return self.error('collection_not_found')
                rows=[p for p in rows if p['photoId'] in col['members']]
            data=self.paginate(rows,req,'photos')
        elif cmd=='select_photos':
            self.selected=req['photoIds'];self.current=req.get('activePhotoId',self.selected[0]);data={'activePhotoId':self.current,'photos':[self.photos[i] for i in self.selected]}
        elif cmd=='get_metadata':
            data['photos']=[deepcopy(self.photos[i]) for i in target_ids]
        elif cmd=='set_metadata':
            for i in target_ids:
                self.photos[i]['metadata'].update(req.get('values',{}))
                for field in req.get('clearFields',[]):self.photos[i]['metadata'].pop(field,None)
            return {'success':True,'applied':len(target_ids),'failed':0,'notAttempted':0,'data':{'results':[{'photoId':i,'success':True} for i in target_ids]}}
        elif cmd=='create_keyword':
            existing=next((k for k in self.keywords.values() if k['name']==req['name'] and k.get('parentId')==req.get('parentId')),None)
            if existing:data={**existing,'status':'existing'}
            else:
                kid=len(self.keywords)+1;data={'keywordId':kid,'name':req['name'],'parentId':req.get('parentId'),'synonyms':req.get('synonyms',[]),'includeOnExport':req.get('includeOnExport',True),'path':req['name']}
                self.keywords[kid]=deepcopy(data);data['status']='created_or_existing'
        elif cmd=='update_keyword':
            if req['keywordId'] not in self.keywords:return self.error('keyword_not_found')
            item=self.keywords[req['keywordId']]
            item.update({k:req[k] for k in ['name','synonyms','includeOnExport'] if k in req});data=item
        elif cmd=='list_keywords':
            data=self.paginate([k for k in self.keywords.values() if req.get('query','').lower() in k['name'].lower()],req,'keywords')
        elif cmd=='update_photo_keywords':
            if any(k not in self.keywords for k in req['keywordIds']):return self.error('keyword_not_found')
            for i in target_ids:
                assigned=set(self.photos[i]['keywords'])
                if req['operation']=='add':assigned.update(req['keywordIds'])
                else:assigned.difference_update(req['keywordIds'])
                self.photos[i]['keywords']=sorted(assigned)
            return {'success':True,'applied':len(target_ids),'failed':0,'notAttempted':0,'data':{'results':[{'photoId':i,'success':True} for i in target_ids]}}
        elif cmd=='create_collection':
            if any(c['name']==req['name'] and c.get('parentId')==req.get('parentId') for c in self.collections.values()):return self.error('collection_exists')
            cid=len(self.collections)+10;data={'collectionId':cid,'name':req['name'],'kind':req.get('kind','collection'),'parentId':req.get('parentId'),'members':[]}
            self.collections[cid]=deepcopy(data)
        elif cmd=='list_collections':data=self.paginate(list(self.collections.values()),req,'collections')
        elif cmd in {'update_collection','update_collection_photos','delete_collection'}:
            col=self.collections.get(req['collectionId'])
            if not col:return self.error('collection_not_found')
            if cmd=='update_collection':col.update({k:req[k] for k in ['name','filters'] if k in req})
            elif cmd=='update_collection_photos':
                if col['kind']!='collection':return self.error('unsupported_collection')
                ids=set(col['members'])
                if req['operation']=='add':ids.update(target_ids)
                else:ids.difference_update(target_ids)
                col['members']=sorted(ids)
            else:
                if col['members'] and req.get('requireEmpty',True):return self.error('collection_not_empty')
                del self.collections[req['collectionId']]
            data={'collectionId':req['collectionId']}
        elif cmd=='export_photos':
            job=req['jobId'];folder=Path(req['destination'])/('LR-MCP-export-'+job);folder.mkdir()
            data={'jobId':job,'status':'completed','total':len(target_ids),'completed':len(target_ids),'failed':0,'notStarted':0,'outputDirectory':str(folder),'results':[]}
            for i,pid in enumerate(target_ids):
                path=folder/f'photo-{i}.jpg';path.write_bytes(b'mock-export')
                data['results'].append({'photoId':pid,'success':True,'path':str(path),'bytes':11})
            self.jobs[job]=deepcopy(data)
        elif cmd in {'get_export_status','cancel_export'}:
            if req['jobId'] not in self.jobs:return self.error('job_not_found')
            data=self.jobs[req['jobId']]
        data['catalogPath']='/mock/catalog.lrcat'
        return {'success':True,'data':deepcopy(data)}
