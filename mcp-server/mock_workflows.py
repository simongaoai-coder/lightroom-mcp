"""Transport simulation only; native SDK semantics are tested with production Lua."""
from copy import deepcopy


class MockWorkflows:
    def __init__(self, library):
        self.library = library
        self.previews = set()
        self.jobs = {}
        self.settings = {pid: {'Exposure': i, 'Contrast': 0} for i, pid in enumerate(library.photos)}

    def handle(self, req):
        cmd = req['command']
        ids = self.library.targets(req)
        if cmd in {'get_smart_preview_job', 'cancel_smart_preview_job'}:
            job = self.jobs.get(req['jobId'])
            return {'success': True, 'data': deepcopy(job)} if job else self.library.error('job_not_found')
        if any(pid not in self.library.photos for pid in ids):
            return self.library.error('photo_not_found')
        if cmd == 'get_smart_previews':
            return {'success': True, 'data': {'photos': [
                {'photoId': pid, 'originalAvailable': True, 'hasSmartPreview': pid in self.previews}
                for pid in ids]}}
        if cmd == 'batch_adjust_relative':
            results = []
            for pid in ids:
                before = {k: self.settings[pid].get(k, 0) for k in req['deltas']}
                after = {k: before[k] + v for k, v in req['deltas'].items()}
                self.settings[pid].update(after)
                results.append({'photoId': pid, 'success': True, 'before': before, 'after': after, 'target': after})
            return {'success': True, 'applied': len(ids), 'failed': 0, 'notAttempted': 0, 'data': {'results': results}}
        results = []
        for pid in ids:
            if cmd == 'build_smart_previews':
                self.previews.add(pid)
            else:
                self.previews.discard(pid)
            results.append({'photoId': pid, 'success': True})
        job = {'jobId': req['jobId'], 'status': 'completed', 'total': len(ids),
               'completed': len(ids), 'failed': 0, 'notStarted': 0, 'results': results}
        self.jobs[req['jobId']] = job
        return {'success': True, 'data': deepcopy(job)}
