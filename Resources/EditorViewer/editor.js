'use strict';
const post = value => window.webkit?.messageHandlers.editor.postMessage(value);
let scoreDocument, engineName, osmd, lastXML, lastNotationXML, rendering=false, pending=null, requested=0, selected='', playBeat=null, resizeTimer;
const host=document.getElementById('score-host'), layer=document.getElementById('hit-layer');
let targets=[], diagnostics={}, observedWidth=0, runtimeErrors=[];
window.addEventListener('error',event=>runtimeErrors.push(event.message));
window.addEventListener('unhandledrejection',event=>runtimeErrors.push(String(event.reason)));
const originalConsoleError=console.error;console.error=(...args)=>{runtimeErrors.push(args.map(a=>String(a?.message||a)).join(' '));originalConsoleError(...args);};
const originalConsoleWarn=console.warn;console.warn=(...args)=>{runtimeErrors.push(args.map(a=>String(a?.message||a)).join(' '));originalConsoleWarn(...args);};
function previewFrames(){if(!window.editorPreview||window.editorFrames)return;window.editorFrames=true;const frame=window.requestAnimationFrame.bind(window);window.requestAnimationFrame=callback=>{let done=false;const id=frame(time=>{if(!done){done=true;callback(time);}});setTimeout(()=>{if(!done){done=true;window.cancelAnimationFrame(id);callback(performance.now());}},40);return id;};}
const rhythmTicks=r=>r.triplet?r.base*2/3:r.dotted?r.base*1.5:r.base;
function events(bar,staff,voice=null){return scoreDocument.events.filter(e=>e.bar===bar&&e.staff===staff&&(voice===null||(e.voice||1)===voice));}
function voices(staff){return [...new Set(scoreDocument.events.filter(e=>e.staff===staff).map(e=>e.voice||1))].sort();}
function eventAt(bar,staff,ticks,voice=1){let time=0;for(const e of events(bar,staff,voice)){if(Math.abs(time-ticks)<2)return e;time+=rhythmTicks(e.rhythm);}return null;}
function box(element){if(!element)return null;const r=element.getBoundingClientRect(),h=host.getBoundingClientRect();return r.width&&r.height?{x:r.x-h.x,y:r.y-h.y,width:r.width,height:r.height}:null;}
function target(event,element,extra={}){const r=box(element);if(!r||!event)return;const key=event.id+':'+Math.round(r.y);if(targets.some(t=>t.key===key))return;targets.push({key,id:event.id,bar:event.bar,staff:event.staff,voice:event.voice||1,...r,...extra});}
function paintTargets(){layer.replaceChildren();for(const t of targets){const button=document.createElement('button');button.type='button';button.className='note-hit';button.dataset.eventId=t.id;button.setAttribute('aria-label',`Bar ${t.bar+1+(scoreDocument.barOffset||0)}, ${scoreDocument.instrument==='Piano'?(t.staff===1?'right hand':'left hand'):'guitar'}, ${events(t.bar,t.staff).find(e=>e.id===t.id)?.pitches.map(p=>p.midi).join(' and ')||'rest'}`);button.style.cssText=`left:${t.x-4}px;top:${t.y-6}px;width:${Math.max(22,t.width+8)}px;height:${Math.max(24,t.height+12)}px`;button.addEventListener('click',()=>{selected=t.id;window.selectEditor(selected,playBeat);post({kind:'select',id:t.id});});layer.append(button);}window.selectEditor(selected,playBeat);}
window.selectEditor=function(id,beat){selected=id;playBeat=typeof beat==='number'?beat:null;const active=new Set();if(playBeat!==null){const length=scoreDocument.meter.beats*4/scoreDocument.meter.unit,bar=Math.floor(playBeat/length)-(scoreDocument.barOffset||0),ticks=(playBeat%length)*480;for(let staff=1;staff<=(scoreDocument?.instrument==='Piano'?2:1);staff++){for(const voice of voices(staff)){let time=0;for(const e of events(bar,staff,voice)){if(ticks>=time&&ticks<time+rhythmTicks(e.rhythm))active.add(e.id);time+=rhythmTicks(e.rhythm);}}}}for(const b of layer.children){b.classList.toggle('selected',b.dataset.eventId===selected);b.classList.toggle('playing',active.has(b.dataset.eventId));}paintPlayhead();};
function paintPlayhead(){
  let line=layer.querySelector('.score-playhead');
  if(!line){line=document.createElement('div');line.className='score-playhead';line.setAttribute('aria-hidden','true');layer.append(line);}
  if(playBeat===null||!scoreDocument){line.hidden=true;return;}
  const length=scoreDocument.meter.beats*4/scoreDocument.meter.unit;
  const bar=Math.floor(playBeat/length)-(scoreDocument.barOffset||0),local=playBeat%length;
  const marks=targets.filter(t=>t.bar===bar);
  if(!marks.length){line.hidden=true;return;}
  const anchors=[];
  for(const t of marks){let time=0;for(const e of events(bar,t.staff,t.voice)){if(e.id===t.id)break;time+=rhythmTicks(e.rhythm)/480;}
    const previous=anchors.find(a=>Math.abs(a.time-time)<0.00001);
    if(previous)previous.x=Math.min(previous.x,t.x+t.width/2);else anchors.push({time,x:t.x+t.width/2});}
  anchors.sort((a,b)=>a.time-b.time);
  const top=Math.max(0,Math.min(...marks.map(t=>t.y))-24),bottom=Math.max(...marks.map(t=>t.y+t.height))+28;
  const next=targets.filter(t=>t.bar===bar+1&&t.y>=top&&t.y<=bottom);
  const end=next.length?Math.min(...next.map(t=>t.x))-12:host.clientWidth-20;
  const a=anchors.filter(a=>a.time<=local).at(-1)||anchors[0],b=anchors.find(b=>b.time>a.time)||{time:length,x:Math.max(a.x+8,end)};
  const progress=Math.max(0,Math.min(1,(local-a.time)/Math.max(0.001,b.time-a.time)));
  line.hidden=false;line.style.cssText=`left:${a.x+(b.x-a.x)*progress}px;top:${top}px;height:${bottom-top}px`;
  const rect=line.getBoundingClientRect();if(rect.top<0||rect.bottom>window.innerHeight)window.scrollTo(0,Math.max(0,top-40));
}
function mapOSMD(){
  const measures=osmd.GraphicSheet.MeasureList;
  for(let bar=0;bar<measures.length;bar++)for(let staff=0;staff<measures[bar].length;staff++){
    const measure=measures[bar][staff];if(!measure)continue;
    for(const entry of measure.staffEntries||[]){
      const ticks=(entry.sourceStaffEntry?.Timestamp?.RealValue??0)*1920;
      for(const voice of entry.graphicalVoiceEntries||[])for(const note of voice.notes||[]){
        const xmlVoice=note.sourceNote?.ParentVoiceEntry?.ParentVoice?.VoiceId;
        const nativeVoice=typeof xmlVoice==='number'?((xmlVoice-1)%2)+1:1;
        const event=eventAt(bar,scoreDocument.instrument==='Guitar'?1:staff+1,ticks,nativeVoice);
        const element=note.getSVGGElement?.()||document.getElementById(note.sourceNote?.NoteId);
        target(event,element,{displayStaff:staff+1});
      }
    }
  }
}
window.loadEditor=async function(model,engine,xml,notationXML){
  model.meter ||= {beats:4,unit:4};model.barCount ||= 4;
  const restoreScroll=scoreDocument?.id===model.id && (scoreDocument.barOffset||0)===(model.barOffset||0) ? window.scrollY : 0;
  if(rendering){pending=[model,engine,xml,notationXML];return;}
  rendering=true;const token=++requested,start=performance.now();scoreDocument=model;engineName=engine='OpenSheetMusicDisplay';lastXML=xml;lastNotationXML=notationXML;targets=[];layer.replaceChildren();
  try{
      host.replaceChildren();osmd=new opensheetmusicdisplay.OpenSheetMusicDisplay('score-host',{backend:'svg',autoResize:false,drawTitle:false,drawSubtitle:false,drawComposer:false,drawPartNames:false,drawingParameters:'compacttight'});osmd.Zoom=0.85;osmd.EngravingRules.StretchLastSystemLine=true;osmd.EngravingRules.RenderXMeasuresPerLineAkaSystem=4;osmd.EngravingRules.AutoGenerateMultipleRestMeasuresFromRestMeasures=false;osmd.EngravingRules.RenderMultipleRestMeasures=false;osmd.EngravingRules.RenderStringNumbersClassical=false;osmd.EngravingRules.RenderFingerings=false;await osmd.load(window.cadenceEngravingXML(xml));osmd.render();mapOSMD();
    if(token!==requested)return;
    paintTargets();
    if(playBeat===null)window.scrollTo(0,restoreScroll);
    diagnostics={kind:'ready',engine,milliseconds:performance.now()-start,height:Math.ceil(host.scrollHeight),targets:targets.length,tabTargets:scoreDocument.instrument==='Guitar'?targets.filter(t=>t.displayStaff===2).length:0,events:scoreDocument.events.length,mappedEvents:new Set(targets.map(t=>t.id)).size,dynamicLabelsSeparated:window.cadenceDynamicOffsets||0,voiceTargets:targets.reduce((r,t)=>(r[t.staff+':'+t.voice]=(r[t.staff+':'+t.voice]||0)+1,r),{}),svgCount:host.querySelectorAll('.score-container svg,#osmdCanvasPage1 svg').length||host.querySelectorAll('svg').length,barOffset:scoreDocument.barOffset||0,meter:scoreDocument.meter,offline:true,linkedTab:scoreDocument.instrument==='Guitar',staffCount:scoreDocument.instrument==='Piano'?2:1,firstSVGIDs:[...host.querySelectorAll('[id]')].slice(0,16).map(e=>e.id)};
    post(diagnostics);
  }catch(error){post({kind:'error',engine,message:String(error.message||error),detail:String(error.stack||error),runtimeErrors});}
  finally{rendering=false;if(pending){const args=pending;pending=null;await window.loadEditor(...args);}}
};
window.verifyEditor=async function(){
  const initial=selected;const buttons=[...layer.querySelectorAll('button')];const first=buttons[0],last=buttons.at(-1);let selectedFirst=false,selectedLast=false;
  if(first){first.click();selectedFirst=selected===first.dataset.eventId;}if(last){last.click();selectedLast=selected===last.dataset.eventId;}window.selectEditor(initial,(scoreDocument.barOffset||0)*scoreDocument.meter.beats*4/scoreDocument.meter.unit+0.5);const playbackHighlight=layer.querySelectorAll('.playing').length>0;window.selectEditor(initial,null);
  const exportInfo={};
  if(initial)post({kind:'select',id:initial});
  const voiceIDs=[...new Set(scoreDocument.events.map(e=>e.voice||1))];
  let distinctVoices=true;
  for(const voice of voiceIDs){const event=scoreDocument.events.find(e=>(e.voice||1)===voice);const button=event&&buttons.find(b=>b.dataset.eventId===event.id);if(!button){distinctVoices=false;continue;}button.click();if(selected!==event.id)distinctVoices=false;}
  window.selectEditor(initial,null);if(initial)post({kind:'select',id:initial});
  const harmonyLabels=window.cadenceHarmonyLabels||[];
  const labels=[...host.querySelectorAll('svg text')].map(e=>({text:e.textContent,box:box(e)}));
  const usedLabels=new Set();
  const renderedHarmony=harmonyLabels.map(label=>{const index=labels.findIndex((e,i)=>e.text===label&&!usedLabels.has(i));if(index>=0)usedLabels.add(index);return labels[index];});
  const harmonyVisible=!scoreDocument.harmonies?.length || harmonyLabels.length===scoreDocument.harmonies.length && renderedHarmony.every(e=>e?.box?.width>0);
  const harmonySeparated=!scoreDocument.harmonies?.length || renderedHarmony.every((e,i)=>renderedHarmony.every((other,j)=>i===j||!e?.box||!other?.box||Math.abs(e.box.x-other.box.x)>5||Math.abs(e.box.y-other.box.y)>5));
  const line=layer.querySelector(".score-playhead");window.selectEditor(initial,(scoreDocument.barOffset||0)*scoreDocument.meter.beats*4/scoreDocument.meter.unit+0.2);const firstX=parseFloat(line.style.left);window.selectEditor(initial,(scoreDocument.barOffset||0)*scoreDocument.meter.beats*4/scoreDocument.meter.unit+0.7);const continuousPlayhead=!line.hidden&&parseFloat(line.style.left)>firstX;window.selectEditor(initial,null);
  if(scoreDocument.barCount>16 && window.scrollProof===undefined){
    window.scrollProof='running';const savedScroll=window.scrollY;
    window.scrollTo(0,120);const before=window.scrollY;
    await window.loadEditor(scoreDocument,engineName,lastXML,lastNotationXML);
    window.scrollProof=before>50&&Math.abs(window.scrollY-before)<2;
    window.scrollTo(0,savedScroll);
  }
  const scrollRetained=window.scrollProof===undefined||window.scrollProof===true;
  return {scrollRetained,continuousPlayhead,harmonyVisible,harmonySeparated,harmonyLabels,harmonyText:labels.map(e=>e.text),selectedFirst,selectedLast,playbackHighlight,distinctVoices,allEventsMapped:scoreDocument.events.every(e=>targets.some(t=>t.id===e.id)),selectionIDsValid:buttons.every(b=>scoreDocument.events.some(e=>e.id===b.dataset.eventId)),...exportInfo};
};
new ResizeObserver(()=>{const width=host.clientWidth;if(Math.abs(width-observedWidth)<2)return;observedWidth=width;clearTimeout(resizeTimer);resizeTimer=setTimeout(()=>{if(scoreDocument&&!rendering)window.loadEditor(scoreDocument,engineName,lastXML,lastNotationXML);},180);}).observe(host);
post({kind:'loaded'});
