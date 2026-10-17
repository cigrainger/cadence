'use strict';
let feedbackMarks=[], feedbackLayer, focusRange=[-1,-1], focusLayer, focusNeedsScroll=false;
let osmd, positions=[], cursorStep=0, requested=0, pendingPosition=null, currentStudy=null, renderedWidth=0, resizeTimer, smoothLine, barDurations=[];
const post = value => window.webkit.messageHandlers.study.postMessage(value);
const children = (element,name) => [...element.children].filter(e=>e.localName===name);
function passageXML(xml,partID,from,through) {
  const document = new DOMParser().parseFromString(xml,'application/xml');
  if(document.querySelector('parsererror')) throw new Error('The score XML could not be displayed.');
  const root=document.documentElement;
  const part=children(root,'part').find(p=>p.getAttribute('id')===partID);
  if(!part) throw new Error('The selected part could not be found.');
  children(root,'part').filter(p=>p!==part).forEach(p=>p.remove());
  const list=children(root,'part-list')[0];
  if(list) [...list.children].filter(p=>p.localName!=='score-part'||p.getAttribute('id')!==partID).forEach(p=>p.remove());
  const bars=children(part,'measure');
  // Carry the selected bar's active divisions, clefs, key, meter and instrument
  // settings into the excerpt so a mid-score passage engraves correctly.
  const carried=new Map();
  for(let i=0;i<=from;i++) {
    for(const attr of children(bars[i],'attributes')) {
      for(const item of attr.children) carried.set(item.localName+':'+(item.getAttribute('number')||''),item.cloneNode(true));
    }
  }
  const first=bars[from];
  children(first,'attributes').forEach(e=>e.remove());
  const attributes=document.createElement('attributes');
  for(const item of carried.values()) attributes.appendChild(item);
  first.insertBefore(attributes,first.firstChild);
  bars.forEach((bar,index)=> { if(index<from||index>through) bar.remove(); });
  // A source page/system break should not leave a small excerpt on empty pages.
  [...part.getElementsByTagName('print')].forEach(e=>e.remove());
  return new XMLSerializer().serializeToString(document);
}
window.loadStudy = async function(xml,partID,from,through,durations=[],feedbackRoom=false) {
  currentStudy=[xml,partID,from,through,durations,feedbackRoom];barDurations=durations;
  const token=++requested;
  positions=[]; cursorStep=0;
  try {
    const excerpt=passageXML(xml,partID,from,through);
    document.getElementById('score').replaceChildren();
    osmd=new opensheetmusicdisplay.OpenSheetMusicDisplay('score',{
      backend:'svg',autoResize:false,drawTitle:false,drawSubtitle:false,drawComposer:false,
      drawPartNames:false,drawingParameters:'compacttight',
      cursorsOptions:[{type:0,color:'#386655',alpha:0.25,follow:false}]
    });
    osmd.Zoom=0.95;
    osmd.EngravingRules.StretchLastSystemLine=true;osmd.EngravingRules.RenderXMeasuresPerLineAkaSystem=4;osmd.EngravingRules.AutoGenerateMultipleRestMeasuresFromRestMeasures=false;osmd.EngravingRules.RenderMultipleRestMeasures=false;
    // Verified against the bundled 2.2.1 EngravingRules/system layout. Keep
    // room for onset badges below a system and harmony above the next one.
    if(feedbackRoom) {osmd.EngravingRules.MinimumDistanceBetweenSystems=7;osmd.EngravingRules.MinSkyBottomDistBetweenSystems=5;}
    await osmd.load(window.cadenceEngravingXML(excerpt));
    if(token!==requested) return;
    osmd.render();
    renderedWidth=document.getElementById('score').getBoundingClientRect().width;
    positions=[]; cursorStep=0;
    const cursor=osmd.cursor;
    cursor.reset(); cursor.show();
    for(let step=0;step<20000&&!cursor.Iterator.EndReached;step++) {
      const iterator=cursor.Iterator;
      const bar=iterator.CurrentMeasureIndex;
      const offset=iterator.CurrentRelativeInMeasureTimestamp.RealValue*4;
      if(!positions.some(p=>p.bar===bar&&Math.abs(p.offset-offset)<0.00001)) {
        const element=cursor.cursorElement, rect=element.getBoundingClientRect(), origin=document.getElementById('score').getBoundingClientRect();
        positions.push({bar,offset,step,x:rect.left-origin.left+rect.width/2,y:rect.top-origin.top,height:rect.height});
      }
      cursor.next();
    }
    positions.sort((a,b)=>a.bar-b.bar||a.offset-b.offset);
    cursor.reset(); cursor.hide();
    smoothLine=document.createElement('div');smoothLine.className='playhead-line';smoothLine.hidden=true;smoothLine.setAttribute('aria-hidden','true');document.getElementById('score').append(smoothLine);
    const feedbackChecks=window.setStudyFeedback(feedbackMarks);
    const focusChecks=window.setStudyFocus(...focusRange,true);
    const height=Math.ceil(document.getElementById('score').scrollHeight);
    post({...feedbackChecks,...focusChecks,kind:'ready',height,svgCount:document.querySelectorAll('svg').length,bars:through-from+1,
      cursorPositions:positions.map(p=>({bar:p.bar,offset:p.offset})),offline:true});
    if(pendingPosition) window.positionStudy(...pendingPosition);
  } catch(error) { post({kind:'error',message:String(error.message||error)}); }
};
window.positionStudy = function(bar,offset,visible) {
  pendingPosition=[bar,offset,visible];
  if(!osmd||!positions.length) return;
  if(!visible) { osmd.cursor.hide(); if(smoothLine)smoothLine.hidden=true; return; }
  const inBar=positions.filter(p=>p.bar===bar);
  const target=inBar.filter(p=>p.offset<=offset+0.001).at(-1)||inBar[0];
  if(!target) { osmd.cursor.hide(); if(smoothLine)smoothLine.hidden=true; return; }
  if(target.step<cursorStep) { osmd.cursor.reset(); cursorStep=0; }
  while(cursorStep<target.step&&!osmd.cursor.Iterator.EndReached) { osmd.cursor.next(); cursorStep++; }
  osmd.cursor.hide();
  const next=inBar.find(p=>p.offset>target.offset+0.00001&&Math.abs(p.y-target.y)<5);
  const nextBar=positions.find(p=>p.bar===bar+1&&Math.abs(p.y-target.y)<5);
  const end={offset:barDurations[bar]||Math.max(offset+1,target.offset+1),x:nextBar?nextBar.x-12:document.getElementById('score').clientWidth-18};
  const toward=next||end, fraction=Math.max(0,Math.min(1,(offset-target.offset)/Math.max(0.001,toward.offset-target.offset)));
  smoothLine.hidden=false;smoothLine.style.cssText=`left:${target.x+(Math.max(target.x,toward.x)-target.x)*fraction}px;top:${target.y}px;height:${target.height}px`;
  const rect=smoothLine.getBoundingClientRect();if(rect.top<0||rect.bottom>window.innerHeight)window.scrollTo(0,Math.max(0,target.y-30));
};
post({kind:'loaded'});
// The isolated app preview exercises the real engraving cursor in both
// directions, including the reset used when a passage loops.
window.verifyStudyCursor = function() {
  if(!positions.length) return {cursorForward:false,cursorRewind:false};
  const saved=pendingPosition, savedScroll=[window.scrollX,window.scrollY];
  const first=positions[0], last=positions.at(-1);
  window.positionStudy(last.bar,last.offset,true);
  const cursorForward=osmd.cursor.Iterator.CurrentMeasureIndex===last.bar && Math.abs(osmd.cursor.Iterator.CurrentRelativeInMeasureTimestamp.RealValue*4-last.offset)<0.0001;
  window.positionStudy(first.bar,first.offset,true);
  const cursorRewind=osmd.cursor.Iterator.CurrentMeasureIndex===first.bar && Math.abs(osmd.cursor.Iterator.CurrentRelativeInMeasureTimestamp.RealValue*4-first.offset)<0.0001;
  window.positionStudy(first.bar,first.offset+0.1,true);const x1=parseFloat(smoothLine.style.left);
  window.positionStudy(first.bar,first.offset+0.2,true);const continuousCursor=!smoothLine.hidden&&parseFloat(smoothLine.style.left)>x1;
  window.positionStudy(first.bar,first.offset,false);const cursorHidden=smoothLine.hidden;
  if(saved) window.positionStudy(...saved); else { osmd.cursor.hide(); smoothLine.hidden=true; pendingPosition=null; }
  window.scrollTo(...savedScroll);
  return {cursorForward,cursorRewind,continuousCursor,cursorHidden,cursorCheckPreservesScroll:Math.abs(window.scrollY-savedScroll[1])<1};
};

// Re-engrave when the native window changes width. Ignore height-only changes
// so the fitted native score height does not create a rendering loop.
new ResizeObserver(entries=> {
  const width=document.getElementById('score').getBoundingClientRect().width;
  if(!currentStudy||Math.abs(width-renderedWidth)<2) return;
  clearTimeout(resizeTimer);
  resizeTimer=setTimeout(()=> {
    if(currentStudy&&Math.abs(document.getElementById('score').getBoundingClientRect().width-renderedWidth)>=2) window.loadStudy(...currentStudy);
  },180);
}).observe(document.getElementById('score'));

// Mark the selected voice's entrances using the same engraved anchors as the
// playhead. Text and symbols supplement colour; the native note list is the
// accessible, detailed counterpart. Never insert source strings as HTML.
window.setStudyFeedback = function(marks) {
  feedbackMarks=Array.isArray(marks)?marks.slice(0,256):[];
  if(!positions.length)return {feedbackPending:true};
  if(feedbackLayer)feedbackLayer.remove();
  feedbackLayer=document.createElement('div');feedbackLayer.className='feedback-layer';
  const symbols={onTime:'✓',early:'←',late:'→',wrongPitch:'×',missed:'–'};
  let mapped=0,clearOfNextSystem=true;
  const entrances=new Map();
  for(const mark of feedbackMarks) {
    if(!Object.hasOwn(symbols,mark.verdict)||!Number.isFinite(mark.offset))continue;
    const point=positions.find(p=>p.bar===mark.bar&&Math.abs(p.offset-mark.offset)<0.001);
    if(!point)continue;
    const key=point.bar+':'+point.offset;
    if(!entrances.has(key))entrances.set(key,{point,marks:[]});
    entrances.get(key).marks.push(mark);mapped++;
  }
  for(const {point,marks:group} of entrances.values()) {
    const severity={onTime:0,early:1,late:1,wrongPitch:2,missed:3};
    const worst=group.reduce((a,b)=>severity[a.verdict]>=severity[b.verdict]?a:b),settled=group.every(m=>m.settled);
    const badge=document.createElement('span');badge.className='note-feedback '+worst.verdict+(settled?'':' provisional');
    badge.textContent=group.length===1?symbols[worst.verdict]:group.filter(m=>m.verdict==='onTime').length+'/'+group.length;
    badge.title=(group.length>1?'Chord entrance · notes on time\n':'')+group.map(m=>String(m.label||m.verdict)).join('\n');badge.setAttribute('aria-label',badge.title);
    const nextSystem=positions.find(p=>p.y>point.y+5);
    if(nextSystem&&point.y+point.height+7+19>nextSystem.y-28)clearOfNextSystem=false;
    badge.style.left=point.x+'px';badge.style.top=(point.y+point.height+7)+'px';feedbackLayer.append(badge);
  }
  document.getElementById('score').style.paddingBottom=feedbackMarks.length?'36px':'8px';
  document.getElementById('score').append(feedbackLayer);
  return {feedbackBadgeCount:entrances.size,feedbackChordsGrouped:[...entrances.values()].filter(e=>e.marks.length>1).length,feedbackClearOfNextSystem:clearOfNextSystem,feedbackHeight:Math.ceil(document.getElementById('score').scrollHeight),feedbackWithinScore:[...feedbackLayer.children].every(e=>e.offsetTop+e.offsetHeight<=document.getElementById('score').scrollHeight&&e.offsetLeft>=0&&e.offsetLeft<=document.getElementById('score').clientWidth),feedbackCount:mapped,feedbackMapped:mapped===feedbackMarks.length,feedbackSafeText:[...feedbackLayer.children].every(e=>e.childElementCount===0)};
};

// The full score stays engraved. The selected exercise only adds a quiet wash
// over its measures, using the same public cursor anchors as the moving line.
window.setStudyFocus = function(from,through,scroll=true) {
  const changed=focusRange[0]!==from||focusRange[1]!==through;
  focusRange=[from,through];focusNeedsScroll=focusNeedsScroll||changed;
  if(!positions.length)return {focusPending:true};
  if(focusLayer)focusLayer.remove();
  focusLayer=document.createElement('div');focusLayer.className='focus-layer';
  const bars=[];
  for(let bar=from;bar>=0&&bar<=through&&bar-from<8;bar++) {
    const points=positions.filter(p=>p.bar===bar);if(!points.length)continue;
    const first=points[0],next=positions.find(p=>p.bar===bar+1&&Math.abs(p.y-first.y)<5);
    const left=Math.max(0,first.x-14),right=next?next.x-16:document.getElementById('score').clientWidth-10;
    const wash=document.createElement('div');wash.className='focus-measure';wash.setAttribute('aria-hidden','true');
    wash.style.cssText=`left:${left}px;top:${Math.max(0,first.y-22)}px;width:${Math.max(12,right-left)}px;height:${first.height+48}px`;
    focusLayer.append(wash);bars.push(bar);
  }
  document.getElementById('score').append(focusLayer);
  if(scroll&&focusNeedsScroll&&bars.length) {const first=positions.find(p=>p.bar===bars[0]);window.scrollTo(0,Math.max(0,first.y-44));focusNeedsScroll=false;}
  return {focusMapped:from<0||bars.length===through-from+1,focusedBars:bars,focusCount:bars.length};
};
