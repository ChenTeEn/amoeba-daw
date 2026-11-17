"use strict";
const find=(selector)=>document.querySelector(selector);
const position=find("#position"), tracks=find("#tracks");
let mix, state, busy=false, polling=false, rows=[];
let gainQueue=null, sendingGain=false, activeGain=null;
const autoTrack=find("#auto-track"), autoPoint=find("#auto-point"), autoTime=find("#auto-time"), autoDb=find("#auto-db");

function showPoints(resetFields=false) {
  const track=mix.tracks[Number(autoTrack.value)];
  const current=autoPoint.value;
  autoPoint.replaceChildren(new Option("新增", "new"));
  track.automation.forEach(([frame,,db],i)=>{
    autoPoint.add(new Option((frame/mix.rate).toFixed(2)+" s · "+(db/10).toFixed(1)+" dB",i));
  });
  if([...autoPoint.options].some(option=>option.value===current))autoPoint.value=current;
  const point=track.automation[Number(autoPoint.value)];
  find("#auto-update").disabled=!point;
  if(resetFields&&point){autoTime.value=(point[0]/mix.rate).toFixed(3);autoDb.value=point[2]/10;}
}

async function drainGain(){
  if(sendingGain)return;
  sendingGain=true;
  try{
    while(gainQueue){
      const send=gainQueue;gainQueue=null;
      if(send.value!==null){
        state=await request("action/gain/"+send.index+"/"+send.value,"POST");
        mix.tracks[send.index].trim=send.value;
      }
      if(send.end){state=await request("action/gain-end","POST");activeGain=null;}
      drawControls();
    }
  }catch(error){find("#message").textContent=error.message;activeGain=null;}
  finally{sendingGain=false;}
}
function queueGain(index,value,end){
  activeGain=index;gainQueue={index,value,end};drainGain();
}
const actions=(name)=>find(`[data-action="${name}"]`);

async function request(path, method="GET") {
  const response=await fetch(path, {method, cache:"no-store"});
  if(!response.ok) throw new Error(await response.text());
  return response.json();
}

function meter(value) {
  const db=value===0 ? -60 : Math.max(-60,20*Math.log10(value/8388608));
  return 60+db;
}

function paint(row, track, cursor) {
  const canvas=row.canvas, box=canvas.getBoundingClientRect();
  const scale=window.devicePixelRatio || 1;
  const w=Math.round(box.width*scale), h=Math.round(box.height*scale);
  if(w<1||h<1) return;
  if(canvas.width!==w||canvas.height!==h){canvas.width=w;canvas.height=h;}
  const ctx=canvas.getContext("2d");
  ctx.clearRect(0,0,w,h);
  const px=(frame)=>Math.round(w*frame/mix.length);
  const middle=h*.43;
  const trim=Math.pow(10,(state.mode==="b"?track.trim:track.viewTrim)/200);
  ctx.strokeStyle="#263747";
  ctx.beginPath();
  const barFrames=mix.bar*mix.rate*60/mix.bpm;
  for(let frame=0;frame<mix.length;frame+=barFrames){
    ctx.moveTo(px(frame),0);ctx.lineTo(px(frame),h);
  }
  ctx.moveTo(0,middle);ctx.lineTo(w,middle);ctx.stroke();
  ctx.strokeStyle="#62c7d5";ctx.beginPath();
  for(let i=0;i<track.peaks.length;i++){
    const [left,right]=track.peaks[i];
    const x=px(i*mix.step);
    ctx.moveTo(x,middle-Math.min(1,left*trim/8388608)*middle);
    ctx.lineTo(x,middle+Math.min(1,right*trim/8388608)*middle);
  }
  ctx.stroke();
  if(track.automation.length){
    const y=(gain)=>h-6*scale-Math.min(1600,gain)*h*.17/1600;
    ctx.strokeStyle="#ffc36d";ctx.fillStyle="#ffc36d";ctx.beginPath();
    let previous=1000;
    ctx.moveTo(0,y(previous));
    for(const [frame,gain] of [...track.automation].sort((a,b)=>a[0]-b[0])){
      ctx.lineTo(px(frame),y(previous));ctx.lineTo(px(frame),y(gain));previous=gain;
    }
    ctx.lineTo(w,y(previous));ctx.stroke();
    for(const [frame,gain] of track.automation){
      ctx.beginPath();ctx.arc(px(frame),y(gain),3*scale,0,2*Math.PI);ctx.fill();
    }
  }
  ctx.fillStyle="#eaf7ff";ctx.fillRect(Math.min(w-scale,px(cursor)),0,Math.max(1,scale),h);
}

function addTrack(track,index) {
  const row=document.createElement("article");row.className="track";
  const info=document.createElement("div");
  const name=document.createElement("h2");name.textContent=track.name;
  const levels=document.createElement("div");levels.className="levels";
  const meters=["L","R"].map(channel=>{
    const mark=document.createElement("span");mark.textContent=channel;
    const level=document.createElement("meter");level.min=0;level.max=60;level.value=0;
    level.setAttribute("aria-label",`${track.name} ${channel} 峰值，−60 至 0 dBFS`);
    levels.append(mark,level);return level;
  });
  info.append(name,levels);
  const gain=document.createElement("div");gain.className="gain";
  const label=document.createElement("label");label.textContent="增益調整（dB）";label.htmlFor=`gain-${index}`;
  const slider=document.createElement("input"), number=document.createElement("input");
  slider.type="range";slider.id=label.htmlFor;number.type="number";
  number.setAttribute("aria-label",`${track.name} 增益數值 dB`);
  for(const input of [slider,number]){
    input.min=-24;input.max=6;input.step=.1;input.value=track.trim/10;
    input.addEventListener("change",()=>{
      if(!input.checkValidity()||input.value===""){drawControls();return;}
      queueGain(index,Math.round(input.valueAsNumber*10),true);
    });
  }
  slider.addEventListener("input",()=>{number.value=slider.value;queueGain(index,Math.round(slider.valueAsNumber*10),false);});
  gain.append(label,slider,number);
  const canvas=document.createElement("canvas");canvas.className="wave";canvas.tabIndex=0;
  canvas.setAttribute("aria-label",`${track.name} 波形。點選定位，或用方向鍵移動拍點。`);
  let drag=null, suppressClick=false;
  const frameAt=(event)=>{
    const rect=canvas.getBoundingClientRect();
    return Math.min(mix.length-1,Math.max(0,Math.round(mix.length*(event.clientX-rect.left)/rect.width)));
  };
  canvas.addEventListener("pointerdown",event=>{
    if(!state||!event.isPrimary)return;
    const rect=canvas.getBoundingClientRect();
    const y=event.clientY-rect.top;
    const points=mix.tracks[index].automation;
    const hit=points.findIndex(([frame,gain])=>{
      const x=frame/mix.length*rect.width;
      const dot=rect.height-6-Math.min(1600,gain)*rect.height*.17/1600;
      return Math.abs(event.clientX-rect.left-x)<12 && Math.abs(y-dot)<13;
    });
    if(hit<0)return;
    autoTrack.value=index;showPoints();autoPoint.value=hit;showPoints(true);
    drag={hit,x:event.clientX,db:points[hit][2]};
    canvas.setPointerCapture(event.pointerId);
  });
  canvas.addEventListener("pointermove",event=>{
    if(drag)autoTime.value=(frameAt(event)/mix.rate).toFixed(3);
  });
  canvas.addEventListener("pointerup",event=>{
    if(!drag)return;
    const frame=frameAt(event);
    if(Math.abs(event.clientX-drag.x)>=4){
      autoTime.value=(frame/mix.rate).toFixed(3);
      act("point/"+index+"/"+drag.hit+"/"+frame+"/"+drag.db,true);
    }
    suppressClick=true;
    setTimeout(()=>{suppressClick=false;},0);
    drag=null;
  });
  canvas.addEventListener("pointercancel",()=>{drag=null;});
  canvas.addEventListener("click",event=>{
    if(suppressClick)return;
    const frame=frameAt(event);
    autoTrack.value=index;showPoints();
    autoTime.value=(frame/mix.rate).toFixed(3);
    act("seek/"+frame);
  });
  canvas.addEventListener("keydown",event=>{
    if(!["ArrowLeft","ArrowRight"].includes(event.key))return;
    event.preventDefault();
    const beat=Math.round(mix.rate*60/mix.bpm);
    act(`seek/${state.cursor+(event.key==="ArrowLeft"?-beat:beat)}`);
  });
  row.append(info,gain,canvas);tracks.append(row);
  return {meters,slider,number,canvas};
}

function drawControls() {
  if(!mix||!state)return;
  const ms=Math.round(1000*state.cursor/mix.rate);
  find("#clock").textContent=`${String(Math.floor(ms/60000)).padStart(2,"0")}:${String(Math.floor(ms/1000)%60).padStart(2,"0")}.${String(ms%1000).padStart(3,"0")}`;
  find("#revision").textContent=`REV ${state.revision}${state.draft?" · 尚未儲存":""}`;
  for(const button of find("#sections").children)
    button.setAttribute("aria-pressed",String(button.textContent===state.section));
  actions("play").textContent=state.playing?"暫停":"播放";
  for(const version of ["a","b"]) actions(version).setAttribute("aria-pressed",String(state.mode===version));
  actions("undo").disabled=!state.history;
  actions("save").disabled=!state.draft||state.mode!=="b";
  actions("restore").disabled=state.draft||!state.undo;
  if(takes?.supported)find("#take-apply").disabled=!takes.comp||state.mode!=="b";
  if(document.activeElement!==position)position.value=state.cursor;
  mix.tracks.forEach((track,i)=>{
    const row=rows[i];
    if(activeGain!==i && document.activeElement!==row.slider)row.slider.value=track.trim/10;
    if(activeGain!==i && document.activeElement!==row.number)row.number.value=track.trim/10;
    row.meters.forEach((element,ch)=>{element.value=state.playing?meter(state.levels[i*2+ch]||0):0;});
    paint(row,track,state.cursor);
  });
}

async function loadData() {
  mix=await request("data");
  find("#title").textContent=mix.title;
  position.max=mix.length;position.step=Math.max(1,Math.round(mix.rate/20));
  if(!rows.length){
    mix.sections.forEach((id,index)=>{
      const button=document.createElement("button");
      button.textContent=id;button.setAttribute("aria-label","定位段落 "+id);
      button.addEventListener("click",()=>act("jump/"+index));
      find("#sections").append(button);
    });
    rows=mix.tracks.map(addTrack);
    mix.tracks.forEach((track,i)=>autoTrack.add(new Option(track.name,i)));
    autoTime.value=0;
  }
  autoTime.max=(mix.length-1)/mix.rate;
  showPoints();
}

async function act(action, refresh=false) {
  if(busy||sendingGain||!state)return;
  busy=true;find("#message").textContent="";
  try {
    state=await request(`action/${action}`,"POST");
    if(refresh)await loadData();
    if(action.startsWith("take-"))await loadTakes();
    drawControls();
  } catch(error){find("#message").textContent=error.message;}
  finally {busy=false;}
}
autoTrack.addEventListener("change",()=>showPoints(true));
autoPoint.addEventListener("change",()=>showPoints(true));
find("#auto-cursor").addEventListener("click",()=>{autoTime.value=(Math.min(mix.length-1,state.cursor)/mix.rate).toFixed(3);});
function editPoint(index){
  if(!autoTime.value||!autoDb.value||!autoTime.checkValidity()||!autoDb.checkValidity()){
    find("#message").textContent="輸入曲子範圍內的時間與 −24 至 +6 dB。";return;
  }
  act("point/"+autoTrack.value+"/"+index+"/"+Math.round(autoTime.valueAsNumber*mix.rate)+"/"+Math.round(autoDb.valueAsNumber*10),true);
}
find("#auto-new").addEventListener("click",()=>editPoint("new"));
find("#auto-update").addEventListener("click",()=>editPoint(autoPoint.value));
for(const button of document.querySelectorAll("[data-action]")){
  button.addEventListener("click",()=>act(button.dataset.action,["a","b","undo","save","restore"].includes(button.dataset.action)));
}
position.addEventListener("change",()=>act(`seek/${position.value}`));
document.addEventListener("keydown",event=>{
  if(event.ctrlKey||event.altKey||event.metaKey||event.repeat||event.target.closest("input,button,select"))return;
  if(event.code==="Space"){event.preventDefault();act("play");}
  if(["a","b"].includes(event.key.toLowerCase()))act(event.key.toLowerCase(),true);
  if(event.key==="Escape")act("close");
});
window.addEventListener("resize",drawControls);

(async()=>{
  try {
    await loadData();state=await request("state");await loadTakes(true);drawControls();
    setInterval(async()=>{
      if(busy||sendingGain||polling||!state.playing)return;
      polling=true;
      try {const next=await request("state");if(!busy&&!sendingGain){state=next;if(takes?.recording)await loadTakes();drawControls();if(state.error)find("#message").textContent=state.error;}}
      catch(error){find("#message").textContent=error.message;}
      finally{polling=false;}
    },100);
  }catch(error){find("#message").textContent=error.message;}
})();

let takes, slices=[], lastTakeKey="", sliceEdge="from";
const takesPanel=find("#takes-panel"), sliceTake=find("#slice-take");
const seconds=frame=>(frame/mix.rate).toFixed(3);
const frameOf=selector=>Math.round(find(selector).valueAsNumber*mix.rate);

function paintTake(canvas, row){
  const w=canvas.clientWidth||700, h=40;
  canvas.width=w;canvas.height=h;
  const ctx=canvas.getContext("2d");
  const peak=Math.max(65536,...row.peaks.map(([left,right])=>Math.max(left,right)));
  ctx.strokeStyle="#7ee1ed";ctx.beginPath();
  row.peaks.forEach(([left,right],i)=>{
    const x=w*i/row.peaks.length;
    ctx.moveTo(x,h/2-left/peak*h*.47);ctx.lineTo(x,h/2+right/peak*h*.47);
  });
  ctx.stroke();
}
async function loadTakes(initial=false){
  takes=await request("takes");
  takesPanel.hidden=!takes.supported;
  if(!takes.supported)return;
  if(initial){
    find("#take-from").value=seconds(takes.from); find("#take-to").value=seconds(takes.to);
    find("#slice-from").value=seconds(takes.from); find("#slice-to").value=seconds(takes.to);
  }
  find("#take-state").textContent=takes.recording?"錄音／預捲中":takes.comp?"拼接待套用":takes.preview?"Take 試聽":(takes.takes.length+" takes");
  if(takes.ready&&!takes.recording&&!takes.preview){
    find("#take-state").textContent += " · ALSA"
      +(takes.calibrated?" · 已量測對位":" · 對位未校準");
  }
  find("#take-record").disabled=!takes.ready||takes.recording;
  find("#take-cancel").disabled=!takes.recording;
  find("#take-apply").disabled=!takes.comp || state.mode!=="b";
  const key=takes.takes.map(row=>row.id).join(",");
  if(key===lastTakeKey)return;
  lastTakeKey=key;
  const list=find("#take-list");
  list.replaceChildren();sliceTake.replaceChildren();
  takes.takes.forEach((row,i)=>{
    sliceTake.add(new Option("Take "+(i+1),row.id));
    const group=document.createElement("div");group.className="take-row";
    const button=document.createElement("button");button.textContent="試聽 Take "+(i+1);
    button.addEventListener("click",()=>{sliceTake.value=row.id;act("take-listen/"+row.id,true);});
    const canvas=document.createElement("canvas");canvas.className="wave take-wave";
    canvas.setAttribute("aria-label","Take "+(i+1)+" 波形");
    canvas.addEventListener("click",event=>{
      const box=canvas.getBoundingClientRect();
      sliceTake.value=row.id;
      find("#slice-"+sliceEdge).value=seconds(row.from+Math.round((row.to-row.from)*(event.clientX-box.x)/box.width));
    });
    group.append(button,canvas);list.append(group);paintTake(canvas,row);
  });
}
function showSlices(){
  const list=find("#slice-list");list.replaceChildren();
  slices.forEach(([id,from,to])=>{
    const li=document.createElement("li");li.textContent="Take "+(takes.takes.findIndex(row=>row.id===id)+1)+" · "+seconds(from)+"–"+seconds(to)+" s";list.append(li);
  });
}
find("#take-confirm").addEventListener("click",()=>act("take-confirm"));
find("#take-range").addEventListener("click",()=>act("take-range/"+frameOf("#take-from")+"/"+frameOf("#take-to"),true));
find("#take-record").addEventListener("click",()=>act("take-record"));
find("#take-cancel").addEventListener("click",()=>act("take-cancel"));
find("#take-discard").addEventListener("click",()=>act("take-discard",true));
find("#slice-edge").addEventListener("click",()=>{
  sliceEdge=sliceEdge==="from"?"to":"from";
  const button=find("#slice-edge");
  button.setAttribute("aria-pressed",String(sliceEdge==="to"));
  button.textContent=sliceEdge==="to"?"波形點選：終點":"波形點選：起點";
});
find("#slice-add").addEventListener("click",()=>{
  const from=frameOf("#slice-from"),to=frameOf("#slice-to");
  if(!sliceTake.value||!Number.isFinite(from)||!Number.isFinite(to)||from>=to||slices.length>=8){
    find("#message").textContent="請選 Take 與有效的起點、終點，最多八段。";return;
  }
  slices.push([sliceTake.value,from,to]);showSlices();
});
find("#slice-clear").addEventListener("click",()=>{slices=[];showSlices();});
find("#take-comp").addEventListener("click",()=>{if(slices.length)act("take-comp/"+slices.map(row=>row.join(",")).join("/"),true);});
find("#take-apply").addEventListener("click",()=>act("take-apply",true));
