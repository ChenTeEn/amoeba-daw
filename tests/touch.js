(async()=>{
const fs=require("node:fs"), [, , endpoint, screenshot]=process.argv;
const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms));
let page;
for(let i=0;i<60;i++){
  try {
    const pages=await (await fetch(endpoint+"/json/list")).json();
    page=pages.find(t=>t.type==="page"&&t.url.startsWith("http://127.0.0.1:"));
    if(page)break;
  }catch{}
  await delay(160);
}
if(!page)throw Error("Mixer browser not found");
const ws=new WebSocket(page.webSocketDebuggerUrl);
await new Promise(resolve=>ws.addEventListener("open",resolve,{once:true}));
const pending=new Map(); let id=0;
ws.addEventListener("message",event=>{
  const m=JSON.parse(event.data), p=pending.get(m.id);if(!p)return;
  pending.delete(m.id);if(m.error)p.reject(Error(m.error.message));else p.resolve(m.result);
});
ws.addEventListener("close",()=>{for(const value of pending.values())value.reject(Error("Browser closed"));pending.clear();});
function send(method,params={}){
  return new Promise((resolve,reject)=>{pending.set(++id,{resolve,reject});ws.send(JSON.stringify({id,method,params}));});
}
async function evaluate(expression){
  const r=await send("Runtime.evaluate",{expression,returnByValue:true,awaitPromise:true});
  if(r.exceptionDetails)throw Error(r.exceptionDetails.text);
  return r.result.value;
}
async function waitFor(expr){
  for(let i=0;i<50;i++){if(await evaluate(expr))return;await delay(120);}
  throw Error("Timed out: "+expr);
}
async function touch(selector,fraction=.5){
  const rect=await evaluate("(()=>{const r=document.querySelector("+JSON.stringify(selector)+").getBoundingClientRect();return [r.left,r.top,r.width,r.height]})()");
  await send("Input.dispatchTouchEvent",{type:"touchStart",touchPoints:[{x:Math.round(rect[0]+rect[2]*fraction),y:Math.round(rect[1]+.5*rect[3])}]});
  await delay(70);
  await send("Input.dispatchTouchEvent",{type:"touchEnd",touchPoints:[]});
}
async function key(code,virtual){
  for(const type of ["rawKeyDown","keyUp"])
    await send("Input.dispatchKeyEvent",{type,code,key:code==="Space"?" ":code,windowsVirtualKeyCode:virtual});
}
await waitFor("document.querySelectorAll('#sections button').length === 3");
if(process.argv[4]==="reopen"){
  await waitFor("document.querySelector('#play').textContent==='暫停' && document.querySelector('#sections button:nth-child(2)').getAttribute('aria-pressed')==='true'");
  console.log("PASS reattached to playing B without starting playback.");
} else {
  await touch("#sections button:nth-child(2)");
  await waitFor("document.querySelector('#play').textContent==='暫停' && document.querySelector('#sections button:nth-child(2)').getAttribute('aria-pressed')==='true'");
  await touch("[data-action=close]");
  console.log("PASS touch section B and detach.");
}
ws.close();
})().catch(error=>{console.error(error);process.exit(1)});
