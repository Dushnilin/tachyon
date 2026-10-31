import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const source=fs.readFileSync(new URL('../luci-app-tachyon/htdocs/luci-static/resources/view/tachyon/settings.js',import.meta.url),'utf8');
const block=source.slice(source.indexOf('  const chainOpt ='),source.indexOf('  // Legacy background detector destinations;'));
assert.ok(block.includes('smart_detect_chain'),'exercise the shipped settings block');
const options=[],forms={smart_detect_chain_zapret:'zapret',smart_detect_chain_vpn:'vpn'};
let calls=0;
function E(tag,attrs={},children=[]){
  if(Array.isArray(attrs)||typeof attrs==='string'){children=attrs;attrs={};}
  return {tag,attrs,children:Array.isArray(children)?children:[children],events:{},textContent:'',
    appendChild(x){this.children.push(x);},replaceChildren(){this.children=[];},
    addEventListener(name,fn){this.events[name]=fn;}};
}
vm.runInNewContext(block,{
  _:s=>s,form:{Flag:'Flag',Value:'Value',ListValue:'ListValue',DummyValue:'DummyValue'},
  UCI_PACKAGE:'tachyon',E,
  uci:{get:(_p,_s,k)=>forms[k],sections:()=>[
    {'.name':'zapret',enabled:'1',action:'zapret2'},
    {'.name':'vpn',enabled:'1',action:'connection'},
    {'.name':'disabled',enabled:'0',action:'connection'},
    {'.name':'block',enabled:'1',action:'block'},
  ]},
  fs:{exec:async(path,args)=>{calls++;assert.equal(path,'/usr/bin/tachyon-read');assert.equal(args[0],'smart_connect_status');return {code:0,stdout:JSON.stringify({entries:[{key:'zapret|site.example:443',route:'zapret',ip:'1.1.1.3'}]})};}},
  section:{taboption(tab,type,name,title,description){
    const option={name,type,title,description,choices:[],dependencies:[],map:{lookupOption:key=>[{formvalue:()=>forms[key]}]},
      value(v,label){this.choices.push([v,label]);},depends(...v){this.dependencies.push(v);}};
    options.push(option);return option;
  }},
});
const get=name=>options.find(o=>o.name===name);
assert.equal(get('smart_detect_chain').default,'0');
for(const name of ['smart_detect_chain_zapret','smart_detect_chain_vpn']){
  const field=get(name);assert.equal(field.retain,true);
  assert.equal(field.validate('settings','missing'),'Select an enabled routing section');
  assert.equal(field.validate('settings',forms[name]),true);
  const other=name==='smart_detect_chain_zapret'?'smart_detect_chain_vpn':'smart_detect_chain_zapret';
  assert.equal(field.validate('settings',forms[other]),'Zapret and backup VPN must use different sections');
  assert.ok(!field.choices.some(([v])=>v==='disabled'||v==='block'));
}
assert.equal(get('smart_detect_chain_budget_ms').default,'3000');
assert.equal(get('smart_detect_chain_budget_ms').datatype,'range(100,10000)');
const widget=get('_smart_connect_status').renderWidget();
const [button,content]=widget.children;
assert.equal(calls,0,'no probe or service action on render');
await button.events.click();
assert.equal(button.disabled,false);
assert.equal(calls,1);
assert.equal(content.children[0].tag,'table');
assert.equal(content.children[0].children[1].children[0].children[0],'site.example:443');
assert.equal(content.children[0].children[1].children[1].children[0],'Zapret');
assert.equal(content.children[0].children[1].children[2].children[0],'1.1.1.3');
console.log('PASS: Smart Connect opt-in, required fields, preserved settings and read-only cache viewer');
