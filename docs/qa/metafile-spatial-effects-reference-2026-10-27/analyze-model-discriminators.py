#!/usr/bin/env python3
"""Summarize matched native sources, stage identities and falsified models.

This does not implement or fit image processing. All predictions are read from
an independently parameterized full-buffer diagnostic; all references are SDK
observations, with the source consumer's startup version selected explicitly.
"""
import argparse,hashlib,json
from collections import Counter
from pathlib import Path

def sha(data):return hashlib.sha256(data).hexdigest()
def analyze(root,models):
    generated=json.loads((root/'generate.json').read_text(encoding='utf-8-sig'))
    one=json.loads((root/'replay-v1.json').read_text(encoding='utf-8-sig'))
    two=json.loads((root/'replay.json').read_text(encoding='utf-8-sig'))
    v1={c['atlas']:c for c in one['cases']};v2={c['atlas']:c for c in two['cases']}
    hypotheses=json.loads(models.read_text());assert hypotheses['observationMode']=='replay-v1'
    predictions={c['name']:c for c in hypotheses['artifacts'][0]['cases']}
    rows=[];histograms={};stage_matches=Counter()
    for c in generated['cases']:
        name=c['name'];source=(root/('atlas-'+c['atlas']+'.rgba')).read_bytes()
        stages={stage:(root/(prefix+name+'.rgba')).read_bytes()for stage,prefix in [('direct-v2',''),('created-v2','created-'),('direct-v1','direct-v1-'),('created-v1','direct-v1-created-'),('file-v1','replay-v1-'),('file-v2','replay-')]}
        first=stages['file-v1'];hist=Counter(tuple(source[i:i+4])for i in range(0,len(source),4));histograms[name]=hist
        equal={stage:data==first for stage,data in stages.items()};stage_matches.update(stage for stage,value in equal.items()if value)
        case=predictions[name];quarter=next(q for q in case['hypotheses']if q['coneFactor']==1 and q['includeCandidateGlint'])
        center=4*(15*32+15)
        row=dict(name=name,sourceSHA256=sha(source),sourceHistogram=[dict(rgba=list(color),count=count)for color,count in sorted(hist.items())],sourceDefinition=c['sourceDefinition'],fileV1EqualsStage=equal,stageSHA256={stage:sha(data)for stage,data in stages.items()},center15_15={stage:list(data[center:center+4])for stage,data in stages.items()},quarterConeWithExplicitGlint=dict(comparedPixelCount=quarter['comparedPixelCount'],pixelsExceedingOne=quarter['pixelsExceedingOne'],maxByteDelta=quarter['maxByteDelta']),candidateConeConstraint=case['inferredConeCoefficientConstraint']['interval'])
        rows.append(row)
    hist_names=[c['name']for c in generated['cases']if c['sourceDefinition']['matchedHistogramGroup']=='576red448gray']
    assert len(hist_names)==5 and all(histograms[n]==histograms[hist_names[0]]for n in hist_names)
    interval_names=['model-hist-square24','model-hist-two-rectangles','model-hist-center-rows','model-red-square20','model-red-square22','model-red-square26']
    intervals=[next(c for c in rows if c['name']==n)['candidateConeConstraint']for n in interval_names]
    lower=max(q[0]for q in intervals);upper=min(q[1]for q in intervals);assert lower<=upper
    return dict(qualification='Numerical source-contract evidence only. No production algorithm, renderer acceptance, Core/native check or tolerance change. Conditional inferred intervals are diagnostics, never prediction coefficients.',sourceConsumer=dict(anchors=['src/Utils/MiscUI/Picture.h:197','src/Utils/MiscUI/Picture.cpp:415'],startupVersion=1,reason='GdiplusStartupInput constructed with default Version1; Picture calls GdiplusStartup without overriding Version.'),observationMode='replay-v1',caseCount=len(rows),fullBufferPixels=len(rows)*1024,stageIdentityCounts=dict(stage_matches),quarterConeWithExplicitGlint=dict(passingCases=sum(c['quarterConeWithExplicitGlint']['pixelsExceedingOne']==0 for c in rows),failingCases=sum(c['quarterConeWithExplicitGlint']['pixelsExceedingOne']>0 for c in rows)),matchedHistogram=dict(cases=hist_names,histogram=[dict(rgba=list(color),count=count)for color,count in sorted(histograms[hist_names[0]].items())],conditionalCommonConeInterval=dict(cases=interval_names,interval=[lower,upper],warning='Conditioned on current ROI/angular/radial composition, excluding supplied glint support. Does not establish a general coefficient or global histogram selection rule.')),newConstraints=['All29 FILE-v1 buffers equal both direct and created outputs for both SDK startup versions.', 'Only model-channel-gb0-uniform and model-channel-gb0-gray-hole differ between FILE startup1 and2. Older pure-red255 file/direct disagreement remains separately valid; new pure-red240 is not the same input.', 'Constant quarter cone with candidate glint is exact/within1byte for15of29 default-v1 full buffers; all five continuous gradients and several equal-histogram layouts still refute general acceptance.', 'Centered red squares20,22,24,26 share a conditional coefficient near0.66; square28/30 instead agree with quarter cone. An extent/population switch is constrained, not identified.', 'Mean-only and dispersion angular candidates remain unaccepted: their continuous-distribution errors are not repaired by selecting a different fixed cone coefficient.'],nextImplementationStep='Derive the angular statistic and amplitude-selection rule from the full default-v1 buffers, retaining signed rounding bounds and independent spatial geometry. Separate green-zero behavior and red255 recording/replay behavior from ordinary colors. Do not enable fitted per-case branches.',inputSHA256={str(models):sha(models.read_bytes())},cases=rows)
if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('artifact',type=Path);p.add_argument('models',type=Path);p.add_argument('output',type=Path);a=p.parse_args();report=analyze(a.artifact,a.models);a.output.write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({k:report[k]for k in ['caseCount','fullBufferPixels','stageIdentityCounts','quarterConeWithExplicitGlint','matchedHistogram']}))
